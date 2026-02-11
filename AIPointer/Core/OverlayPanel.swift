import Cocoa
import SwiftUI

class OverlayPanel: NSPanel {
    static let shadowPadding: CGFloat = 14

    init(hostingView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0,
                                width: 20 + Self.shadowPadding * 2,
                                height: 20 + Self.shadowPadding * 2),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentView = hostingView
        self.level = .screenSaver
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = false

        // Hide standard window buttons
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        self.contentView?.wantsLayer = true
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

    func updateForState(_ state: PointerState) {
        switch state {
        case .idle:
            ignoresMouseEvents = true
            allowsKeyWindow = false
            setContentSize(paddedSize(20, 20))

        case .input:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            setContentSize(paddedSize(400, 34))

        case .thinking:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            setContentSize(paddedSize(300, 80))

        case .responding, .response:
            ignoresMouseEvents = false
            allowsKeyWindow = true
            setContentSize(paddedSize(420, 280))
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
