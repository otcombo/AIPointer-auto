import Foundation

struct BehaviorAnalysis {
    enum Confidence: String {
        case high, medium, low
    }
    let confidence: Confidence
    let observation: String
    let suggestion: String
}

class BehaviorSensingService {
    let buffer = BehaviorBuffer()
    let scorer = BehaviorScorer()
    let monitor: BehaviorMonitor

    var openClawService: OpenClawService?
    var onAnalysisResult: ((BehaviorAnalysis) -> Void)?

    var sensitivity: Double {
        get { scorer.sensitivity }
        set { scorer.sensitivity = newValue }
    }

    private(set) var isRunning = false
    private(set) var isAnalyzing = false
    private var evaluationTimer: Timer?
    private var lastAnalysisTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 30

    init() {
        monitor = BehaviorMonitor(buffer: buffer)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()

        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    func stop() {
        isRunning = false
        monitor.stop()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
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
        let prompt = buildPrompt(events: compressed)

        Task {
            defer {
                self.isAnalyzing = false
                self.lastAnalysisTime = Date()
            }

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

    private func buildPrompt(events: [BehaviorEvent]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        lines.append("You are analyzing a user's desktop behavior to detect repetitive patterns and offer proactive help.")
        lines.append("Below is a timeline of recent user actions. Analyze for repetitive patterns.")
        lines.append("")
        lines.append("Timeline:")

        for event in events {
            let time = formatter.string(from: event.timestamp)
            var line = "[\(time)] \(event.kind.rawValue): \(event.detail)"
            if let ctx = event.context {
                line += " (\(ctx))"
            }
            lines.append(line)
        }

        lines.append("")
        lines.append("Respond with JSON only:")
        lines.append("""
        {"confidence": "high|medium|low", "observation": "what pattern you detected", "suggestion": "how you can help"}
        """)
        lines.append("")
        lines.append("Rules:")
        lines.append("- confidence=high: clear repetitive pattern that could be automated")
        lines.append("- confidence=medium: likely pattern, user might benefit from help")
        lines.append("- confidence=low: no clear pattern or too little data")
        lines.append("- observation: concise description of what the user is doing (1 sentence)")
        lines.append("- suggestion: specific actionable help you can provide (1 sentence)")

        return lines.joined(separator: "\n")
    }

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
        let suggestion = json["suggestion"] as? String ?? ""

        return BehaviorAnalysis(confidence: confidence, observation: observation, suggestion: suggestion)
    }
}
