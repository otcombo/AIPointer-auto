import SwiftUI
import Cocoa
import ObjectiveC
import ScreenCaptureKit

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
    private var openClawService: OpenClawService!
    private var settingsWindow: NSWindow?
    private var isEnabled = true
    private var isFollowingMouse = true

    // Screenshot support
    private var screenshotViewModel: ScreenshotViewModel?
    private var screenshotWindows: [ScreenshotOverlayWindow] = []
    private var panelFrameBeforeScreenshot: NSRect = .zero
    private var screenshotEnteredFromIdle = false

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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "pointer.arrow.ipad.rays", accessibilityDescription: "AI Pointer")?.withSymbolConfiguration(config)
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
        openClawService = OpenClawService()

        // Apply stored settings
        applySettings()

        let rootView = PointerRootView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 48, height: 48)

        overlayPanel = OverlayPanel(hostingView: hostingView)

        // Connect screenshot request (from camera button in input mode)
        viewModel.onScreenshotRequested = { [weak self] in
            self?.screenshotEnteredFromIdle = false
            Task { await self?.startScreenshotMode() }
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

        eventTapManager.onFnShortPress = { [weak self] in
            DispatchQueue.main.async {
                self?.viewModel.onFnPress()
            }
        }

        eventTapManager.onFnLongPress = { [weak self] in
            DispatchQueue.main.async {
                self?.handleFnLongPress()
            }
        }

        // Watch for settings changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )

        // Verification code service — passively monitors for OTP fields
        verificationService = VerificationService()
        verificationService.openClawService = openClawService
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

        let url = (defaults.string(forKey: "backendURL") ?? "http://localhost:18789").trimmingCharacters(in: .whitespacesAndNewlines)

        viewModel.configureAPI(baseURL: url)
        openClawService.configure(baseURL: url)
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    // MARK: - Fn Long Press → Screenshot

    private func handleFnLongPress() {
        switch viewModel.state {
        case .idle:
            // From idle, prepare input state silently and go straight to screenshot
            screenshotEnteredFromIdle = true
            viewModel.prepareForScreenshot()
            Task { await startScreenshotMode() }
        case .input:
            // Already in input mode — trigger screenshot (same as camera button)
            screenshotEnteredFromIdle = false
            Task { await startScreenshotMode() }
        default:
            // thinking/responding/response — ignore
            break
        }
    }

    // MARK: - Screenshot Mode

    private func startScreenshotMode() async {
        // Check Screen Recording permission
        guard await ScreenRecordingPermission.promptIfNeeded() else { return }

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

        // Restore cursor: pop crosshair and force arrow to clear any cursor-rect residue
        NSCursor.pop()
        NSCursor.arrow.set()

        // Brief delay to ensure windows are off-screen, then capture via ScreenCaptureKit
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))

            // Query available displays
            let displays: [SCDisplay]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                displays = content.displays
            } catch {
                print("[Screenshot] Failed to query displays: \(error)")
                self.restoreAfterScreenshot(regions: [])
                return
            }

            guard !displays.isEmpty else {
                print("[Screenshot] No displays available")
                self.restoreAfterScreenshot(regions: [])
                return
            }

            // Capture each region
            var capturedRegions: [SelectedRegion] = []
            for region in regions {
                guard let display = displays.first(where: { $0.displayID == region.displayID })
                        ?? displays.first else { continue }

                // Convert global Quartz coordinates to display-local coordinates.
                // region.rect is in global Quartz space (origin at top-left of primary display).
                // sourceRect expects coordinates relative to the target display's origin.
                let displayOrigin = CGPoint(x: CGFloat(display.frame.origin.x),
                                            y: CGFloat(display.frame.origin.y))
                let localRect = CGRect(x: region.rect.origin.x - displayOrigin.x,
                                       y: region.rect.origin.y - displayOrigin.y,
                                       width: region.rect.width,
                                       height: region.rect.height)

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = localRect
                // Clamp output dimensions:
                // - Max 1568px per side (Anthropic's vision limit; larger images are
                //   downscaled server-side, wasting TTFR without improving quality).
                // - Min 200px shortest side (below this, vision accuracy degrades).
                //   If aspect ratio is too extreme, max takes priority over min.
                let maxDim: CGFloat = 1568
                let minDim: CGFloat = 200
                var outW = region.rect.width
                var outH = region.rect.height
                // Step 1: Downscale so neither side exceeds maxDim
                let downScale = min(maxDim / outW, maxDim / outH, 1.0)
                outW *= downScale; outH *= downScale
                // Step 2: Upscale so shortest side reaches minDim (if possible
                // without exceeding maxDim on the other side)
                let shortSide = min(outW, outH)
                if shortSide < minDim {
                    let maxUpScale = min(maxDim / outW, maxDim / outH)
                    let upScale = min(minDim / shortSide, maxUpScale)
                    outW *= upScale; outH *= upScale
                }
                config.width = Int(outW)
                config.height = Int(outH)
                config.showsCursor = false
                config.captureResolution = .best

                if let cgImage = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                ) {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    print("[Screenshot] region=\(region.rect) localRect=\(localRect) cgImage=\(cgImage.width)x\(cgImage.height)")
                    if let b64 = OpenClawService.toBase64JPEG(nsImage) {
                        print("[Screenshot] base64 length=\(b64.count) chars (\(b64.count * 3 / 4 / 1024)KB)")
                    }
                    let debugPath = NSString(string: "~/Desktop/debug_screenshot_\(capturedRegions.count).png").expandingTildeInPath
                    if let tiff = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: debugPath))
                        print("[Screenshot] saved to \(debugPath)")
                    }
                    var captured = region
                    captured.snapshot = nsImage
                    capturedRegions.append(captured)
                }
            }

            self.restoreAfterScreenshot(regions: capturedRegions)
        }
    }

    /// Clean up screenshot state and restore the overlay panel.
    private func restoreAfterScreenshot(regions: [SelectedRegion]) {
        screenshotWindows = []
        screenshotViewModel = nil

        viewModel.attachScreenshots(regions)

        cursorHider.hide()
        overlayPanel.orderFrontRegardless()

        overlayPanel.updateForState(viewModel.state)
        overlayPanel.ignoresMouseEvents = false
        overlayPanel.allowsKeyWindow = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            self.overlayPanel.makeKeyAndOrderFront(nil)
            self.focusTextField()
        }
    }

    private func cancelScreenshot() {
        // Hide all screenshot overlay windows
        for window in screenshotWindows {
            window.orderOut(nil)
        }

        // Restore cursor: pop crosshair and force arrow to clear any cursor-rect residue
        NSCursor.pop()
        NSCursor.arrow.set()

        // Clean up
        let fromIdle = screenshotEnteredFromIdle
        screenshotWindows = []
        screenshotViewModel = nil
        screenshotEnteredFromIdle = false

        if fromIdle {
            // Entered from idle via FN long press — return to idle (default pointer, no panel)
            // Re-show overlay panel first (it serves as the custom cursor in idle mode)
            overlayPanel.orderFrontRegardless()
            viewModel.dismiss()
        } else {
            // Entered from input mode — restore panel and focus text field
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlayPanel.setFrame(panelFrameBeforeScreenshot, display: false)
            CATransaction.commit()

            cursorHider.hide()
            overlayPanel.orderFrontRegardless()

            overlayPanel.ignoresMouseEvents = false
            overlayPanel.allowsKeyWindow = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                self.overlayPanel.makeKeyAndOrderFront(nil)
                self.focusTextField()
            }
        }
    }

    /// Recursively find and focus the OrangeCaretTextField in the panel.
    /// Retries with increasing delays to wait for SwiftUI layout.
    private func focusTextField(attempt: Int = 0) {
        guard let contentView = overlayPanel.contentView else { return }
        if let textField = findTextField(in: contentView) {
            overlayPanel.makeFirstResponder(textField)
            return
        }
        // Retry up to 5 times with increasing delays
        if attempt < 5 {
            let delay = 0.05 * Double(attempt + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.focusTextField(attempt: attempt + 1)
            }
        }
    }

    private func findTextField(in view: NSView) -> OrangeCaretTextField? {
        if let tf = view as? OrangeCaretTextField { return tf }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI Pointer Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 420))
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
