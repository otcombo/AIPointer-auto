import Cocoa
import Combine

enum ScreenshotPhase {
    case selecting
    case dragging(origin: NSPoint, current: NSPoint)
    case completed
    case cancelled
}

@MainActor
class ScreenshotViewModel: ObservableObject {
    static let maxRegions = 5

    @Published var regions: [SelectedRegion] = []
    @Published private(set) var phase: ScreenshotPhase = .selecting

    var onComplete: (([SelectedRegion]) -> Void)?
    var onCancel: (() -> Void)?

    /// The current drag rectangle in Quartz coordinates, if dragging.
    var currentDragRect: CGRect? {
        guard case .dragging(let origin, let current) = phase else { return nil }
        let x = min(origin.x, current.x)
        let y = min(origin.y, current.y)
        let w = abs(current.x - origin.x)
        let h = abs(current.y - origin.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Mouse events (called from NSView, coordinates already in Quartz)

    func mouseDown(at point: NSPoint, displayID: CGDirectDisplayID) {
        guard case .selecting = phase, regions.count < Self.maxRegions else { return }
        phase = .dragging(origin: point, current: point)
    }

    func mouseDragged(to point: NSPoint) {
        guard case .dragging(let origin, _) = phase else { return }
        phase = .dragging(origin: origin, current: point)
    }

    func mouseUp(at point: NSPoint, displayID: CGDirectDisplayID) {
        guard case .dragging(let origin, _) = phase else { return }

        let x = min(origin.x, point.x)
        let y = min(origin.y, point.y)
        let w = abs(point.x - origin.x)
        let h = abs(point.y - origin.y)

        // Minimum 10x10 threshold to filter accidental clicks
        guard w >= 10 && h >= 10 else {
            phase = .selecting
            return
        }

        let rect = CGRect(x: x, y: y, width: w, height: h)
        let region = SelectedRegion(rect: rect, displayID: displayID)
        regions.append(region)
        phase = .selecting
    }

    // MARK: - Keyboard

    func keyDown(keyCode: UInt16) {
        switch keyCode {
        case 53: // Escape
            cancel()
        case 36: // Enter/Return
            confirm()
        case 51: // Backspace/Delete
            undoLastRegion()
        default:
            break
        }
    }

    func confirm() {
        phase = .completed
        onComplete?(regions)
    }

    func cancel() {
        phase = .cancelled
        onCancel?()
    }

    func undoLastRegion() {
        guard !regions.isEmpty else { return }
        regions.removeLast()
    }
}
