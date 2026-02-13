import Cocoa
import ApplicationServices

/// Orchestrates the verification code auto-fill lifecycle:
/// 1. AccessibilityMonitor detects focused element changes
/// 2. OTPFieldDetector checks if the focused element is an OTP field
/// 3. If yes → transition to .monitoring (green dot), start CodeSourceMonitor
/// 4. If focus leaves OTP field → .idle (no visual), but keep monitoring in background
/// 5. CodeSourceMonitor finds a code:
///    - If focused on OTP → .codeReady → auto-fill
///    - If not focused → stash as pendingCode (delivered when user refocuses OTP field)
/// 6. After 1 second delay → auto-fill the code into the field → .idle
///
/// Auto-stop conditions:
/// - Code successfully filled
/// - User typed 4-8 digits manually
/// - 3 minute overall timeout
@MainActor
final class VerificationService {
    var onStateChanged: ((PointerState) -> Void)?

    private let accessibilityMonitor = AccessibilityMonitor()
    private let codeSourceMonitor = CodeSourceMonitor()

    private var currentOTPField: AXUIElement?
    private var isMonitoring = false
    private var focusedOnOTP = false
    private var pendingCode: String?
    private var autoFillTimer: Timer?
    private var pendingCodeTimer: Timer?
    private var fieldValueCheckTimer: Timer?
    private var overallTimer: Timer?

    /// Delay before auto-filling (1 second).
    private let autoFillDelay: TimeInterval = 1.0

    /// Time to keep pendingCode alive after leaving OTP field (30 seconds).
    private let pendingCodeTimeout: TimeInterval = 30.0

    /// Overall timeout for the monitoring session (3 minutes).
    private let overallTimeout: TimeInterval = 180.0

    // MARK: - Lifecycle

    func start() {
        accessibilityMonitor.onFocusedElementChanged = { [weak self] element in
            Task { @MainActor in
                self?.handleFocusChange(element: element)
            }
        }

        codeSourceMonitor.onCodeFound = { [weak self] code in
            Task { @MainActor in
                self?.handleCodeFound(code)
            }
        }

        accessibilityMonitor.start()
    }

    func stop() {
        stopMonitoring()
        accessibilityMonitor.stop()
    }

    // MARK: - Focus handling

    private func handleFocusChange(element: AXUIElement) {
        let confidence = OTPFieldDetector.detect(element: element)
        debugLog("[Verify] handleFocusChange → confidence=\(confidence), isMonitoring=\(isMonitoring), pendingCode=\(pendingCode ?? "nil")")

        switch confidence {
        case .tier1, .tier2, .tier3:
            focusedOnOTP = true
            pendingCodeTimer?.invalidate()
            pendingCodeTimer = nil

            if !isMonitoring {
                startMonitoring(field: element)
            } else {
                currentOTPField = element
            }

            // If we have a code waiting, deliver it now
            if let code = pendingCode {
                pendingCode = nil
                onStateChanged?(.codeReady(code: code))
                autoFillTimer?.invalidate()
                autoFillTimer = Timer.scheduledTimer(withTimeInterval: autoFillDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.performAutoFill(code: code)
                    }
                }
            } else {
                onStateChanged?(.monitoring)
            }

        case .none:
            focusedOnOTP = false
            if isMonitoring {
                // Hide visual but keep monitoring in background
                onStateChanged?(.idle)
                startPendingCodeTimer()
            }
        }
    }

    // MARK: - Monitoring lifecycle

    private func startMonitoring(field: AXUIElement) {
        isMonitoring = true
        focusedOnOTP = true
        currentOTPField = field
        pendingCode = nil

        onStateChanged?(.monitoring)
        codeSourceMonitor.start()
        startFieldValueChecking()
        startOverallTimer()
    }

    private func stopMonitoring() {
        isMonitoring = false
        focusedOnOTP = false
        currentOTPField = nil
        pendingCode = nil

        autoFillTimer?.invalidate()
        autoFillTimer = nil
        pendingCodeTimer?.invalidate()
        pendingCodeTimer = nil
        fieldValueCheckTimer?.invalidate()
        fieldValueCheckTimer = nil
        overallTimer?.invalidate()
        overallTimer = nil

        codeSourceMonitor.stop()

        onStateChanged?(.idle)
    }

    // MARK: - Code found → auto-fill

    private func handleCodeFound(_ code: String) {
        guard isMonitoring else { return }

        debugLog("[Verify] handleCodeFound → code=\(code), focusedOnOTP=\(focusedOnOTP)")

        if focusedOnOTP {
            // User is on the OTP field — show and auto-fill
            onStateChanged?(.codeReady(code: code))
            autoFillTimer?.invalidate()
            autoFillTimer = Timer.scheduledTimer(withTimeInterval: autoFillDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.performAutoFill(code: code)
                }
            }
        } else {
            // User is not on the OTP field — stash for later
            pendingCode = code
            debugLog("[Verify] Code stashed as pendingCode (focus not on OTP field)")
        }
    }

    private func performAutoFill(code: String) {
        guard isMonitoring, let field = currentOTPField else {
            stopMonitoring()
            return
        }

        // Check if the field already has a value (user may have typed it themselves)
        let attrs = AXAttributes(element: field)
        if let existingValue = attrs.value,
           existingValue.count >= 4,
           existingValue.allSatisfy({ $0.isNumber }) {
            // User already filled it, just stop
            stopMonitoring()
            return
        }

        // Try to set the value directly via AX
        let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, code as CFTypeRef)

        if result == .success {
            stopMonitoring()
        } else {
            // Fallback: simulate keyboard input
            simulateKeyboardInput(code: code, into: field)
            stopMonitoring()
        }
    }

    /// Fallback: focus the element and type the code character by character.
    private func simulateKeyboardInput(code: String, into field: AXUIElement) {
        // First, set focus to the field
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, true as CFTypeRef)

        // Select all existing text and replace
        let selectAllEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true) // Cmd+A
        selectAllEvent?.flags = .maskCommand
        selectAllEvent?.post(tap: .cghidEventTap)
        let selectAllUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: false)
        selectAllUp?.flags = .maskCommand
        selectAllUp?.post(tap: .cghidEventTap)

        // Type each character with a small delay
        for (i, char) in code.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.03) {
                let str = String(char)
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let chars = Array(str.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                event?.post(tap: .cghidEventTap)

                let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                upEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Field value monitoring (detect user self-resolution)

    private func startFieldValueChecking() {
        fieldValueCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkFieldValue()
            }
        }
    }

    private func checkFieldValue() {
        guard isMonitoring, let field = currentOTPField else { return }

        // Check if user typed a code themselves
        let attrs = AXAttributes(element: field)
        if let value = attrs.value,
           value.count >= 4,
           value.allSatisfy({ $0.isNumber }) {
            stopMonitoring()
        }
    }

    // MARK: - Pending code timer (soft timeout for stashed codes)

    private func startPendingCodeTimer() {
        pendingCodeTimer?.invalidate()
        pendingCodeTimer = Timer.scheduledTimer(withTimeInterval: pendingCodeTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                debugLog("[Verify] Pending code timeout — clearing pendingCode")
                self.pendingCode = nil
            }
        }
    }

    // MARK: - Overall timeout (3 minutes)

    private func startOverallTimer() {
        overallTimer?.invalidate()
        overallTimer = Timer.scheduledTimer(withTimeInterval: overallTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                debugLog("[Verify] Overall timeout (3 min) — stopping monitoring")
                self?.stopMonitoring()
            }
        }
    }

    deinit {
        autoFillTimer?.invalidate()
        pendingCodeTimer?.invalidate()
        fieldValueCheckTimer?.invalidate()
        overallTimer?.invalidate()
    }
}
