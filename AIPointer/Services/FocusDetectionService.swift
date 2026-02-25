import Foundation

// MARK: - Data Types

struct PreScreenResult {
    let triggered: Bool
    let triggerApp: String
    let triggerBundleId: String
}

struct TimelineEntry {
    let timestamp: Date
    let app: String
    let title: String
    var axContext: String?
    var clipboardContent: String?
    var isRevisit: Bool = false
}

struct ObjectiveMetrics {
    let revisitCount: Int
    let browsedTabRatio: Double
    let clipboardRelevance: Int
    let triggerAppFocus: Double
}

struct FocusDetectResult {
    let detected: Bool
    let confidence: Confidence?
    let theme: String?
    let observation: String?
    let insight: String?
    var offer: String?
    let installedSkill: String?
    let searchKeywords: [String]?

    enum Confidence: String { case high, medium }

    func displayText(
        showObservation: Bool,
        showInsight: Bool,
        showOffer: Bool
    ) -> String? {
        var parts: [String] = []
        if showObservation, let obs = observation, !obs.isEmpty {
            parts.append("Observation\n\(obs)")
        }
        if showInsight, let ins = insight, !ins.isEmpty {
            parts.append("Insight\n\(ins)")
        }
        if showOffer, let ofr = offer, !ofr.isEmpty {
            parts.append("Action\n\(ofr)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

// MARK: - Service

class FocusDetectionService {
    let buffer: BehaviorBuffer
    let tabCache: TabSnapshotCache
    let openClawService: OpenClawService

    private var lastDetectTime: Date = .distantPast
    private var lastCooldownSeconds: TimeInterval = 120
    private(set) var isAnalyzing = false
    private var installedSkillsCache: [(name: String, description: String)] = []

    var detectionWindowMinutes: Double = 5.0
    var cooldownDetectedMinutes: Double = 10.0
    var cooldownMissedMinutes: Double = 2.0
    var strictness: Int = 1

    init(buffer: BehaviorBuffer, tabCache: TabSnapshotCache, openClawService: OpenClawService) {
        self.buffer = buffer
        self.tabCache = tabCache
        self.openClawService = openClawService
        self.installedSkillsCache = getInstalledSkills()
    }

    /// Called every 30 seconds by BehaviorSensingService.
    func tick() async -> FocusDetectResult? {
        guard !isAnalyzing else {
            print("[FocusDetect] tick: skipped (analyzing)")
            return nil
        }

        // ========== Layer 1: Pre-screen ==========
        let windowSeconds = detectionWindowMinutes * 60
        let events = buffer.snapshot(lastSeconds: windowSeconds)

        let cooldownPassed = Date().timeIntervalSince(lastDetectTime) > lastCooldownSeconds
        let titleEvents = events.filter { $0.kind == .windowTitle || $0.kind == .tabSwitch }
        print("[FocusDetect] tick: events=\(events.count) titles=\(titleEvents.count) cooldown=\(cooldownPassed) lastCooldownSec=\(lastCooldownSeconds) windowMin=\(detectionWindowMinutes)")

        let preResult = preScreen(events: events, cooldownPassed: cooldownPassed)
        guard preResult.triggered else {
            print("[FocusDetect] tick: pre-screen not triggered")
            return nil
        }

        print("[FocusDetect] Pre-screen passed: app=\(preResult.triggerApp)")
        isAnalyzing = true
        defer { isAnalyzing = false }

        // ========== Layer 2: Timeline + Metrics ==========
        let timeline = buildTimeline(events: events, windowSeconds: windowSeconds)
        guard !timeline.isEmpty else { return nil }

        let tabSnapshot = tabCache.get(bundleId: preResult.triggerBundleId)

        let allTitleEvents = events.filter { $0.kind == .windowTitle || $0.kind == .tabSwitch }
        let metrics = computeMetrics(
            timeline: timeline,
            triggerApp: preResult.triggerApp,
            tabSnapshot: tabSnapshot,
            allTitleEvents: allTitleEvents
        )
        print("[FocusDetect] Metrics: revisit=\(metrics.revisitCount) tabRatio=\(String(format: "%.0f%%", metrics.browsedTabRatio * 100)) clipRel=\(metrics.clipboardRelevance) focus=\(String(format: "%.0f%%", metrics.triggerAppFocus * 100))")

        // ========== Layer 3: LLM Judgment ==========
        let prompt = buildFocusDetectPrompt(
            timeline: timeline,
            tabSnapshot: tabSnapshot,
            metrics: metrics,
            installedSkills: installedSkillsCache,
            strictness: strictness
        )

        let response = await callOpenClaw(prompt: prompt)
        guard let response, !response.isEmpty else {
            lastDetectTime = Date()
            lastCooldownSeconds = cooldownMissedMinutes * 60
            return nil
        }

        var result = parseFocusDetectResponse(response)

        // Handle ClawHub search if LLM returned searchKeywords
        if result.detected, let keywords = result.searchKeywords, !keywords.isEmpty {
            let communitySkills = await searchClawHub(keywords: keywords)
            if !communitySkills.isEmpty {
                let topSkills = communitySkills.prefix(3).map { $0.name }.joined(separator: "、")
                result.offer = (result.offer ?? "") + "（推荐 skill: " + topSkills + "）"
            }
        }

        // Prepend installed skill mention if not already in offer
        if result.detected, let skill = result.installedSkill, !skill.isEmpty {
            if let offer = result.offer, !offer.contains(skill) {
                result.offer = "试试 " + skill + "。" + offer
            }
        }

        // Update cooldown
        lastDetectTime = Date()
        if result.detected {
            lastCooldownSeconds = cooldownDetectedMinutes * 60
            print("[FocusDetect] Detected: conf=\(result.confidence?.rawValue ?? "?") theme=\(result.theme ?? "?")")
        } else {
            lastCooldownSeconds = cooldownMissedMinutes * 60
            print("[FocusDetect] Not detected")
        }

        return result.detected ? result : nil
    }

    // MARK: - Layer 1: Pre-screen

    private func preScreen(events: [BehaviorEvent], cooldownPassed: Bool) -> PreScreenResult {
        guard cooldownPassed else {
            return PreScreenResult(triggered: false, triggerApp: "", triggerBundleId: "")
        }

        let cutoff = Date().addingTimeInterval(-detectionWindowMinutes * 60)

        let titleEvents = events.filter {
            ($0.kind == .windowTitle || $0.kind == .tabSwitch) && $0.timestamp >= cutoff
        }

        let byApp = Dictionary(grouping: titleEvents, by: { $0.context ?? "" })

        for (app, appEvents) in byApp {
            guard !app.isEmpty else { continue }

            let uniqueTitles = Set(appEvents.map { $0.detail })
            let bundleId = lookupBundleId(forAppName: app, events: events)

            let hasTabSnapshot = tabCache.get(bundleId: bundleId) != nil
            let tabCount = tabCache.get(bundleId: bundleId)?.tabs.count ?? 0

            if hasTabSnapshot {
                if appEvents.count >= 3 && uniqueTitles.count >= 2 && tabCount >= 4 {
                    return PreScreenResult(triggered: true, triggerApp: app, triggerBundleId: bundleId)
                }
            } else {
                if appEvents.count >= 4 && uniqueTitles.count >= 2 {
                    return PreScreenResult(triggered: true, triggerApp: app, triggerBundleId: bundleId)
                }
            }
        }

        return PreScreenResult(triggered: false, triggerApp: "", triggerBundleId: "")
    }

    /// Look up bundleId from recent appSwitch events that recorded the mapping.
    private func lookupBundleId(forAppName name: String, events: [BehaviorEvent]) -> String {
        // Check tabSnapshot events which store appName in detail
        for event in events.reversed() {
            if event.kind == .tabSnapshot && event.detail == name {
                // The bundleId was stored during capture; look it up in tabCache
                for snapshot in tabCache.allValid() {
                    if snapshot.appName == name { return snapshot.bundleId }
                }
            }
        }
        // Fallback: check tabCache directly by app name
        for snapshot in tabCache.allValid() {
            if snapshot.appName == name { return snapshot.bundleId }
        }
        return ""
    }

    // MARK: - Layer 2: Timeline + Metrics

    private func buildTimeline(events: [BehaviorEvent], windowSeconds: TimeInterval) -> [TimelineEntry] {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let recentEvents = events.filter { $0.timestamp >= cutoff }

        var timeline: [TimelineEntry] = []
        var seenTitles = Set<String>()
        var currentTitle = ""

        for event in recentEvents.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.kind {
            case .windowTitle, .tabSwitch:
                let title = event.detail
                let app = event.context ?? ""
                guard title != currentTitle else { continue }

                var entry = TimelineEntry(
                    timestamp: event.timestamp,
                    app: app,
                    title: title
                )
                entry.isRevisit = seenTitles.contains(title)
                seenTitles.insert(title)
                timeline.append(entry)
                currentTitle = title

            case .dwell, .click:
                if let context = event.context, !context.isEmpty,
                   let last = timeline.indices.last {
                    if timeline[last].axContext == nil {
                        timeline[last].axContext = context
                    }
                }

            case .clipboard:
                if let last = timeline.indices.last {
                    if timeline[last].clipboardContent == nil {
                        timeline[last].clipboardContent = event.detail
                    }
                }

            default:
                break
            }
        }

        if timeline.count > 15 {
            return Array(timeline.suffix(15))
        }
        return timeline
    }

    private func computeMetrics(
        timeline: [TimelineEntry],
        triggerApp: String,
        tabSnapshot: TabSnapshotCache.Snapshot?,
        allTitleEvents: [BehaviorEvent]
    ) -> ObjectiveMetrics {
        // 1. Revisit count
        let titleCounts = Dictionary(grouping: timeline, by: { $0.title }).mapValues { $0.count }
        let revisitCount = titleCounts.values.filter { $0 >= 2 }.count

        // 2. Browsed tab ratio
        let browsedTabRatio: Double
        if let snapshot = tabSnapshot {
            let timelineTitles = Set(timeline.map { $0.title })
            let browsedCount = snapshot.tabs.filter { timelineTitles.contains($0.title) }.count
            browsedTabRatio = snapshot.tabs.isEmpty ? 0 : Double(browsedCount) / Double(snapshot.tabs.count)
        } else {
            browsedTabRatio = 0
        }

        // 3. Clipboard relevance
        let clipboards = timeline.compactMap { $0.clipboardContent }
        let titles = timeline.map { $0.title }
        var clipboardRelevance = 0
        for clip in clipboards {
            for title in titles {
                if title.localizedCaseInsensitiveContains(clip) || clip.localizedCaseInsensitiveContains(title) {
                    clipboardRelevance += 1
                    break
                }
            }
        }

        // 4. Trigger app focus
        let triggerAppEvents = allTitleEvents.filter { ($0.context ?? "") == triggerApp }
        let triggerAppFocus = allTitleEvents.isEmpty ? 0 : Double(triggerAppEvents.count) / Double(allTitleEvents.count)

        return ObjectiveMetrics(
            revisitCount: revisitCount,
            browsedTabRatio: browsedTabRatio,
            clipboardRelevance: clipboardRelevance,
            triggerAppFocus: triggerAppFocus
        )
    }

    // MARK: - Layer 3: LLM Prompt + Parse

    private func buildFocusDetectPrompt(
        timeline: [TimelineEntry],
        tabSnapshot: TabSnapshotCache.Snapshot?,
        metrics: ObjectiveMetrics,
        installedSkills: [(name: String, description: String)],
        strictness: Int
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // Timeline text
        var timelineText = ""
        for entry in timeline {
            let time = timeFormatter.string(from: entry.timestamp)
            let revisitMark = entry.isRevisit ? "  <- revisit" : ""
            timelineText += "\(time) [\(entry.app)] \(entry.title)\(revisitMark)\n"
            if let ax = entry.axContext {
                timelineText += "      -> AX: \(ax)\n"
            }
            if let clip = entry.clipboardContent {
                timelineText += "      -> copied: \"\(clip)\"\n"
            }
        }

        // Tab snapshot text
        var tabText = ""
        if let snapshot = tabSnapshot {
            let timelineTitles = Set(timeline.map { $0.title })
            tabText = "--- \(snapshot.appName) all tabs (\(snapshot.tabs.count) total) ---\n"
            for (i, tab) in snapshot.tabs.enumerated() {
                let browsed = timelineTitles.contains(tab.title) ? "  [browsed]" : ""
                let active = tab.isActive ? "  [current]" : ""
                tabText += "\(i + 1). \(tab.title)\(browsed)\(active)\n"
            }
        }

        // Installed skills text
        var skillsText = ""
        if !installedSkills.isEmpty {
            skillsText = "--- Installed skills ---\n"
            for skill in installedSkills {
                skillsText += "- \(skill.name): \(skill.description)\n"
            }
        }

        // Metrics text
        let metricsText = """
        --- Objective Metrics ---
        - Revisit count: \(metrics.revisitCount)
        - Browsed tab ratio: \(String(format: "%.0f%%", metrics.browsedTabRatio * 100))
        - Clipboard relevance: \(metrics.clipboardRelevance)
        - Trigger app focus: \(String(format: "%.0f%%", metrics.triggerAppFocus * 100))
        """

        // Strictness-based high requirement
        let highRequirement: String
        switch strictness {
        case 0:  highRequirement = "at least one of the following objective metrics"
        case 2:  highRequirement = "at least three of the following objective metrics"
        default: highRequirement = "at least two of the following objective metrics"
        }

        return """
        [FOCUS-DETECT] Determine if the user is sustained-focusing on a topic and whether you can help.

        --- Browsing Timeline ---
        \(timelineText)
        \(tabText.isEmpty ? "" : "\(tabText)\n")\(metricsText)

        \(skillsText.isEmpty ? "" : "\(skillsText)\n")--- Your capabilities ---
        Read/write files, run scripts (Python/Node/Shell), operate browsers (Chromium),
        read email, send messages, extract web content, search the web.
        Installed skills above are tools you can use right now.

        --- Confidence criteria ---

        high (ALL must be true):
        1. Specific research subject identified (e.g. "Kweichow Moutai", not vague "stocks")
        2. Specific actionable suggestion possible
        3. \(highRequirement) met: revisit≥1 | tabRatio≥40% | clipRelevance≥1 | appFocus≥60%

        medium: Can identify topic direction but not specific enough, or can help but need more info.

        detected:false: Scattered content, no theme, or has theme but cannot help, or all metrics unmet.

        --- Skill recommendation ---
        - Only recommend installedSkill if it DIRECTLY solves the user's topic (generic tools don't count)
        - If no installed skill matches, provide searchKeywords (specific capabilities, not generic operations)
        - installedSkill and searchKeywords CAN coexist

        --- Response format (strict JSON only) ---
        Character limits: theme≤30, observation≤200, insight≤120, offer≤200.

        CRITICAL: No psychological analysis, emotional judgment, or motive speculation in any field.

        theme: Topic keywords only. ✅ "美股行情" ❌ "强迫性股票检查焦虑"
        observation: Objective behavior facts only. ✅ "1分钟内在Yahoo和Robinhood间切换7次" ❌ "maintained compulsive checking cycle"
        insight: Plain language, what user is doing. ✅ "在对比茅台和五粮液的股价" ❌ "进行多维度的行业横向对比研究"
        offer: What you can do. If installedSkill set, mention it naturally. ✅ "可以帮你自动监控这6只股票，试试 portfolio-watcher"

        Installed skill helps:
        {"detected":true,"confidence":"high/medium","theme":"...","observation":"...","insight":"...","offer":"...","installedSkill":"name"}

        Need community skill:
        {"detected":true,"confidence":"high/medium","theme":"...","observation":"...","insight":"...","offer":"...","searchKeywords":["kw1","kw2"]}

        No theme or cannot help:
        {"detected":false}
        """
    }

    private func parseFocusDetectResponse(_ raw: String) -> FocusDetectResult {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FocusDetectResult(detected: false, confidence: nil, theme: nil,
                                     observation: nil, insight: nil, offer: nil,
                                     installedSkill: nil, searchKeywords: nil)
        }

        let detected = json["detected"] as? Bool ?? false
        guard detected else {
            return FocusDetectResult(detected: false, confidence: nil, theme: nil,
                                     observation: nil, insight: nil, offer: nil,
                                     installedSkill: nil, searchKeywords: nil)
        }

        return FocusDetectResult(
            detected: true,
            confidence: FocusDetectResult.Confidence(rawValue: json["confidence"] as? String ?? ""),
            theme: json["theme"] as? String,
            observation: json["observation"] as? String,
            insight: json["insight"] as? String,
            offer: json["offer"] as? String,
            installedSkill: json["installedSkill"] as? String,
            searchKeywords: json["searchKeywords"] as? [String]
        )
    }

    // MARK: - OpenClaw Call

    private func callOpenClaw(prompt: String) async -> String? {
        do {
            var fullResponse = ""
            let stream = openClawService.executeCommand(prompt: prompt, agentId: "aipointer")
            for try await event in stream {
                switch event {
                case .delta(let chunk):
                    fullResponse += chunk
                case .done, .status, .error:
                    break
                }
            }
            return fullResponse.isEmpty ? nil : fullResponse
        } catch {
            print("[FocusDetect] OpenClaw call failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - ClawHub Search

    private func searchClawHub(keywords: [String]) async -> [(name: String, description: String)] {
        guard !keywords.isEmpty else { return [] }
        let query = keywords.joined(separator: " ")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["clawhub", "search", "--limit", "5", query]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + 3.0)
                timer.setEventHandler { process.terminate() }
                timer.resume()

                do {
                    try process.run()
                    process.waitUntilExit()
                    timer.cancel()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: [])
                        return
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8) else {
                        continuation.resume(returning: [])
                        return
                    }

                    let results = Self.parseClawHubOutput(output)
                    continuation.resume(returning: results)
                } catch {
                    timer.cancel()
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private static func parseClawHubOutput(_ output: String) -> [(name: String, description: String)] {
        var results: [(name: String, description: String)] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
            let components = trimmed.components(separatedBy: "  ").filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }
            let namePart = components[0].components(separatedBy: " ").first ?? ""
            let descPart = components[1].components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !namePart.isEmpty else { continue }
            results.append((namePart, descPart))
        }
        return results
    }

    // MARK: - Installed Skills

    private func getInstalledSkills() -> [(name: String, description: String)] {
        let skillsDir = "/opt/homebrew/lib/node_modules/openclaw/skills"

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) else {
            return []
        }

        var skills: [(name: String, description: String)] = []

        for entry in entries {
            let skillMdPath = "\(skillsDir)/\(entry)/SKILL.md"
            guard FileManager.default.fileExists(atPath: skillMdPath),
                  let content = try? String(contentsOfFile: skillMdPath, encoding: .utf8) else { continue }

            let name = entry
            var description = ""
            for line in content.components(separatedBy: "\n").prefix(10) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(">") && !trimmed.hasPrefix("---") {
                    description = trimmed
                    break
                }
            }
            skills.append((name, description))
        }

        return skills
    }
}
