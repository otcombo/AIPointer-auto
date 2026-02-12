import Cocoa
import ApplicationServices

/// Monitors verification code sources: Mail.app (polling) and Notification Center (event-driven).
/// Extracts numeric codes from email subjects/bodies and SMS notifications.
final class CodeSourceMonitor {
    var onCodeFound: ((String) -> Void)?

    private var mailTimer: Timer?
    private var notificationObserver: AXObserver?
    private var isActive = false
    private var startTime: Date?

    /// Maximum monitoring duration before auto-stop (3 minutes).
    private let timeout: TimeInterval = 180

    /// Mail polling interval (4 seconds).
    private let mailPollInterval: TimeInterval = 4

    /// Delay before starting mail polling (2 seconds).
    private let mailStartDelay: TimeInterval = 2

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        startTime = Date()

        // Start notification center monitoring immediately (event-driven, no cost)
        startNotificationMonitor()

        // Delay mail polling by 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + mailStartDelay) { [weak self] in
            guard let self, self.isActive else { return }
            self.startMailPolling()
        }
    }

    func stop() {
        isActive = false
        startTime = nil
        mailTimer?.invalidate()
        mailTimer = nil
        stopNotificationMonitor()
    }

    /// Check if monitoring has exceeded the timeout.
    var isTimedOut: Bool {
        guard let start = startTime else { return false }
        return Date().timeIntervalSince(start) >= timeout
    }

    // MARK: - Mail.app polling

    private func startMailPolling() {
        // Poll immediately, then every 4 seconds
        pollMail()
        mailTimer = Timer.scheduledTimer(withTimeInterval: mailPollInterval, repeats: true) { [weak self] _ in
            self?.pollMail()
        }
    }

    private func pollMail() {
        guard isActive else { return }

        // Check timeout
        if isTimedOut {
            stop()
            return
        }

        // Run AppleScript to get recent unread emails (last 5 minutes)
        let script = """
        tell application "Mail"
            set cutoff to (current date) - 300
            set recentMessages to {}
            try
                set inboxMessages to messages of inbox whose date received > cutoff and read status is false
                repeat with msg in inboxMessages
                    set msgSubject to subject of msg
                    set msgContent to content of msg
                    set end of recentMessages to msgSubject & " ||| " & (text 1 thru (min of {500, length of msgContent}) of msgContent)
                end repeat
            end try
            return recentMessages as text
        end tell
        """

        Task.detached { [weak self] in
            guard let self else { return }
            let result = self.runAppleScript(script)
            guard let result, !result.isEmpty else { return }

            if let code = self.extractCode(from: result) {
                await MainActor.run {
                    self.onCodeFound?(code)
                }
            }
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }

    // MARK: - Notification Center monitoring

    /// Monitor the Notification Center UI for new SMS/notification banners.
    /// Uses AX to watch the notification center process for new child elements.
    private func startNotificationMonitor() {
        // Find the notification center process
        guard let ncApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        ).first else { return }

        let pid = ncApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<CodeSourceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleNotificationChange(element: element)
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Watch for new UI elements appearing (notification banners)
        AXObserverAddNotification(observer, appElement, kAXCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXUIElementsKey as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        notificationObserver = observer
    }

    private func stopNotificationMonitor() {
        if let observer = notificationObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        notificationObserver = nil
    }

    private func handleNotificationChange(element: AXUIElement) {
        guard isActive else { return }

        // Try to extract text from the notification element and its children
        let texts = extractTexts(from: element, depth: 3)
        let combined = texts.joined(separator: " ")

        if let code = extractCode(from: combined) {
            DispatchQueue.main.async { [weak self] in
                self?.onCodeFound?(code)
            }
        }
    }

    /// Recursively extract text content from AX element tree.
    private func extractTexts(from element: AXUIElement, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        var texts: [String] = []

        // Get this element's value/title
        let attrs = AXAttributes(element: element)
        if let v = attrs.value { texts.append(v) }
        if let t = attrs.title { texts.append(t) }

        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                texts += extractTexts(from: child, depth: depth - 1)
            }
        }

        return texts
    }

    // MARK: - Code extraction

    /// Extract a 4-8 digit verification code from text.
    /// Looks for standalone digit sequences, prioritizing those near verification keywords.
    func extractCode(from text: String) -> String? {
        // First try: code near a keyword (higher confidence)
        let keywordPattern = "(?:verification|code|verify|OTP|验证码|校验码|确认码|認証コード|인증번호|Bestätigungscode|código)\\s*[:：]?\\s*(\\d{4,8})"
        if let match = text.range(of: keywordPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                return String(matchStr[codeMatch])
            }
        }

        // Second try: digit sequence after keyword (reversed order)
        let reversedPattern = "(\\d{4,8})\\s*(?:is your|is the|为您的|是您的)"
        if let match = text.range(of: reversedPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                return String(matchStr[codeMatch])
            }
        }

        // Third try: any standalone 4-8 digit sequence (lower confidence)
        // Only use if text contains verification-related keywords nearby
        let hasKeyword = ["code", "verify", "验证", "otp", "pin", "码", "コード", "인증"]
            .contains { text.lowercased().contains($0) }

        if hasKeyword {
            let digitPattern = "(?:^|\\D)(\\d{4,8})(?:\\D|$)"
            if let match = text.range(of: digitPattern, options: .regularExpression) {
                let matchStr = String(text[match])
                if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                    return String(matchStr[codeMatch])
                }
            }
        }

        return nil
    }

    deinit {
        stop()
    }
}
