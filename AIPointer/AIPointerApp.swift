import SwiftUI
import Cocoa
import ObjectiveC

@main
struct AIPointerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel!
    private var eventTapManager: EventTapManager!
    private var cursorHider: CursorHider!
    private var viewModel: PointerViewModel!
    private var verificationService: VerificationService!
    private var settingsWindow: NSWindow?
    private var isEnabled = true
    private var isFollowingMouse = true

    // Screenshot support
    private var screenshotViewModel: ScreenshotViewModel?
    private var screenshotWindows: [ScreenshotOverlayWindow] = []
    private var panelFrameBeforeScreenshot: NSRect = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        swizzleCharacterPalette()
        setupMenuBar()
        checkPermissionsAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cursorHider?.restore()
        eventTapManager?.stop()
        verificationService?.stop()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "AI Pointer")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AI Pointer", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.state = .on
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Swizzle NSApplication.orderFrontCharacterPalette as extra safety layer.
    private func swizzleCharacterPalette() {
        let original = #selector(NSApplication.orderFrontCharacterPalette(_:))
        let swizzled = #selector(NSApplication.noopCharacterPalette(_:))
        guard let m1 = class_getInstanceMethod(NSApplication.self, original),
              let m2 = class_getInstanceMethod(NSApplication.self, swizzled) else { return }
        method_exchangeImplementations(m1, m2)
    }

    private func checkPermissionsAndStart() {
        if EventTapManager.checkPermission() {
            startPointerSystem()
        } else {
            EventTapManager.requestPermission()
            let alert = NSAlert()
            alert.messageText = "Input Monitoring Required"
            alert.informativeText = "AI Pointer needs Input Monitoring permission to track mouse movement and keyboard events.\n\nPlease grant access in System Settings → Privacy & Security → Input Monitoring, then relaunch the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private func startPointerSystem() {
        cursorHider = CursorHider()
        viewModel = PointerViewModel()
        eventTapManager = EventTapManager()

        // Apply stored settings
        applySettings()

        let rootView = PointerRootView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 48, height: 48)

        overlayPanel = OverlayPanel(hostingView: hostingView)

        // Connect screenshot request
        viewModel.onScreenshotRequested = { [weak self] in
            self?.startScreenshotMode()
        }

        // React to every state change
        viewModel.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.isFollowingMouse = !state.isFixed
            self.overlayPanel.updateForState(state)

            switch state {
            case .idle:
                self.overlayPanel.allowsKeyWindow = false
                self.overlayPanel.ignoresMouseEvents = true
                self.cursorHider.hide()

            case .monitoring, .codeReady:
                self.overlayPanel.ignoresMouseEvents = true
                self.overlayPanel.allowsKeyWindow = false
                self.cursorHider.hide()

            case .input, .thinking, .responding, .response:
                self.overlayPanel.ignoresMouseEvents = false
                self.overlayPanel.allowsKeyWindow = true
                // Keep cursor hidden initially; show on first mouse move (see onMouseMoved)

                // Delay to next run loop so SwiftUI has laid out the TextField
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.activate(ignoringOtherApps: true)
                    self.overlayPanel.makeKeyAndOrderFront(nil)
                    // contentView is the container; the hosting view is its first subview
                    if let hostingView = self.overlayPanel.contentView?.subviews.first {
                        self.overlayPanel.makeFirstResponder(hostingView)
                    }
                }

                if state.isFixed {
                    self.overlayPanel.clampToScreen()
                }
            }
        }

        eventTapManager.onMouseMoved = { [weak self] point in
            guard let self else { return }
            self.overlayPanel.lastMousePosition = point
            if self.isFollowingMouse {
                self.overlayPanel.moveTo(point)
            } else {
                // Panel is fixed (input/thinking/response) — show cursor on mouse move
                self.cursorHider.restore()
            }
        }

        eventTapManager.onFnKeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel.onFnPress()
            }
        }

        // Watch for settings changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )

        // Verification code service — passively monitors for OTP fields
        verificationService = VerificationService()
        verificationService.onStateChanged = { [weak self] state in
            self?.viewModel.updateVerificationState(state)
        }
        verificationService.start()

        eventTapManager.start()
        cursorHider.hide()
        overlayPanel.orderFrontRegardless()
    }

    private func applySettings() {
        let defaults = UserDefaults.standard
        eventTapManager.suppressFnKey = defaults.object(forKey: "suppressFnKey") as? Bool ?? true
        eventTapManager.longPressDuration = defaults.double(forKey: "longPressDuration") // 0 = instant

        let url = defaults.string(forKey: "backendURL") ?? ""
        let token = defaults.string(forKey: "authToken") ?? ""
        let agentId = defaults.string(forKey: "agentId") ?? "main"
        viewModel.configureAPI(baseURL: url, authToken: token, agentId: agentId)
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    // MARK: - Screenshot Mode

    private func startScreenshotMode() {
        // Check Screen Recording permission
        guard ScreenRecordingPermission.promptIfNeeded() else { return }

        // Save panel position so we can restore it on cancel
        panelFrameBeforeScreenshot = overlayPanel.frame

        // Hide the overlay panel and restore system cursor
        overlayPanel.orderOut(nil)
        cursorHider.restore()

        // Set crosshair cursor
        NSCursor.crosshair.push()

        // Create screenshot view model, continuing numbering from existing attachments
        let ssViewModel = ScreenshotViewModel()
        ssViewModel.existingCount = viewModel.attachedImages.count
        screenshotViewModel = ssViewModel

        // Create overlay window for each screen
        screenshotWindows = NSScreen.screens.map { screen in
            ScreenshotOverlayWindow(screen: screen, viewModel: ssViewModel)
        }

        // Connect callbacks
        ssViewModel.onComplete = { [weak self] regions in
            self?.completeScreenshot(regions: regions)
        }

        ssViewModel.onCancel = { [weak self] in
            self?.cancelScreenshot()
        }

        // Show all overlay windows, make the main screen's window key
        for (index, window) in screenshotWindows.enumerated() {
            window.orderFrontRegardless()
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func completeScreenshot(regions: [SelectedRegion]) {
        // Hide all screenshot overlay windows first (to avoid capturing them)
        for window in screenshotWindows {
            window.orderOut(nil)
        }

        // Pop crosshair cursor
        NSCursor.pop()

        // Brief delay to ensure windows are off-screen before capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }

            // Capture each region
            var capturedRegions: [SelectedRegion] = []
            for region in regions {
                if let cgImage = CGWindowListCreateImage(
                    region.rect,
                    .optionOnScreenOnly,
                    kCGNullWindowID,
                    [.bestResolution]
                ) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    var captured = region
                    captured.snapshot = nsImage
                    capturedRegions.append(captured)
                }
            }

            // Clean up
            self.screenshotWindows = []
            self.screenshotViewModel = nil

            // Attach screenshots and restore overlay
            self.viewModel.attachScreenshots(capturedRegions)

            // Re-hide system cursor and show overlay panel
            self.cursorHider.hide()
            self.overlayPanel.orderFrontRegardless()

            // Re-activate the panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                self.overlayPanel.makeKeyAndOrderFront(nil)
                if let hostingView = self.overlayPanel.contentView?.subviews.first {
                    self.overlayPanel.makeFirstResponder(hostingView)
                }
                // Force state update to resize panel for attachments
                self.viewModel.onStateChanged?(self.viewModel.state)
            }
        }
    }

    private func cancelScreenshot() {
        // Hide all screenshot overlay windows
        for window in screenshotWindows {
            window.orderOut(nil)
        }

        // Pop crosshair cursor
        NSCursor.pop()

        // Clean up
        screenshotWindows = []
        screenshotViewModel = nil

        // Restore panel at its original position (not current mouse position)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayPanel.setFrame(panelFrameBeforeScreenshot, display: false)
        CATransaction.commit()

        // Re-hide system cursor and show overlay panel
        cursorHider.hide()
        overlayPanel.orderFrontRegardless()

        // Re-activate the panel and restore input focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            self.overlayPanel.makeKeyAndOrderFront(nil)
            if let hostingView = self.overlayPanel.contentView?.subviews.first {
                self.overlayPanel.makeFirstResponder(hostingView)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI Pointer Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 260))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled {
            cursorHider.hide()
            eventTapManager.start()
            verificationService.start()
            overlayPanel.orderFrontRegardless()
        } else {
            cursorHider.restore()
            eventTapManager.stop()
            verificationService.stop()
            overlayPanel.orderOut(nil)
        }

        if let menu = statusItem.menu,
           let toggleItem = menu.item(at: 2) {
            toggleItem.state = isEnabled ? .on : .off
        }
    }

    @objc private func quit() {
        cursorHider.restore()
        NSApp.terminate(nil)
    }
}

// MARK: - Swizzle target

extension NSApplication {
    @objc func noopCharacterPalette(_ sender: Any?) {
        // Intentionally empty — blocks emoji picker via orderFrontCharacterPalette
    }
}
