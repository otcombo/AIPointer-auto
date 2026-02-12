import Cocoa
import SwiftUI

// MARK: - NSScreen extension for display ID

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }
}

// MARK: - Pass-through hosting view

/// NSHostingView subclass that lets all mouse events pass through to views below.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

// MARK: - Screenshot Overlay Window

/// A borderless, full-screen overlay window for screenshot region selection.
/// One instance is created per display. All instances share the same ScreenshotViewModel.
class ScreenshotOverlayWindow: NSWindow {
    let viewModel: ScreenshotViewModel
    let targetDisplayID: CGDirectDisplayID

    init(screen: NSScreen, viewModel: ScreenshotViewModel) {
        self.viewModel = viewModel
        self.targetDisplayID = screen.displayID

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false

        // Bottom layer: NSView for mouse events + coordinate conversion
        let selectionView = ScreenshotSelectionNSView(frame: screen.frame, viewModel: viewModel, displayID: targetDisplayID)
        selectionView.autoresizingMask = [.width, .height]

        // Top layer: SwiftUI for rendering overlays (mouse events pass through via hitTest override)
        let overlayView = ScreenshotOverlayView(viewModel: viewModel, screenFrame: screen.frame)
        let hostingView = PassThroughHostingView(rootView: overlayView)
        hostingView.frame = selectionView.bounds
        hostingView.autoresizingMask = [.width, .height]

        let container = NSView(frame: screen.frame)
        container.wantsLayer = true
        container.addSubview(selectionView)
        container.addSubview(hostingView)
        self.contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        viewModel.keyDown(keyCode: event.keyCode)
    }
}

// MARK: - Mouse Event Handling NSView

/// Handles mouse events for screenshot selection, converting AppKit coordinates to Quartz.
class ScreenshotSelectionNSView: NSView {
    private let viewModel: ScreenshotViewModel
    private let displayID: CGDirectDisplayID

    init(frame: NSRect, viewModel: ScreenshotViewModel, displayID: CGDirectDisplayID) {
        self.viewModel = viewModel
        self.displayID = displayID
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Convert AppKit window coordinate to Quartz screen coordinate (origin top-left).
    private func toQuartz(_ point: NSPoint) -> NSPoint {
        // Convert from view coordinates to screen coordinates
        guard let window = self.window else { return point }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        // Flip Y: AppKit has origin at bottom-left, Quartz at top-left
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 0
        return NSPoint(x: screenPoint.x, y: mainHeight - screenPoint.y)
    }

    override func mouseDown(with event: NSEvent) {
        let point = toQuartz(convert(event.locationInWindow, from: nil))
        Task { @MainActor in
            viewModel.mouseDown(at: point, displayID: displayID)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = toQuartz(convert(event.locationInWindow, from: nil))
        Task { @MainActor in
            viewModel.mouseDragged(to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = toQuartz(convert(event.locationInWindow, from: nil))
        Task { @MainActor in
            viewModel.mouseUp(at: point, displayID: displayID)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
