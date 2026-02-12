import Cocoa
import SwiftUI

class OverlayPanel: NSPanel {
    static let shadowPadding: CGFloat = 14

    init(hostingView: NSView) {
        let size = 20 + Self.shadowPadding * 2
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Wrap hosting view in a plain container to prevent NSHostingView
        // from auto-resizing the window to fit its SwiftUI content size.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        self.contentView = container

        self.level = .screenSaver
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = false
    }

    // MARK: - Key window

    private var _canBecomeKeyWindow = false

    var allowsKeyWindow: Bool {
        get { _canBecomeKeyWindow }
        set { _canBecomeKeyWindow = newValue }
    }

    override var canBecomeKey: Bool { _canBecomeKeyWindow }
    override var canBecomeMain: Bool { _canBecomeKeyWindow }

    // Auto-activate accessory app when panel becomes key
    override func becomeKey() {
        super.becomeKey()
        if NSApp.activationPolicy() == .accessory {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Block fn/Globe at the window level to prevent emoji picker.
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 63 { return }
        super.flagsChanged(with: event)
    }

    /// Allow the panel to be positioned anywhere, including over the menu bar and Dock.
    /// Default NSPanel behavior constrains windows to the visible screen area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// Return a custom field editor that suppresses fn key events.
    /// This prevents the text input context from seeing fn and triggering the emoji picker.
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is OrangeCaretTextField {
            return OrangeCaretTextField.fnSuppressingFieldEditor
        }
        return super.fieldEditor(createFlag, for: object)
    }



    // MARK: - State updates

    private func paddedSize(_ w: CGFloat, _ h: CGFloat) -> NSSize {
        NSSize(width: w + Self.shadowPadding * 2,
               height: h + Self.shadowPadding * 2)
    }

    /// Current mouse position in AppKit coordinates (updated by EventTapManager).
    var lastMousePosition: NSPoint = .zero

    /// Timer driving the spring-based collapse animation.
    private var collapseTimer: Timer?

    /// Instantly position the frame so the hotspot (top-left of content) is at `lastMousePosition`.
    private func snapToMouse(width w: CGFloat, height h: CGFloat) {
        collapseTimer?.invalidate()
        collapseTimer = nil

        let size = paddedSize(w, h)
        let p = Self.shadowPadding
        let origin = NSPoint(
            x: lastMousePosition.x - p,
            y: lastMousePosition.y - size.height + p
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(NSRect(origin: origin, size: size), display: false)
        CATransaction.commit()
    }

    /// Animate collapse using easeOut bezier curve (no bounce).
    /// Uses a Timer to drive the curve, updating window frame each tick.
    private func animateCollapse() {
        collapseTimer?.invalidate()

        let duration: Double = 0.25
        let targetSize = paddedSize(20, 20)
        let p = Self.shadowPadding
        let targetOrigin = NSPoint(
            x: lastMousePosition.x - p,
            y: lastMousePosition.y - targetSize.height + p
        )
        let startFrame = frame
        let startTime = CACurrentMediaTime()

        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)

            // easeOut bezier: decelerate towards end
            let progress = 1.0 - pow(1.0 - t, 3.0)

            let x = startFrame.origin.x + (targetOrigin.x - startFrame.origin.x) * progress
            let y = startFrame.origin.y + (targetOrigin.y - startFrame.origin.y) * progress
            let w = startFrame.width + (targetSize.width - startFrame.width) * progress
            let h = startFrame.height + (targetSize.height - startFrame.height) * progress

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
            CATransaction.commit()

            if t >= 1.0 {
                timer.invalidate()
                self.collapseTimer = nil
            }
        }
    }

    func updateForState(_ state: PointerState, inputHeight: CGFloat = 34) {
        switch state {
        case .idle:
            ignoresMouseEvents = true
            allowsKeyWindow = false
            animateCollapse()

        case .input:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            snapToMouse(width: 440, height: inputHeight)

        case .thinking:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            snapToMouse(width: 440, height: 80)

        case .responding, .response:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            snapToMouse(width: 440, height: 280)
        }
    }

    func moveTo(_ point: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = Self.shadowPadding
        setFrameOrigin(NSPoint(x: point.x - p, y: point.y - frame.height + p))
        CATransaction.commit()
    }

    func clampToScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = frame.origin
        if origin.x + frame.width > visible.maxX { origin.x = visible.maxX - frame.width }
        if origin.x < visible.minX { origin.x = visible.minX }
        if origin.y < visible.minY { origin.y = visible.minY }
        if origin.y + frame.height > visible.maxY { origin.y = visible.maxY - frame.height }
        setFrameOrigin(origin)
    }
}
