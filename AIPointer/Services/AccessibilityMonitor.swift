import Cocoa
import ApplicationServices

/// Monitors the focused UI element across applications using AXObserver.
/// When the user focuses a new element, `onFocusedElementChanged` fires with the AXUIElement.
///
/// Lifecycle:
/// - Listens to NSWorkspace.didActivateApplicationNotification to track the frontmost app
/// - Creates an AXObserver for each activated app to watch kAXFocusedUIElementChangedNotification
/// - Tears down the observer when the user switches away
/// - Enables AXEnhancedUserInterface on Chrome/Chromium for full DOM attribute exposure
final class AccessibilityMonitor {
    var onFocusedElementChanged: ((AXUIElement) -> Void)?

    private var currentObserver: AXObserver?
    private var currentPid: pid_t = 0
    private var currentAppElement: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?
    private var pollingTimer: Timer?
    private var lastFocusedFingerprint: String?

    /// Polling interval for fallback focus detection (Chrome doesn't fire AXObserver callbacks).
    private let pollingInterval: TimeInterval = 1.5

    /// Chromium-based browsers that need AXEnhancedUserInterface enabled.
    private static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.electron",
        "com.arc.browser",
    ]

    /// All browser bundle IDs — OTP field detection is limited to browsers only.
    private static let browserBundleIds: Set<String> = chromiumBundleIds.union([
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",      // Arc (alternate ID)
    ])

    func start() {
        // Observe app activation
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attachToApp(app)
        }

        // Attach to currently active app immediately
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            attachToApp(frontApp)
        }
    }

    func stop() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        detachCurrentObserver()
    }

    // MARK: - Observer management

    private func attachToApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != currentPid else { return }

        // Only monitor browsers — skip native apps to avoid false positives.
        guard let bundleId = app.bundleIdentifier,
              Self.browserBundleIds.contains(where: { bundleId.hasPrefix($0) }) else {
            detachCurrentObserver()
            return
        }

        detachCurrentObserver()
        currentPid = pid

        let appElement = AXUIElementCreateApplication(pid)

        // Enable enhanced AX for Chromium browsers
        if Self.chromiumBundleIds.contains(where: { bundleId.hasPrefix($0) }) {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        }

        // Create AXObserver
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Get the actual focused element
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                let focusedElement = focused as! AXUIElement
                DispatchQueue.main.async {
                    monitor.onFocusedElementChanged?(focusedElement)
                }
            }
        }

        let createResult = AXObserverCreate(pid, callback, &observer)
        guard createResult == .success, let observer else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        currentObserver = observer
        currentAppElement = appElement

        // Also check the currently focused element immediately
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            let focusedElement = focused as! AXUIElement
            lastFocusedFingerprint = fingerprint(for: focusedElement)
            onFocusedElementChanged?(focusedElement)
        }

        // Start polling fallback (Chrome doesn't fire AXObserver callbacks)
        startPollingTimer()
    }

    private func detachCurrentObserver() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        lastFocusedFingerprint = nil
        if let observer = currentObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        currentObserver = nil
        currentAppElement = nil
        currentPid = 0
    }

    // MARK: - Polling fallback

    private func startPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.pollFocusedElement()
        }
    }

    private func pollFocusedElement() {
        guard let appElement = currentAppElement else { return }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return }

        let focusedElement = focused as! AXUIElement
        let fp = fingerprint(for: focusedElement)

        guard fp != lastFocusedFingerprint else { return }
        lastFocusedFingerprint = fp

        onFocusedElementChanged?(focusedElement)
    }

    /// Build a lightweight fingerprint for an AXUIElement to detect changes.
    private func fingerprint(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let attrs = AXAttributes(element: element)
        let role = attrs.string("AXRole") ?? ""
        let id = attrs.domId ?? attrs.identifier ?? ""
        let placeholder = attrs.placeholderValue ?? ""
        let title = attrs.title ?? ""
        let label = attrs.label ?? ""
        let desc = attrs.axDescription ?? ""
        return "\(pid)|\(role)|\(id)|\(placeholder)|\(title)|\(label)|\(desc)"
    }

    deinit {
        stop()
    }
}
