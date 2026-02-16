import Cocoa
import ApplicationServices

class BehaviorMonitor {
    let buffer: BehaviorBuffer
    var tabSnapshotCache: TabSnapshotCache?
    private let axQueue = DispatchQueue(label: "com.aipointer.ax-query", qos: .utility)

    private var clipboardTimer: Timer?
    private var dwellTimer: Timer?
    private var titlePollTimer: Timer?
    private var lastClipboardChangeCount: Int = 0
    private var lastActiveApp: String = ""
    private var lastActiveBundleId: String = ""
    private var lastWindowTitle: String = ""
    private var lastMousePosition: CGPoint = .zero
    private var dwellFrameCount: Int = 0
    private var dwellFired: Bool = false

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
    ]

    private static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac"
    ]

    private static let feishuBundleIDs: Set<String> = [
        "com.electron.lark", "com.bytedance.lark", "com.larksuite.Feishu"
    ]

    init(buffer: BehaviorBuffer) {
        self.buffer = buffer
    }

    func start() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount

        // App switch notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Clipboard polling (every 1.0s)
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }

        // Mouse dwell polling (every 0.5s)
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkDwell()
        }

        // Window title polling (every 2s) — detects tab switches within the same app
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkWindowTitle()
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        titlePollTimer?.invalidate()
        titlePollTimer = nil
    }

    // MARK: - App Switch

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName else { return }

        let previousApp = lastActiveApp
        let previousTitle = lastWindowTitle
        let bundleId = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier

        // Update main-thread state immediately (app identity is safe to read here)
        lastActiveApp = name
        lastActiveBundleId = bundleId

        // Move AX query + tab capture off the main thread to avoid deadlocking
        // when our own settings panel is frontmost.
        axQueue.async { [weak self] in
            guard let self else { return }
            let windowTitle = self.readFocusedWindowTitle()

            DispatchQueue.main.async { [weak self] in
                self?.lastWindowTitle = windowTitle
            }

            if !previousApp.isEmpty && previousApp != name {
                self.buffer.append(BehaviorEvent(
                    timestamp: Date(),
                    kind: .appSwitch,
                    detail: "\(previousApp) → \(name)",
                    context: windowTitle
                ))
            }

            // Check for tab switch (same app, different window title)
            if previousApp == name && windowTitle != previousTitle && !windowTitle.isEmpty {
                if Self.browserBundleIDs.contains(bundleId) {
                    self.buffer.append(BehaviorEvent(
                        timestamp: Date(),
                        kind: .tabSwitch,
                        detail: "\(previousTitle) → \(windowTitle)",
                        context: name
                    ))
                }
            }

            if !windowTitle.isEmpty {
                self.buffer.append(BehaviorEvent(
                    timestamp: Date(),
                    kind: .windowTitle,
                    detail: windowTitle,
                    context: name
                ))
            }

            // Tab snapshot capture
            if Self.chromeBundleIDs.contains(bundleId) || Self.feishuBundleIDs.contains(bundleId) {
                if let tabs = self.captureTabs(bundleId: bundleId, pid: pid) {
                    self.tabSnapshotCache?.store(appName: name, bundleId: bundleId, tabs: tabs)

                    let tabTitles = tabs.map { $0.title }
                    let json = (try? JSONSerialization.data(withJSONObject: tabTitles))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    self.buffer.append(BehaviorEvent(
                        timestamp: Date(),
                        kind: .tabSnapshot,
                        detail: name,
                        context: json
                    ))
                    print("[BehaviorMonitor] Tab snapshot: \(name) (\(tabs.count) tabs)")
                }
            }
        }
    }

    // MARK: - Window Title Polling (detect in-app tab switches)

    private func checkWindowTitle() {
        // Capture all shared state on the main thread before dispatching
        let app = lastActiveApp
        let bundleId = lastActiveBundleId
        let previousTitle = lastWindowTitle
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard !app.isEmpty else { return }

        // Run AX query off the main thread to avoid deadlocking when our own
        // settings panel is frontmost (AX hitting our NSHostingView on main).
        axQueue.async { [weak self] in
            guard let self else { return }
            let windowTitle = self.readFocusedWindowTitle()
            guard !windowTitle.isEmpty, windowTitle != previousTitle else { return }

            DispatchQueue.main.async { [weak self] in
                self?.lastWindowTitle = windowTitle
            }

            // Record as tab switch if it's a browser
            let needsTabCapture: Bool
            if Self.browserBundleIDs.contains(bundleId) && !previousTitle.isEmpty {
                self.buffer.append(BehaviorEvent(
                    timestamp: Date(),
                    kind: .tabSwitch,
                    detail: "\(previousTitle) → \(windowTitle)",
                    context: app
                ))
                needsTabCapture = Self.chromeBundleIDs.contains(bundleId) || Self.feishuBundleIDs.contains(bundleId)
            } else {
                needsTabCapture = false
            }

            self.buffer.append(BehaviorEvent(
                timestamp: Date(),
                kind: .windowTitle,
                detail: windowTitle,
                context: app
            ))

            // Refresh tab snapshot so the cache doesn't go stale when the user
            // stays in the same browser for a long time without switching apps.
            if needsTabCapture {
                guard pid > 0 else { return }
                if let tabs = self.captureTabs(bundleId: bundleId, pid: pid) {
                    self.tabSnapshotCache?.store(appName: app, bundleId: bundleId, tabs: tabs)
                    print("[BehaviorMonitor] Tab snapshot refreshed (title poll): \(app) (\(tabs.count) tabs)")
                }
            }
        }
    }

    // MARK: - Clipboard

    private func checkClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentCount

        let content = NSPasteboard.general.string(forType: .string) ?? ""
        let truncated = String(content.prefix(200))
        let detail = isLikelyPassword(truncated) ? "[REDACTED]" : truncated

        buffer.append(BehaviorEvent(
            timestamp: Date(),
            kind: .clipboard,
            detail: detail,
            context: nil
        ))
    }

    private func isLikelyPassword(_ text: String) -> Bool {
        let len = text.count
        guard len >= 8 && len <= 64 && !text.contains(" ") else { return false }

        var categories = 0
        if text.range(of: "[A-Z]", options: .regularExpression) != nil { categories += 1 }
        if text.range(of: "[a-z]", options: .regularExpression) != nil { categories += 1 }
        if text.range(of: "[0-9]", options: .regularExpression) != nil { categories += 1 }
        if text.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil { categories += 1 }

        return categories >= 3
    }

    // MARK: - Mouse Dwell

    private func checkDwell() {
        let pos = NSEvent.mouseLocation
        let distance = hypot(pos.x - lastMousePosition.x, pos.y - lastMousePosition.y)

        if distance < 5 {
            dwellFrameCount += 1
            if dwellFrameCount >= 3 && !dwellFired {
                dwellFired = true
                let app = lastActiveApp
                axQueue.async { [weak self] in
                    guard let self else { return }
                    let axDesc = self.describeElementAtPosition(pos)
                    self.buffer.append(BehaviorEvent(
                        timestamp: Date(),
                        kind: .dwell,
                        detail: axDesc,
                        context: app
                    ))
                }
            }
        } else {
            dwellFrameCount = 0
            dwellFired = false
        }

        lastMousePosition = pos
    }

    // MARK: - Click (called from EventTapManager)

    func recordClick(at quartzPoint: CGPoint) {
        let app = lastActiveApp
        axQueue.async { [weak self] in
            guard let self else { return }
            let axDesc = self.describeElementAtQuartzPosition(quartzPoint)
            self.buffer.append(BehaviorEvent(
                timestamp: Date(),
                kind: .click,
                detail: axDesc,
                context: app
            ))
        }
    }

    // MARK: - Copy (called from EventTapManager)

    func recordCopy() {
        let app = lastActiveApp
        axQueue.async { [weak self] in
            guard let self else { return }
            let axDesc = self.describeFocusedElement()
            self.buffer.append(BehaviorEvent(
                timestamp: Date(),
                kind: .copy,
                detail: axDesc,
                context: app
            ))
        }
    }

    // MARK: - Tab Snapshot Capture

    private func captureTabs(bundleId: String, pid: pid_t) -> [TabInfo]? {
        if Self.chromeBundleIDs.contains(bundleId) {
            return captureChromeTabs(pid: pid)
        } else if Self.feishuBundleIDs.contains(bundleId) {
            return captureFeishuTabs(pid: pid)
        }
        return nil
    }

    private func captureChromeTabs(pid: pid_t) -> [TabInfo]? {
        let appEl = AXUIElementCreateApplication(pid)

        // Enable enhanced UI to access Chrome tab info
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else {
            return nil
        }

        var tabs: [TabInfo] = []

        func findTabs(_ el: AXUIElement, depth: Int = 0) {
            guard depth < 10 else { return }

            var roleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String else { return }

            if role == "AXRadioButton" {
                var subroleRef: AnyObject?
                if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String, subrole == "AXTabButton" {

                    var descRef: AnyObject?
                    if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
                       let desc = descRef as? String, !desc.isEmpty {

                        var selectedRef: AnyObject?
                        let isSelected = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &selectedRef) == .success
                            && (selectedRef as? NSNumber)?.boolValue == true

                        tabs.append(TabInfo(title: desc, isActive: isSelected))
                    }
                }
            }

            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children {
                findTabs(child, depth: depth + 1)
            }
        }

                // AnyObject→AXUIElement cast always succeeds for CF types; guard above ensures non-nil
        let focusedWindow = focusedRef as! AXUIElement  // safe: guarded by .success check
        findTabs(focusedWindow)
        return tabs.isEmpty ? nil : tabs
    }

    private func captureFeishuTabs(pid: pid_t) -> [TabInfo]? {
        let appEl = AXUIElementCreateApplication(pid)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else {
            return nil
        }

        var tabs: [TabInfo] = []

        func findTabScrollArea(_ el: AXUIElement, depth: Int = 0) {
            guard depth < 20 else { return }

            var descRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String, desc.contains("TabScrollContents") {

                var childrenRef: AnyObject?
                guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { return }

                for child in children {
                    var roleRef: AnyObject?
                    guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                          let role = roleRef as? String, role == "AXRadioButton" else { continue }

                    var tabDescRef: AnyObject?
                    if AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &tabDescRef) == .success,
                       let tabDesc = tabDescRef as? String, !tabDesc.isEmpty {

                        var selectedRef: AnyObject?
                        let isSelected = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &selectedRef) == .success
                            && (selectedRef as? NSNumber)?.boolValue == true

                        tabs.append(TabInfo(title: tabDesc, isActive: isSelected))
                    }
                }
                return
            }

            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children {
                findTabScrollArea(child, depth: depth + 1)
            }
        }

        let focusedWindow = focusedRef as! AXUIElement  // safe: guarded by .success check
        findTabScrollArea(focusedWindow)
        return tabs.isEmpty ? nil : tabs
    }

    // MARK: - Accessibility Helpers

    private func readFocusedWindowTitle() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return ""
        }
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else {
            return ""
        }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return ""
        }
        return (title as? String) ?? ""
    }

    private func describeElementAtPosition(_ appKitPoint: NSPoint) -> String {
        // Convert AppKit coordinates (origin bottom-left) to Quartz (origin top-left)
        guard let screen = NSScreen.main else { return "unknown" }
        let quartzY = screen.frame.height - appKitPoint.y
        return describeElementAtQuartzPosition(CGPoint(x: appKitPoint.x, y: quartzY))
    }

    private func describeElementAtQuartzPosition(_ point: CGPoint) -> String {
        // Use the focused app's AX element instead of system-wide to avoid
        // triggering accessibilityHitTest on our own NSHostingView (which causes
        // a main-thread assertion crash from SafariPlatformSupport KVO).
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return "unknown"
        }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(focusedApp as! AXUIElement, Float(point.x), Float(point.y), &element) == .success,
              let el = element else {
            return "unknown"
        }
        return describeAXElement(el)
    }

    private func describeFocusedElement() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return "unknown"
        }
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return "unknown"
        }
        return describeAXElement(focusedElement as! AXUIElement)
    }

    private func describeAXElement(_ element: AXUIElement) -> String {
        func attr(_ key: String) -> String? {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            if let str = value as? String { return str.isEmpty ? nil : String(str.prefix(100)) }
            return nil
        }

        var parts: [String] = []
        if let role = attr(kAXRoleAttribute) { parts.append("role=\(role)") }
        if let value = attr(kAXValueAttribute) { parts.append("value=\(value)") }
        if let title = attr(kAXTitleAttribute) { parts.append("title=\(title)") }
        if let placeholder = attr(kAXPlaceholderValueAttribute) { parts.append("placeholder=\(placeholder)") }
        if let desc = attr(kAXDescriptionAttribute) { parts.append("desc=\(desc)") }

        // Parent info
        var parentRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success {
            let parent = parentRef as! AXUIElement
            var parentRole: AnyObject?
            if AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &parentRole) == .success,
               let pr = parentRole as? String {
                parts.append("parent=\(pr)")
            }
            var parentTitle: AnyObject?
            if AXUIElementCopyAttributeValue(parent, kAXTitleAttribute as CFString, &parentTitle) == .success,
               let pt = parentTitle as? String, !pt.isEmpty {
                parts.append("parentTitle=\(String(pt.prefix(100)))")
            }
        }

        return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
    }
}
