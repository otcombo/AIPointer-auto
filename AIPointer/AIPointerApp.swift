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
    private var settingsWindow: NSWindow?
    private var isEnabled = true
    private var isFollowingMouse = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        swizzleCharacterPalette()
        setupMenuBar()
        checkPermissionsAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cursorHider?.restore()
        eventTapManager?.stop()
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

            case .input, .thinking, .responding, .response:
                self.overlayPanel.ignoresMouseEvents = false
                self.overlayPanel.allowsKeyWindow = true

                // Delay to next run loop so SwiftUI has laid out the TextField
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.activate(ignoringOtherApps: true)
                    self.overlayPanel.makeKeyAndOrderFront(nil)
                    if let contentView = self.overlayPanel.contentView {
                        self.overlayPanel.makeFirstResponder(contentView)
                    }
                }

                if state.isFixed {
                    self.overlayPanel.clampToScreen()
                }
            }
        }

        eventTapManager.onMouseMoved = { [weak self] point in
            guard let self else { return }
            if self.isFollowingMouse {
                self.overlayPanel.moveTo(point)
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

        eventTapManager.start()
        cursorHider.hide()
        overlayPanel.orderFrontRegardless()
    }

    private func applySettings() {
        let defaults = UserDefaults.standard
        eventTapManager.suppressFnKey = defaults.object(forKey: "suppressFnKey") as? Bool ?? true
        eventTapManager.longPressDuration = defaults.double(forKey: "longPressDuration") // 0 = instant

        let url = defaults.string(forKey: "backendURL") ?? "https://claude.otcombo.com"
        let token = defaults.string(forKey: "authToken") ?? ""
        viewModel.configureAPI(baseURL: url, authToken: token)
    }

    @objc private func settingsChanged() {
        applySettings()
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
            overlayPanel.orderFrontRegardless()
        } else {
            cursorHider.restore()
            eventTapManager.stop()
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
