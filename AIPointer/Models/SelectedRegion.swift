import Cocoa

struct SelectedRegion: Identifiable, Equatable {
    let id: UUID
    let rect: CGRect              // Quartz coordinates (origin top-left)
    let displayID: CGDirectDisplayID
    var snapshot: NSImage?

    init(rect: CGRect, displayID: CGDirectDisplayID, snapshot: NSImage? = nil) {
        self.id = UUID()
        self.rect = rect
        self.displayID = displayID
        self.snapshot = snapshot
    }

    static func == (lhs: SelectedRegion, rhs: SelectedRegion) -> Bool {
        lhs.id == rhs.id
    }
}
