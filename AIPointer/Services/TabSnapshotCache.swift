import Foundation

struct TabInfo {
    let title: String
    let isActive: Bool
}

class TabSnapshotCache {
    struct Snapshot {
        let appName: String
        let bundleId: String
        let tabs: [TabInfo]
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var cache: [String: Snapshot] = [:]

    func store(appName: String, bundleId: String, tabs: [TabInfo]) {
        lock.lock()
        defer { lock.unlock() }
        cache[bundleId] = Snapshot(
            appName: appName,
            bundleId: bundleId,
            tabs: tabs,
            capturedAt: Date()
        )
    }

    func get(bundleId: String, maxAge: TimeInterval = 300) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = cache[bundleId],
              Date().timeIntervalSince(snapshot.capturedAt) <= maxAge else {
            return nil
        }
        return snapshot
    }

    func allValid(maxAge: TimeInterval = 300) -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return cache.values.filter { now.timeIntervalSince($0.capturedAt) <= maxAge }
    }
}
