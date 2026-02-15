import Foundation

enum BehaviorEventKind: String {
    case appSwitch
    case windowTitle
    case clipboard
    case click
    case dwell
    case copy
    case tabSwitch
    case tabSnapshot
    case fileOp
}

struct BehaviorEvent {
    let timestamp: Date
    let kind: BehaviorEventKind
    let detail: String
    let context: String?
}

class BehaviorBuffer {
    private var events: [BehaviorEvent] = []
    private let maxEvents: Int
    private let maxAge: TimeInterval

    init(maxEvents: Int = 400, maxAge: TimeInterval = 600) {
        self.maxEvents = maxEvents
        self.maxAge = maxAge
    }

    func append(_ event: BehaviorEvent) {
        let ctx = event.context.map { " (\($0))" } ?? ""
        print("[Behavior] \(event.kind.rawValue): \(event.detail)\(ctx)")
        events.append(event)
        trim()
    }

    func snapshot(lastSeconds: TimeInterval) -> [BehaviorEvent] {
        let cutoff = Date().addingTimeInterval(-lastSeconds)
        return events.filter { $0.timestamp >= cutoff }
    }

    func recentClipboards(count: Int) -> [BehaviorEvent] {
        return events
            .filter { $0.kind == .clipboard }
            .suffix(count)
            .map { $0 }
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        events = events.filter { $0.timestamp >= cutoff }
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }
    }
}
