import Foundation

struct BehaviorAnalysis {
    enum Confidence: String {
        case high, medium, low
    }
    let confidence: Confidence
    let observation: String
    let insight: String
    let offer: String
    
    var suggestion: String {
        let defaults = UserDefaults.standard
        let showObservation = defaults.object(forKey: "focusShowObservation") as? Bool ?? true
        let showInsight = defaults.object(forKey: "focusShowInsight") as? Bool ?? true
        let showOffer = defaults.object(forKey: "focusShowOffer") as? Bool ?? true
        let language = defaults.string(forKey: "responseLanguage") ?? defaultResponseLanguage
        let isChinese = language == "zh-CN"
        
        var parts: [String] = []
        
        if showObservation && !observation.isEmpty {
            let title = isChinese ? "观察" : "Observation"
            parts.append("\(title)\n\(observation)")
        }
        if showInsight && !insight.isEmpty {
            let title = isChinese ? "推测" : "Insight"
            parts.append("\(title)\n\(insight)")
        }
        if showOffer && !offer.isEmpty {
            let title = isChinese ? "建议" : "Offer"
            parts.append("\(title)\n\(offer)")
        }
        
        return parts.joined(separator: "\n\n")
    }
}

class BehaviorSensingService {
    let buffer = BehaviorBuffer()
    let scorer = BehaviorScorer()
    let monitor: BehaviorMonitor
    let tabSnapshotCache = TabSnapshotCache()

    var openClawService: OpenClawService?
    var onAnalysisResult: ((BehaviorAnalysis) -> Void)?

    var sensitivity: Double {
        get { scorer.sensitivity }
        set { scorer.sensitivity = newValue }
    }

    // Focus detection
    var focusDetectionService: FocusDetectionService?
    private var focusDetectionTimer: Timer?
    private(set) var isFocusDetectionRunning = false

    private(set) var isRunning = false
    private(set) var isAnalyzing = false
    private var evaluationTimer: Timer?
    private var lastAnalysisTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 30

    init() {
        monitor = BehaviorMonitor(buffer: buffer)
        monitor.tabSnapshotCache = tabSnapshotCache
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()

        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }

        // Start focus detection if enabled
        let focusEnabled = UserDefaults.standard.object(forKey: "focusDetectionEnabled") as? Bool ?? true
        if focusEnabled {
            startFocusDetection()
        }
    }

    func stop() {
        isRunning = false
        monitor.stop()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        stopFocusDetection()
    }

    // MARK: - Focus Detection

    func startFocusDetection() {
        guard let openClaw = openClawService else { return }
        guard !isFocusDetectionRunning else { return }

        focusDetectionService = FocusDetectionService(
            buffer: buffer,
            tabCache: tabSnapshotCache,
            openClawService: openClaw
        )
        applyFocusDetectionSettings()
        isFocusDetectionRunning = true

        focusDetectionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                guard let result = await self.focusDetectionService?.tick() else { return }

                let defaults = UserDefaults.standard
                let showObservation = defaults.object(forKey: "focusShowObservation") as? Bool ?? true
                let showInsight = defaults.object(forKey: "focusShowInsight") as? Bool ?? true
                let showOffer = defaults.object(forKey: "focusShowOffer") as? Bool ?? true

                guard result.displayText(
                    showObservation: true,
                    showInsight: true,
                    showOffer: true
                ) != nil else { return }

                let analysis = BehaviorAnalysis(
                    confidence: result.confidence == .high ? .high : .medium,
                    observation: result.observation ?? "",
                    insight: result.insight ?? "",
                    offer: result.offer ?? ""
                )

                DispatchQueue.main.async {
                    self.onAnalysisResult?(analysis)
                }
            }
        }
        print("[FocusDetect] Started")
    }

    func stopFocusDetection() {
        focusDetectionTimer?.invalidate()
        focusDetectionTimer = nil
        isFocusDetectionRunning = false
    }

    func applyFocusDetectionSettings() {
        let defaults = UserDefaults.standard
        let window = defaults.double(forKey: "focusDetectionWindow")
        focusDetectionService?.detectionWindowMinutes = window > 0 ? min(max(window, 3), 10) : 5

        let cooldownDetected = defaults.object(forKey: "focusCooldownDetected") as? Double ?? 10
        focusDetectionService?.cooldownDetectedMinutes = min(max(cooldownDetected, 0), 30)

        let cooldownMissed = defaults.object(forKey: "focusCooldownMissed") as? Double ?? 2
        focusDetectionService?.cooldownMissedMinutes = min(max(cooldownMissed, 0), 5)

        focusDetectionService?.strictness = defaults.integer(forKey: "focusStrictness")
    }

    private func evaluate() {
        guard !isAnalyzing else { return }
        guard Date().timeIntervalSince(lastAnalysisTime) >= cooldownSeconds else { return }

        let events = buffer.snapshot(lastSeconds: 120) // 2-minute window
        let currentScore = scorer.score(events: events)
        if currentScore > 0 {
            print("[BehaviorSensing] score=\(currentScore) threshold=\(scorer.threshold) events=\(events.count)")
        }
        guard currentScore >= scorer.threshold else { return }

        print("[BehaviorSensing] Threshold reached! Triggering analysis...")
        analyze()
    }

    private func analyze() {
        guard let service = openClawService else { return }
        isAnalyzing = true

        let events = buffer.snapshot(lastSeconds: 180) // 3-minute window
        let compressed = compressEvents(events, maxCount: 30)
        let keywords = extractKeywords(from: compressed)

        Task {
            defer {
                self.isAnalyzing = false
                self.lastAnalysisTime = Date()
            }

            // Search for relevant skills (non-blocking, 2s timeout)
            var skills: [(name: String, description: String)] = []
            if !keywords.isEmpty {
                print("[BehaviorSensing] Keywords: \(keywords.joined(separator: ", "))")
                skills = await searchSkills(keywords: keywords)
                if !skills.isEmpty {
                    print("[BehaviorSensing] Found skills: \(skills.map { $0.name }.joined(separator: ", "))")
                }
            }

            let prompt = buildPrompt(events: compressed, skills: skills)

            do {
                var fullResponse = ""
                let stream = service.executeCommand(prompt: prompt, agentId: "aipointer")
                for try await event in stream {
                    switch event {
                    case .delta(let chunk):
                        fullResponse += chunk
                    case .done, .status, .error:
                        break
                    }
                }

                if let analysis = parseAnalysis(fullResponse) {
                    print("[BehaviorSensing] Analysis result: confidence=\(analysis.confidence.rawValue) observation=\(analysis.observation)")
                    if analysis.confidence != .low {
                        DispatchQueue.main.async {
                            self.onAnalysisResult?(analysis)
                        }
                    }
                } else {
                    print("[BehaviorSensing] Failed to parse response: \(String(fullResponse.prefix(200)))")
                }
            } catch {
                print("[BehaviorSensing] Analysis failed: \(error.localizedDescription)")
            }
        }
    }

    private func compressEvents(_ events: [BehaviorEvent], maxCount: Int) -> [BehaviorEvent] {
        guard events.count > maxCount else { return events }
        // Keep evenly spaced events plus always keep the most recent ones
        let keepRecent = min(10, maxCount / 3)
        let keepEarlier = maxCount - keepRecent
        let earlier = Array(events.dropLast(keepRecent))
        let stride = max(1, earlier.count / keepEarlier)
        var result: [BehaviorEvent] = []
        for i in Swift.stride(from: 0, to: earlier.count, by: stride) {
            result.append(earlier[i])
            if result.count >= keepEarlier { break }
        }
        result.append(contentsOf: events.suffix(keepRecent))
        return result
    }

    private func buildPrompt(events: [BehaviorEvent], skills: [(name: String, description: String)] = []) -> String {
        let language = UserDefaults.standard.string(forKey: "responseLanguage") ?? defaultResponseLanguage
        let isChinese = language == "zh-CN"
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        
        if isChinese {
            lines.append("你在分析用户的桌面操作行为，检测重复模式并主动提供帮助。")
            lines.append("以下是用户最近的操作时间线。分析是否有重复模式。")
            lines.append("重要：只描述客观行为事实，不做心理分析、情绪判断或动机猜测。")
        } else {
            lines.append("You are analyzing a user's desktop behavior to detect repetitive patterns and offer proactive help.")
            lines.append("Below is a timeline of recent user actions. Analyze for repetitive patterns.")
            lines.append("Important: Only describe objective behavior facts. No psychological analysis, emotional judgment, or motive speculation.")
        }
        
        lines.append("")
        lines.append(isChinese ? "--- 时间线 ---" : "--- Timeline ---")

        for event in events {
            let time = formatter.string(from: event.timestamp)
            var line = "[\(time)] \(event.kind.rawValue): \(event.detail)"
            if let ctx = event.context {
                line += " (\(ctx))"
            }
            lines.append(line)
        }

        if !skills.isEmpty {
            lines.append("")
            lines.append(isChinese ? "--- 相关技能 (来自 ClawHub) ---" : "--- Related Skills (from ClawHub) ---")
            for skill in skills {
                lines.append("- \(skill.name): \(skill.description)")
            }
        }

        lines.append("")
        lines.append(isChinese ? "--- 你的能力 ---" : "--- Your capabilities ---")
        
        if isChinese {
            lines.append("你可以：读写文件、运行脚本（Python/Node/Shell）、操作浏览器、读邮件、发消息、提取网页内容、搜索网络。")
            if !skills.isEmpty {
                lines.append("如果上面列出的技能相关，在建议中提到它。否则根据你自己的能力给建议。")
            }
        } else {
            lines.append("You can: read/write files, run scripts (Python/Node/Shell), operate browsers, read email, send messages, extract web content, search the web.")
            if !skills.isEmpty {
                lines.append("If a listed Skill above is relevant, recommend it in your suggestion. Otherwise, suggest based on your own capabilities.")
            }
        }

        lines.append("")
        lines.append(isChinese ? "只返回 JSON：" : "Respond with JSON only:")
        
        if isChinese {
            lines.append("""
            {"confidence": "high|medium|low", "observation": "检测到什么模式", "insight": "用户在做什么", "offer": "如何帮忙"}
            """)
            lines.append("")
            lines.append("规则：")
            lines.append("- confidence=high: 明确的重复模式，可以自动化")
            lines.append("- confidence=medium: 可能的模式，用户可能需要帮助")
            lines.append("- confidence=low: 没有明确模式或数据太少")
            lines.append("- observation: 客观事实（一句话，如「30秒内在A和B间切换4次」）")
            lines.append("- insight: 用户在做什么（一句话，如「在对比两个产品的价格」，不分析情绪或动机）")
            lines.append("- offer: 你能提供的具体可操作帮助（一句话）")
        } else {
            lines.append("""
            {"confidence": "high|medium|low", "observation": "what pattern you detected", "insight": "what the user is doing", "offer": "how you can help"}
            """)
            lines.append("")
            lines.append("Rules:")
            lines.append("- confidence=high: clear repetitive pattern that could be automated")
            lines.append("- confidence=medium: likely pattern, user might benefit from help")
            lines.append("- confidence=low: no clear pattern or too little data")
            lines.append("- observation: objective facts only (1 sentence, e.g. 'Switched between A and B 4 times in 30s')")
            lines.append("- insight: what the user is doing (1 sentence, e.g. 'Comparing prices of two products', no emotion/motive analysis)")
            lines.append("- offer: specific actionable help you can provide (1 sentence)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Skill Search

    private static let appKeywords = ["excel", "chrome", "safari", "finder", "mail", "slack",
                                       "keynote", "pages", "numbers", "vscode", "xcode",
                                       "notion", "figma", "sketch", "terminal", "iterm"]

    private func extractKeywords(from events: [BehaviorEvent]) -> [String] {
        var keywords = Set<String>()

        for event in events {
            switch event.kind {
            case .appSwitch, .windowTitle, .copy, .click, .dwell:
                let detail = event.detail.lowercased()
                let context = (event.context ?? "").lowercased()
                for app in Self.appKeywords {
                    if detail.contains(app) || context.contains(app) {
                        keywords.insert(app)
                    }
                }

            case .clipboard:
                let content = event.detail
                if content.contains("http://") || content.contains("https://") {
                    keywords.insert("web")
                }
                if content.contains("\t") || content.range(of: #"(\w+,){2,}"#, options: .regularExpression) != nil {
                    keywords.insert("table")
                }

            case .tabSwitch:
                keywords.insert("browser")

            case .tabSnapshot:
                keywords.insert("browser")

            case .fileOp:
                keywords.insert("file")
            }
        }

        return Array(keywords.prefix(3))
    }

    private func searchSkills(keywords: [String]) async -> [(name: String, description: String)] {
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

                // 2s timeout
                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + 2.0)
                timer.setEventHandler {
                    process.terminate()
                }
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

                    let results = self.parseClawHubOutput(output)
                    continuation.resume(returning: results)
                } catch {
                    timer.cancel()
                    print("[BehaviorSensing] Skill search failed: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func parseClawHubOutput(_ output: String) -> [(name: String, description: String)] {
        var results: [(name: String, description: String)] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }

            // Format: skill-name v1.0.0  Description text here  (score)
            let components = trimmed.components(separatedBy: "  ").filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }

            let namePart = components[0].components(separatedBy: " ").first ?? ""
            let descPart = components[1].components(separatedBy: "(").first?
                .trimmingCharacters(in: .whitespaces) ?? ""

            guard !namePart.isEmpty else { continue }
            results.append((name: namePart, description: descPart))
        }

        return results
    }

    // MARK: - Response Parsing

    private func parseAnalysis(_ text: String) -> BehaviorAnalysis? {
        // Strip markdown code block markers (LLMs commonly wrap JSON in ```json ... ```)
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let confidenceStr = json["confidence"] as? String else {
            return nil
        }

        let confidence: BehaviorAnalysis.Confidence
        switch confidenceStr.lowercased() {
        case "high": confidence = .high
        case "medium": confidence = .medium
        default: confidence = .low
        }

        let observation = json["observation"] as? String ?? ""
        let insight = json["insight"] as? String ?? ""
        let offer = json["offer"] as? String ?? ""

        return BehaviorAnalysis(confidence: confidence, observation: observation, insight: insight, offer: offer)
    }
}
