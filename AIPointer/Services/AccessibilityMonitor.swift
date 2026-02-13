import Cocoa
import ApplicationServices

let debugLog: (String) -> Void = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AIPointer-debug.log")
    return { msg in
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}()

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

    func start() {
        debugLog("[AXMonitor] start()")
        // Observe app activation
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            debugLog("[AXMonitor] App activated: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
            self?.attachToApp(app)
        }

        // Attach to currently active app immediately
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            debugLog("[AXMonitor] Attaching to frontmost: \(frontApp.localizedName ?? "?") (\(frontApp.bundleIdentifier ?? "?")")
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

        detachCurrentObserver()
        currentPid = pid

        let appElement = AXUIElementCreateApplication(pid)

        // Enable enhanced AX for Chromium browsers
        if let bundleId = app.bundleIdentifier,
           Self.chromiumBundleIds.contains(where: { bundleId.hasPrefix($0) }) {
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
                let attrs = AXAttributes(element: focusedElement)
                debugLog("[AXMonitor] Focus changed → role=\(attrs.string("AXRole") ?? "nil"), id=\(attrs.domId ?? "nil"), name=\(attrs.domName ?? "nil"), placeholder=\(attrs.placeholderValue ?? "nil"), autocomplete=\(attrs.autocomplete ?? "nil"), label=\(attrs.label ?? "nil"), title=\(attrs.title ?? "nil"), desc=\(attrs.axDescription ?? "nil")")
                DispatchQueue.main.async {
                    monitor.onFocusedElementChanged?(focusedElement)
                }
            }
        }

        let createResult = AXObserverCreate(pid, callback, &observer)
        guard createResult == .success, let observer else {
            debugLog("[AXMonitor] AXObserverCreate FAILED: \(createResult.rawValue)")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addResult = AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        debugLog("[AXMonitor] Observer registered for pid=\(pid), addNotification result=\(addResult.rawValue)")
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        currentObserver = observer
        currentAppElement = appElement

        // Also check the currently focused element immediately
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            let focusedElement = focused as! AXUIElement
            let attrs = AXAttributes(element: focusedElement)
            debugLog("[AXMonitor] Immediate focus check → role=\(attrs.string("AXRole") ?? "nil"), subrole=\(attrs.subrole ?? "nil"), id=\(attrs.domId ?? "nil"), name=\(attrs.domName ?? "nil"), class=\(attrs.domClass ?? "nil"), placeholder=\(attrs.placeholderValue ?? "nil"), autocomplete=\(attrs.autocomplete ?? "nil"), label=\(attrs.label ?? "nil"), title=\(attrs.title ?? "nil"), desc=\(attrs.axDescription ?? "nil"), inputMode=\(attrs.inputMode ?? "nil"), inputType=\(attrs.inputType ?? "nil"), maxLen=\(attrs.maxLength.map(String.init) ?? "nil"), value=\(attrs.value ?? "nil")")
            lastFocusedFingerprint = fingerprint(for: focusedElement)
            onFocusedElementChanged?(focusedElement)
        } else {
            debugLog("[AXMonitor] Immediate focus check → failed to get focused element")
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

        let attrs = AXAttributes(element: focusedElement)
        debugLog("[AXMonitor] Poll detected focus change → role=\(attrs.string("AXRole") ?? "nil"), id=\(attrs.domId ?? "nil"), placeholder=\(attrs.placeholderValue ?? "nil"), label=\(attrs.label ?? "nil"), title=\(attrs.title ?? "nil"), desc=\(attrs.axDescription ?? "nil")")

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
