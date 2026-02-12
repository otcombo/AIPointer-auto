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
    private var workspaceObserver: NSObjectProtocol?

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
                DispatchQueue.main.async {
                    monitor.onFocusedElementChanged?(focusedElement)
                }
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        currentObserver = observer

        // Also check the currently focused element immediately
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            let focusedElement = focused as! AXUIElement
            onFocusedElementChanged?(focusedElement)
        }
    }

    private func detachCurrentObserver() {
        if let observer = currentObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        currentObserver = nil
        currentPid = 0
    }

    deinit {
        stop()
    }
}
