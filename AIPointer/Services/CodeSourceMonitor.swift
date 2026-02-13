import Cocoa
import ApplicationServices

/// Monitors verification code sources: Mail.app (polling), browser tabs (Chrome/Gmail), and Notification Center (event-driven).
/// Extracts numeric codes from email subjects/bodies, browser email tabs, and SMS notifications.
final class CodeSourceMonitor {
    var onCodeFound: ((String) -> Void)?

    private var pollTimer: Timer?
    private var notificationObserver: AXObserver?
    private var isActive = false
    private var startTime: Date?

    /// Last code found — prevents duplicate delivery of the same code.
    private var lastFoundCode: String?

    /// Maximum monitoring duration before auto-stop (3 minutes).
    private let timeout: TimeInterval = 180

    /// Polling interval for mail + browser tabs (4 seconds).
    private let pollInterval: TimeInterval = 4

    /// Delay before starting polling (2 seconds).
    private let pollStartDelay: TimeInterval = 2

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        startTime = Date()
        debugLog("[CodeSource] Monitoring started")

        // Start notification center monitoring immediately (event-driven, no cost)
        startNotificationMonitor()

        // Delay polling by 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + pollStartDelay) { [weak self] in
            guard let self, self.isActive else { return }
            self.startPolling()
        }
    }

    func stop() {
        debugLog("[CodeSource] Monitoring stopped")
        isActive = false
        startTime = nil
        lastFoundCode = nil
        pollTimer?.invalidate()
        pollTimer = nil
        stopNotificationMonitor()
    }

    /// Check if monitoring has exceeded the timeout.
    var isTimedOut: Bool {
        guard let start = startTime else { return false }
        return Date().timeIntervalSince(start) >= timeout
    }

    // MARK: - Unified polling

    private func startPolling() {
        debugLog("[CodeSource] Starting poll timer (interval=\(pollInterval)s)")
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Single poll tick — runs Mail.app and browser tab scans in parallel.
    private func poll() {
        guard isActive else { return }

        if isTimedOut {
            debugLog("[CodeSource] Timed out after \(timeout)s — stopping")
            stop()
            return
        }

        // Run both sources in parallel
        pollMail()
        pollBrowserTabs()
    }

    /// Deliver a found code, skipping duplicates.
    private func deliverCode(_ code: String, source: String) {
        guard isActive else { return }
        if code == lastFoundCode {
            debugLog("[CodeSource] Skipping duplicate code from \(source): \(code)")
            return
        }
        lastFoundCode = code
        debugLog("[CodeSource] Delivering code from \(source): \(code)")
        DispatchQueue.main.async { [weak self] in
            self?.onCodeFound?(code)
        }
    }

    // MARK: - Mail.app polling

    private func pollMail() {
        debugLog("[CodeSource] Polling Mail.app...")

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

            if let result, !result.isEmpty {
                debugLog("[CodeSource] Mail.app returned text (\(result.count) chars)")
                if let code = self.extractCode(from: result) {
                    debugLog("[CodeSource] Mail.app extracted code: \(code)")
                    await MainActor.run {
                        self.deliverCode(code, source: "Mail.app")
                    }
                } else {
                    debugLog("[CodeSource] Mail.app — no code found in text")
                }
            } else {
                debugLog("[CodeSource] Mail.app — no recent unread messages (or Mail not running)")
            }
        }
    }

    // MARK: - Browser tab scanning

    private func pollBrowserTabs() {
        debugLog("[CodeSource] Polling browser tabs...")

        // Phase 1: Collect tab titles (always works, no JS needed)
        // Phase 2: Try JS extraction for deeper content (requires "Allow JavaScript from Apple Events")
        // Gmail tab titles often contain email subjects, e.g. "Inbox (3) - user@gmail.com - Gmail"
        // When an email is open, title shows subject: "Your verification code is 123456 - user@gmail.com - Gmail"

        let titleScript = """
        tell application "Google Chrome"
            set allText to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set tabUrl to URL of t
                    set tabTitle to title of t
                    if tabUrl contains "mail.google.com" or tabUrl contains "outlook.live.com" or tabUrl contains "outlook.office365.com" or tabUrl contains "outlook.office.com" or tabUrl contains "mail.yahoo.com" then
                        set allText to allText & "TAB:" & tabTitle & " ### "
                    end if
                end repeat
            end repeat
            return allText
        end tell
        """

        // JS extraction script — will fail silently if JS from Apple Events is disabled
        let jsScript = """
        tell application "Google Chrome"
            set allText to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set tabUrl to URL of t
                    set tabTitle to title of t
                    if tabUrl contains "mail.google.com" then
                        try
                            set pageText to (execute t javascript "(function(){var t=[];document.querySelectorAll('.zE .y2').forEach(function(e,i){if(i<5) t.push(e.innerText.substring(0,300))});document.querySelectorAll('.a3s').forEach(function(e,i){if(i<3) t.push(e.innerText.substring(0,500))});if(t.length===0) t.push(document.title+' '+document.body.innerText.substring(0,2000));return t.join(' ||| ')})()")
                            set allText to allText & "JS_GMAIL:" & tabTitle & " ### " & pageText & " ### "
                        end try
                    else if tabUrl contains "outlook.live.com" or tabUrl contains "outlook.office365.com" or tabUrl contains "outlook.office.com" then
                        try
                            set pageText to (execute t javascript "(function(){var t=[];document.querySelectorAll('[role=\\\"document\\\"]').forEach(function(e,i){if(i<3) t.push(e.innerText.substring(0,500))});document.querySelectorAll('.wide-content-host').forEach(function(e,i){if(i<3) t.push(e.innerText.substring(0,500))});if(t.length===0) t.push(document.title+' '+document.body.innerText.substring(0,2000));return t.join(' ||| ')})()")
                            set allText to allText & "JS_OUTLOOK:" & tabTitle & " ### " & pageText & " ### "
                        end try
                    else if tabUrl contains "mail.yahoo.com" then
                        try
                            set pageText to (execute t javascript "(function(){return document.title+' '+document.body.innerText.substring(0,2000)})()")
                            set allText to allText & "JS_YAHOO:" & tabTitle & " ### " & pageText & " ### "
                        end try
                    end if
                end repeat
            end repeat
            return allText
        end tell
        """

        Task.detached { [weak self] in
            guard let self else { return }

            // Phase 1: Tab titles (always works)
            let titleResult = self.runAppleScript(titleScript)
            var combinedText = ""

            if let titleResult, !titleResult.isEmpty {
                debugLog("[CodeSource] Browser tab titles: \(titleResult.prefix(500))")
                combinedText += titleResult
            } else {
                debugLog("[CodeSource] Browser tabs — no email tabs found (or Chrome not running)")
                return
            }

            // Phase 2: JS content extraction (may fail if not enabled)
            let jsResult = self.runAppleScript(jsScript)
            if let jsResult, !jsResult.isEmpty {
                debugLog("[CodeSource] Browser JS extraction returned \(jsResult.count) chars")
                combinedText += " " + jsResult
            } else {
                debugLog("[CodeSource] Browser JS extraction unavailable (enable: Chrome → View → Developer → Allow JavaScript from Apple Events)")
            }

            // Try to extract code from combined text
            if let code = self.extractCode(from: combinedText) {
                debugLog("[CodeSource] Browser tabs extracted code: \(code)")
                await MainActor.run {
                    self.deliverCode(code, source: "Browser")
                }
            } else {
                debugLog("[CodeSource] Browser tabs — no code found in extracted text")
            }
        }
    }

    // MARK: - AppleScript runner

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            debugLog("[CodeSource] AppleScript error: \(error)")
            return nil
        }
        return result?.stringValue
    }

    // MARK: - Notification Center monitoring

    /// Monitor the Notification Center UI for new SMS/notification banners.
    /// Uses AX to watch the notification center process for new child elements.
    private func startNotificationMonitor() {
        // Find the notification center process
        guard let ncApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        ).first else {
            debugLog("[CodeSource] Notification Center process not found")
            return
        }

        let pid = ncApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<CodeSourceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleNotificationChange(element: element)
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else {
            debugLog("[CodeSource] Failed to create AX observer for Notification Center")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Watch for new UI elements appearing (notification banners)
        AXObserverAddNotification(observer, appElement, kAXCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXUIElementsKey as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        notificationObserver = observer
        debugLog("[CodeSource] Notification Center observer registered (pid=\(pid))")
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
        debugLog("[CodeSource] Notification event — extracted text: \(combined.prefix(200))")

        if let code = extractCode(from: combined) {
            debugLog("[CodeSource] Notification extracted code: \(code)")
            DispatchQueue.main.async { [weak self] in
                self?.deliverCode(code, source: "Notification")
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
        debugLog("[CodeSource] extractCode called with \(text.count) chars")

        // First try: code near a keyword (higher confidence)
        let keywordPattern = "(?:verification|code|verify|OTP|验证码|校验码|确认码|認証コード|인증번호|Bestätigungscode|código)\\s*[:：]?\\s*(\\d{4,8})"
        if let match = text.range(of: keywordPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                let code = String(matchStr[codeMatch])
                debugLog("[CodeSource] extractCode matched keyword pattern: \(code)")
                return code
            }
        }

        // Second try: digit sequence after keyword (reversed order)
        let reversedPattern = "(\\d{4,8})\\s*(?:is your|is the|为您的|是您的)"
        if let match = text.range(of: reversedPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                let code = String(matchStr[codeMatch])
                debugLog("[CodeSource] extractCode matched reversed pattern: \(code)")
                return code
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
                    let code = String(matchStr[codeMatch])
                    debugLog("[CodeSource] extractCode matched fallback digit pattern: \(code)")
                    return code
                }
            }
        }

        debugLog("[CodeSource] extractCode — no code found")
        return nil
    }

    deinit {
        stop()
    }
}
