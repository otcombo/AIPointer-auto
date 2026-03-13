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

    private var lastDetectTime: Date = .distantPast
    private var lastCooldownSeconds: TimeInterval = 120
    private(set) var isAnalyzing = false

    var detectionWindowMinutes: Double = 5.0
    var cooldownDetectedMinutes: Double = 10.0
    var cooldownMissedMinutes: Double = 2.0
    var strictness: Int = 1

    init(buffer: BehaviorBuffer, tabCache: TabSnapshotCache) {
        self.buffer = buffer
        self.tabCache = tabCache
    }

    /// Called every 30 seconds by BehaviorSensingService.
    /// Currently disabled — requires AI backend integration to function.
    func tick() async -> FocusDetectResult? {
        // Focus detection requires an AI backend for LLM judgment.
        // To re-enable, integrate with the Anthropic Messages API directly.
        return nil
    }

}
