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
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel!
    private var eventTapManager: EventTapManager!
    private var cursorHider: CursorHider!
    private var viewModel: PointerViewModel!
    private var verificationService: VerificationService!
    private var openClawService: OpenClawService!
    private var behaviorSensingService: BehaviorSensingService!
    private var settingsWindow: NSWindow?
    private var isEnabled = true
    private var isFollowingMouse = true
    private var onboardingWindow: NSWindow?

    // Screenshot support
    private var screenshotViewModel: ScreenshotViewModel?
    private var screenshotWindows: [ScreenshotOverlayWindow] = []
    private var panelFrameBeforeScreenshot: NSRect = .zero
    private var screenshotEnteredFromIdle = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil) // Disable stdout buffering for real-time logs
        NSApp.setActivationPolicy(.accessory)
        swizzleCharacterPalette()
        setupMenuBar()

        // 监听 Settings 里的 "Show Onboarding" 按钮
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOnboarding),
            name: .showOnboarding, object: nil
        )

        // 首次启动显示 onboarding，否则直接启动
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            showOnboarding()
        } else {
            startPointerSystem()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cursorHider?.restore()
        eventTapManager?.stop()
        verificationService?.stop()
        behaviorSensingService?.stop()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: "pointer.arrow.ipad.rays", accessibilityDescription: "AI Pointer")?.withSymbolConfiguration(config)
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Enable AI Pointer", action: #selector(toggleEnabled), keyEquivalent: "")
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

    // MARK: - Onboarding

    @objc private func handleShowOnboarding() {
        // 从 debug 按钮触发，系统已经在运行，不需要再初始化
        showOnboarding(needsStart: false)
    }

    private var onboardingNeedsStart = true

    private func showOnboarding(needsStart: Bool = true) {
        // 防止重复打开
        if let existing = onboardingWindow, existing.isVisible { return }

        onboardingNeedsStart = needsStart
        NSApp.setActivationPolicy(.regular) // 临时显示 Dock 图标以便用户交互

        let onboardingView = OnboardingView {
            // 完成回调
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self.dismissOnboarding()
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        window.setContentSize(NSSize(width: 640, height: 656))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        // 隐藏标题栏按钮
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    /// 统一清理 onboarding 窗口，恢复 app 状态
    private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
        if onboardingNeedsStart {
            onboardingNeedsStart = false
            startPointerSystem()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindow else { return }
        // User closed via Cmd+W — clean up as if dismissed
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
        if onboardingNeedsStart {
            onboardingNeedsStart = false
            startPointerSystem()
        }
    }

    /// Swizzle NSApplication.orderFrontCharacterPalette as extra safety layer.
    private func swizzleCharacterPalette() {
        let original = #selector(NSApplication.orderFrontCharacterPalette(_:))
        let swizzled = #selector(NSApplication.noopCharacterPalette(_:))
        guard let m1 = class_getInstanceMethod(NSApplication.self, original),
              let m2 = class_getInstanceMethod(NSApplication.self, swizzled) else { return }
        method_exchangeImplementations(m1, m2)
    }

    private func startPointerSystem() {
        // 权限检查：无论首次还是后续启动，都在此统一拦截
        guard EventTapManager.checkPermission() else {
            EventTapManager.requestPermission()
            let alert = NSAlert()
            alert.messageText = "Input Monitoring Required"
            alert.informativeText = "AI Pointer needs Input Monitoring permission to track mouse movement and keyboard events.\n\nPlease grant access in System Settings → Privacy & Security → Input Monitoring, then relaunch the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Relaunch")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
                // Keep app running so the user can grant permission and relaunch
                return
            } else if response == .alertSecondButtonReturn {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", Bundle.main.bundlePath]
                try? task.run()
            }
            NSApp.terminate(nil)
            return
        }

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

        // Reposition panel when SwiftUI detects expansion direction should change
        viewModel.onExpansionDirectionChanged = { [weak self] in
            guard let self else { return }
            self.overlayPanel.repositionForDirection(
                right: self.viewModel.expandsRight,
                down: self.viewModel.expandsDown
            )
        }

        // React to every state change
        viewModel.onStateChanged = { [weak self] state in
            guard let self, self.isEnabled else { return }
            self.isFollowingMouse = !state.isFixed
            self.overlayPanel.updateForState(state)

            // Sync expansion info from panel to viewModel for SwiftUI
            self.viewModel.expansionMouseX = self.overlayPanel.expansionMousePosition.x
            self.viewModel.expansionMouseY = self.overlayPanel.expansionMousePosition.y
            self.viewModel.expansionScreenMinX = self.overlayPanel.expansionScreenBounds.minX
            self.viewModel.expansionScreenMaxX = self.overlayPanel.expansionScreenBounds.maxX
            self.viewModel.expansionScreenMinY = self.overlayPanel.expansionScreenBounds.minY
            self.viewModel.expansionScreenMaxY = self.overlayPanel.expansionScreenBounds.maxY
            self.viewModel.expandsRight = self.overlayPanel.expandsRight
            self.viewModel.expandsDown = self.overlayPanel.expandsDown

            switch state {
            case .idle:
                self.overlayPanel.allowsKeyWindow = false
                self.overlayPanel.ignoresMouseEvents = true
                self.cursorHider.hide()

            case .monitoring, .codeReady, .suggestion:
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

                // No clampToScreen needed — snapToMouse handles edge detection
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

        // Behavior sensing service — passively monitors user actions
        behaviorSensingService = BehaviorSensingService()
        behaviorSensingService.openClawService = openClawService
        behaviorSensingService.onAnalysisResult = { [weak self] analysis in
            self?.viewModel.updateBehaviorSuggestion(analysis)
        }

        // Connect EventTapManager callbacks for click and copy
        eventTapManager.onMouseDown = { [weak self] quartzPoint in
            self?.behaviorSensingService.monitor.recordClick(at: quartzPoint)
        }
        eventTapManager.onCmdC = { [weak self] in
            self?.behaviorSensingService.monitor.recordCopy()
        }

        // Apply behavior sensing settings
        applyBehaviorSensingSettings()

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

    private func applyBehaviorSensingSettings() {
        guard let service = behaviorSensingService else { return }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "behaviorSensingEnabled") as? Bool ?? true
        let sensitivity = defaults.double(forKey: "behaviorSensitivity")
        service.sensitivity = sensitivity > 0 ? sensitivity : 1.0

        if enabled && !service.isRunning {
            service.start()
            print("[BehaviorSensing] Started (sensitivity=\(service.sensitivity))")
        } else if !enabled && service.isRunning {
            service.stop()
            print("[BehaviorSensing] Stopped")
        }

        // Focus detection settings
        if enabled {
            service.applyFocusDetectionSettings()
            let focusEnabled = defaults.object(forKey: "focusDetectionEnabled") as? Bool ?? true
            if focusEnabled && !service.isFocusDetectionRunning {
                service.startFocusDetection()
            } else if !focusEnabled && service.isFocusDetectionRunning {
                service.stopFocusDetection()
            }
        }
    }

    @objc private func settingsChanged() {
        applySettings()
        applyBehaviorSensingSettings()
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
            let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI Pointer Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 640))
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
            applyBehaviorSensingSettings()
            overlayPanel.orderFrontRegardless()
        } else {
            cursorHider.restore()
            eventTapManager.stop()
            verificationService.stop()
            behaviorSensingService?.stop()
            overlayPanel.orderOut(nil)
        }

        if let menu = statusItem.menu,
           let toggleItem = menu.item(at: 0) {
            toggleItem.state = isEnabled ? .on : .off
        }
    }

    @objc private func quit() {
        cursorHider.restore()
        NSApp.terminate(nil)
    }
}

// MARK: - Borderless window that accepts key + mouse events

class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Swizzle target

extension NSApplication {
    @objc func noopCharacterPalette(_ sender: Any?) {
        // Intentionally empty — blocks emoji picker via orderFrontCharacterPalette
    }
}
