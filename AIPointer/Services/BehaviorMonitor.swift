import Cocoa
import ApplicationServices

class BehaviorMonitor {
    let buffer: BehaviorBuffer
    private let axQueue = DispatchQueue(label: "com.aipointer.ax-query", qos: .utility)

    private var clipboardTimer: Timer?
    private var dwellTimer: Timer?
    private var lastClipboardChangeCount: Int = 0
    private var lastActiveApp: String = ""
    private var lastWindowTitle: String = ""
    private var lastMousePosition: CGPoint = .zero
    private var dwellFrameCount: Int = 0
    private var dwellFired: Bool = false

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
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
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    // MARK: - App Switch

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName else { return }

        let previousApp = lastActiveApp
        let windowTitle = readFocusedWindowTitle()

        if !previousApp.isEmpty && previousApp != name {
            buffer.append(BehaviorEvent(
                timestamp: Date(),
                kind: .appSwitch,
                detail: "\(previousApp) → \(name)",
                context: windowTitle
            ))
        }

        // Check for tab switch (same app, different window title)
        if previousApp == name && windowTitle != lastWindowTitle && !windowTitle.isEmpty {
            let bundleID = app.bundleIdentifier ?? ""
            if Self.browserBundleIDs.contains(bundleID) {
                buffer.append(BehaviorEvent(
                    timestamp: Date(),
                    kind: .tabSwitch,
                    detail: "\(lastWindowTitle) → \(windowTitle)",
                    context: name
                ))
            }
        }

        if !windowTitle.isEmpty {
            buffer.append(BehaviorEvent(
                timestamp: Date(),
                kind: .windowTitle,
                detail: windowTitle,
                context: name
            ))
        }

        lastActiveApp = name
        lastWindowTitle = windowTitle
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
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
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
