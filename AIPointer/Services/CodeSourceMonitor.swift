import Cocoa
import ApplicationServices

/// Monitors verification code sources:
/// - Primary: himalaya CLI (reads email via IMAP directly)
/// - Secondary: Notification Center (catches SMS/notification banners)
final class CodeSourceMonitor {
    var onCodeFound: ((String) -> Void)?

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

        // Start himalaya retry sequence
        startHimalayaRetries()
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

    // MARK: - Himalaya CLI (primary source)

    private func startHimalayaRetries() {
        retryTask = Task { [weak self] in
            guard let self else { return }

            for (index, delay) in self.retryDelays.enumerated() {
                guard self.isActive, !Task.isCancelled else { return }

                // Wait before attempt
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.isActive, !Task.isCancelled else { return }

                debugLog("[CodeSource] Himalaya attempt \(index + 1)/\(self.retryDelays.count)")

                let code = await self.fetchCodeFromHimalaya()
                if let code {
                    await MainActor.run {
                        self.deliverCode(code, source: "Himalaya")
                    }
                    return // Success — stop retrying
                }

                debugLog("[CodeSource] Himalaya attempt \(index + 1) — no code found")
            }

            debugLog("[CodeSource] Himalaya — all \(self.retryDelays.count) attempts exhausted")
        }
    }

    /// Single attempt to fetch a verification code by calling himalaya CLI directly.
    private func fetchCodeFromHimalaya() async -> String? {
        // Check if himalaya is available
        guard let himalayaPath = findHimalaya() else {
            debugLog("[CodeSource] himalaya CLI not found")
            return nil
        }

        // Step 1: List recent envelopes
        guard let envelopeOutput = runShell(himalayaPath, arguments: ["envelope", "list", "--max-width", "500", "--page-size", "5"]) else {
            debugLog("[CodeSource] Failed to list envelopes")
            return nil
        }

        debugLog("[CodeSource] Envelope list: \(envelopeOutput.prefix(500))")

        // Step 2: Parse envelope IDs from the output
        let ids = parseEnvelopeIds(envelopeOutput)
        guard !ids.isEmpty else {
            debugLog("[CodeSource] No envelope IDs found")
            return nil
        }

        // Step 3: Read each message and try to extract a code
        for id in ids {
            guard let body = runShell(himalayaPath, arguments: ["message", "read", id]) else {
                continue
            }

            debugLog("[CodeSource] Message \(id) body: \(body.prefix(300))")

            if let code = extractCode(from: body) {
                debugLog("[CodeSource] Found code \(code) in message \(id)")
                return code
            }
        }

        return nil
    }

    /// Locate the himalaya binary.
    private func findHimalaya() -> String? {
        let candidates = [
            "/opt/homebrew/bin/himalaya",
            "/usr/local/bin/himalaya",
            NSString(string: "~/.local/bin/himalaya").expandingTildeInPath
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try `which`
        if let whichOutput = runShell("/usr/bin/which", arguments: ["himalaya"]),
           !whichOutput.isEmpty {
            let path = whichOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Run a shell command and return stdout, or nil on failure.
    private func runShell(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            debugLog("[CodeSource] Shell error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse envelope IDs from himalaya envelope list output.
    /// Himalaya v1.x outputs a pipe-delimited table:
    ///   | 21142 | * | Your Typeless verification code | Typeless Team | 2026-03-13 ... |
    private func parseEnvelopeIds(_ output: String) -> [String] {
        var ids: [String] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split by both ASCII pipe "|" and Unicode box-drawing "│"
            let columns = trimmed.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // Also try Unicode pipe
            let columnsUnicode = trimmed.components(separatedBy: "│")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let candidates = columns.count > columnsUnicode.count ? columns : columnsUnicode

            // First column should be the ID (numeric)
            if let firstCol = candidates.first {
                let idCandidate = firstCol.trimmingCharacters(in: .whitespaces)
                if !idCandidate.isEmpty && idCandidate.allSatisfy({ $0.isNumber }) {
                    ids.append(idCandidate)
                }
            }
        }

        return ids
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

    // MARK: - Code extraction (regex engine)

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
