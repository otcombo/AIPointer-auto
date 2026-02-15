import Foundation

class BehaviorScorer {
    var sensitivity: Double = 1.0 {
        didSet { sensitivity = max(0.5, min(2.0, sensitivity)) }
    }

    private let baseThreshold = 5

    var threshold: Int {
        max(2, Int(round(Double(baseThreshold) / sensitivity)))
    }

    func score(events: [BehaviorEvent]) -> Int {
        var total = 0
        total += scoreAppSwitching(events)
        total += scoreClipboardFrequency(events)
        total += scoreClipboardSimilarity(events)
        total += scoreDwell(events)
        total += scoreBrowserTabs(events)
        total += scoreFinderOps(events)
        return total
    }

    func shouldTrigger(events: [BehaviorEvent]) -> Bool {
        score(events: events) >= threshold
    }

    // MARK: - Scoring Rules

    /// Cross-app high-frequency switching (+3)
    private func scoreAppSwitching(_ events: [BehaviorEvent]) -> Int {
        let switches = events.filter { $0.kind == .appSwitch }
        guard switches.count >= 4 else { return 0 }

        // Check for rapid switching: 4+ switches in 30 seconds
        let recent = switches.suffix(4)
        if let first = recent.first, let last = recent.last {
            let interval = last.timestamp.timeIntervalSince(first.timestamp)
            if interval <= 30 { return 3 }
        }
        return 0
    }

    /// Clipboard high-frequency changes (+3)
    private func scoreClipboardFrequency(_ events: [BehaviorEvent]) -> Int {
        let clips = events.filter { $0.kind == .clipboard }
        guard clips.count >= 3 else { return 0 }

        let recent = clips.suffix(3)
        if let first = recent.first, let last = recent.last {
            let interval = last.timestamp.timeIntervalSince(first.timestamp)
            if interval <= 30 { return 3 }
        }
        return 0
    }

    /// Clipboard structural similarity (+2)
    private func scoreClipboardSimilarity(_ events: [BehaviorEvent]) -> Int {
        let clips = events.filter { $0.kind == .clipboard }
        guard clips.count >= 3 else { return 0 }

        let recentDetails = clips.suffix(3).map { $0.detail }
        let lengths = recentDetails.map { $0.count }
        let types = recentDetails.map { classifyContent($0) }

        // Length consistency: all within 50% of average
        let avg = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let lengthConsistent = avg > 0 && lengths.allSatisfy {
            Double($0) >= avg * 0.5 && Double($0) <= avg * 1.5
        }

        // Type consistency: all same classification
        let typeConsistent = Set(types).count == 1

        if lengthConsistent && typeConsistent { return 2 }
        return 0
    }

    /// Same-app dwell with low output (+2)
    private func scoreDwell(_ events: [BehaviorEvent]) -> Int {
        let dwells = events.filter { $0.kind == .dwell }
        guard dwells.count >= 2 else { return 0 }

        // 2+ dwells without intervening app switches
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var consecutiveDwells = 0
        for event in sorted.reversed() {
            if event.kind == .dwell {
                consecutiveDwells += 1
            } else if event.kind == .appSwitch {
                break
            }
        }
        return consecutiveDwells >= 2 ? 2 : 0
    }

    /// Browser multi-tab switching (+2)
    private func scoreBrowserTabs(_ events: [BehaviorEvent]) -> Int {
        let tabs = events.filter { $0.kind == .tabSwitch }
        guard tabs.count >= 3 else { return 0 }

        let recent = tabs.suffix(3)
        if let first = recent.first, let last = recent.last {
            let interval = last.timestamp.timeIntervalSince(first.timestamp)
            if interval <= 30 { return 2 }
        }
        return 0
    }

    /// Finder file operations (+2)
    private func scoreFinderOps(_ events: [BehaviorEvent]) -> Int {
        let ops = events.filter { $0.kind == .fileOp }
        return ops.count >= 2 ? 2 : 0
    }

    // MARK: - Helpers

    enum ContentType: Hashable {
        case chinese, english, numeric, mixed
    }

    func classifyContent(_ text: String) -> ContentType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .mixed }

        var hasHan = false
        var hasLatin = false
        var hasDigit = false

        for scalar in trimmed.unicodeScalars {
            if CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains(scalar) {
                hasHan = true
            } else if CharacterSet.letters.contains(scalar) {
                hasLatin = true
            } else if CharacterSet.decimalDigits.contains(scalar) {
                hasDigit = true
            }
        }

        if hasHan && !hasLatin && !hasDigit { return .chinese }
        if hasLatin && !hasHan { return .english }
        if hasDigit && !hasHan && !hasLatin { return .numeric }
        return .mixed
    }
}
