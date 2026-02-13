import Cocoa
import ApplicationServices

/// Monitors verification code sources:
/// - Primary: OpenClaw API (reads email via IMAP/himalaya)
/// - Secondary: Notification Center (catches SMS/notification banners)
final class CodeSourceMonitor {
    var onCodeFound: ((String) -> Void)?

    /// Inject the shared OpenClawService instance. Set this before calling start().
    var openClawService: OpenClawService?

    private var notificationObserver: AXObserver?
    private var isActive = false
    private var lastFoundCode: String?
    private var retryTask: Task<Void, Never>?

    /// Retry schedule: delays in seconds before each attempt.
    /// Attempt 1 at T+2s, attempt 2 at T+7s, attempt 3 at T+15s.
    private let retryDelays: [TimeInterval] = [2.0, 5.0, 8.0]

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        lastFoundCode = nil
        debugLog("[CodeSource] Monitoring started")

        // Start notification center monitoring (event-driven, zero cost)
        startNotificationMonitor()

        // Start OpenClaw retry sequence
        startOpenClawRetries()
    }

    func stop() {
        debugLog("[CodeSource] Monitoring stopped")
        isActive = false
        lastFoundCode = nil
        retryTask?.cancel()
        retryTask = nil
        stopNotificationMonitor()
    }

    // MARK: - Code delivery (dedup)

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

    // MARK: - OpenClaw API (primary source)

    private func startOpenClawRetries() {
        retryTask = Task { [weak self] in
            guard let self else { return }

            for (index, delay) in self.retryDelays.enumerated() {
                guard self.isActive, !Task.isCancelled else { return }

                // Wait before attempt
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.isActive, !Task.isCancelled else { return }

                debugLog("[CodeSource] OpenClaw attempt \(index + 1)/\(self.retryDelays.count)")

                let code = await self.fetchCodeFromOpenClaw()
                if let code {
                    await MainActor.run {
                        self.deliverCode(code, source: "OpenClaw")
                    }
                    return // Success — stop retrying
                }

                debugLog("[CodeSource] OpenClaw attempt \(index + 1) — no code found")
            }

            debugLog("[CodeSource] OpenClaw — all \(self.retryDelays.count) attempts exhausted")
        }
    }

    /// Single attempt to fetch a verification code from OpenClaw.
    private func fetchCodeFromOpenClaw() async -> String? {
        guard let service = openClawService else {
            debugLog("[CodeSource] OpenClaw service not configured")
            return nil
        }

        let prompt = """
        [AUTO-VERIFY] Read the most recent emails (last 5 minutes) and extract any verification/OTP code.

        Instructions:
        1. Run: himalaya envelope list --max-width 0 --page-size 5
        2. For each email received within the last 5 minutes, run: himalaya message read <ID> --header From --header Subject
        3. Look for 4-8 digit verification codes in the email body
        4. Return the MOST RECENT code found

        Response format (STRICT JSON, nothing else):
        {"code":"123456","from":"noreply@example.com","subject":"Your verification code","age_seconds":30}

        If no verification code found:
        {"code":null,"reason":"no recent verification email found"}
        """

        // Collect the full response from SSE stream
        var fullText = ""
        do {
            for try await event in service.executeCommand(prompt: prompt) {
                switch event {
                case .delta(let text):
                    fullText += text
                case .error(let msg):
                    debugLog("[CodeSource] OpenClaw error: \(msg)")
                    return nil
                default:
                    break
                }
            }
        } catch {
            debugLog("[CodeSource] OpenClaw request failed: \(error.localizedDescription)")
            return nil
        }

        debugLog("[CodeSource] OpenClaw response: \(fullText.prefix(500))")

        // Parse the response
        let parsed = parseOTPResponse(fullText)
        if let reason = parsed.reason, parsed.code == nil {
            debugLog("[CodeSource] OpenClaw no code: \(reason)")
        }
        return parsed.code
    }

    // MARK: - Response parsing

    private struct OTPResponse {
        let code: String?
        let from: String?
        let subject: String?
        let reason: String?
    }

    private func parseOTPResponse(_ text: String) -> OTPResponse {
        // Step 1: Try to extract JSON from the response
        let jsonPattern = "\\{[^{}]*\"code\"[^{}]*\\}"
        if let jsonRange = text.range(of: jsonPattern, options: .regularExpression),
           let data = String(text[jsonRange]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let code = json["code"] as? String  // nil if JSON null
            return OTPResponse(
                code: code,
                from: json["from"] as? String,
                subject: json["subject"] as? String,
                reason: json["reason"] as? String
            )
        }

        // Step 2: Fallback — regex extract any 4-8 digit code
        if let code = extractCode(from: text) {
            return OTPResponse(code: code, from: nil, subject: nil, reason: nil)
        }

        return OTPResponse(code: nil, from: nil, subject: nil, reason: "parse_error")
    }

    // MARK: - Notification Center (secondary source)

    private func startNotificationMonitor() {
        guard let ncApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        ).first else {
            debugLog("[CodeSource] Notification Center process not found")
            return
        }

        let pid = ncApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        let callback: AXObserverCallback = { _, element, _, refcon in
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

    private func extractTexts(from element: AXUIElement, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        var texts: [String] = []
        let attrs = AXAttributes(element: element)
        if let v = attrs.value { texts.append(v) }
        if let t = attrs.title { texts.append(t) }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                texts += extractTexts(from: child, depth: depth - 1)
            }
        }
        return texts
    }

    // MARK: - Code extraction (regex engine — fallback for raw text parsing)

    func extractCode(from text: String) -> String? {
        // First try: code near a keyword (higher confidence)
        let keywordPattern = "(?:verification|code|verify|OTP|验证码|校验码|确认码|認証コード|인증번호|Bestätigungscode|código)\\s*[:：]?\\s*(\\d{4,8})"
        if let match = text.range(of: keywordPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                return String(matchStr[codeMatch])
            }
        }

        // Second try: digit sequence before keyword
        let reversedPattern = "(\\d{4,8})\\s*(?:is your|is the|为您的|是您的)"
        if let match = text.range(of: reversedPattern, options: [.regularExpression, .caseInsensitive]) {
            let matchStr = String(text[match])
            if let codeMatch = matchStr.range(of: "\\d{4,8}", options: .regularExpression) {
                return String(matchStr[codeMatch])
            }
        }

        // Third try: any standalone 4-8 digit sequence near keywords
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
