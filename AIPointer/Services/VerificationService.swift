import Cocoa
import ApplicationServices

/// Orchestrates the verification code auto-fill lifecycle:
/// 1. AccessibilityMonitor detects focused element changes
/// 2. OTPFieldDetector checks if the focused element is an OTP field
/// 3. If yes → transition to .monitoring, start CodeSourceMonitor
/// 4. CodeSourceMonitor finds a code → transition to .codeReady
/// 5. After 1 second delay → auto-fill the code into the field → .idle
///
/// Auto-stop conditions:
/// - Code successfully filled
/// - User typed 4-8 digits manually
/// - User left the OTP field for 30 seconds
/// - 3 minute overall timeout
@MainActor
final class VerificationService {
    var onStateChanged: ((PointerState) -> Void)?

    private let accessibilityMonitor = AccessibilityMonitor()
    private let codeSourceMonitor = CodeSourceMonitor()

    private var currentOTPField: AXUIElement?
    private var isMonitoring = false
    private var autoFillTimer: Timer?
    private var fieldLeftTimer: Timer?
    private var fieldValueCheckTimer: Timer?

    /// Delay before auto-filling (1 second).
    private let autoFillDelay: TimeInterval = 1.0

    /// Time after leaving OTP field before stopping (30 seconds).
    private let fieldLeftTimeout: TimeInterval = 30.0

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

        switch confidence {
        case .tier1, .tier2, .tier3:
            if !isMonitoring {
                startMonitoring(field: element)
            } else {
                // Update the tracked field (user may have moved to a different OTP field)
                currentOTPField = element
                fieldLeftTimer?.invalidate()
                fieldLeftTimer = nil
            }

        case .none:
            if isMonitoring {
                // User left the OTP field — start the 30s countdown
                startFieldLeftTimer()
            }
        }
    }

    // MARK: - Monitoring lifecycle

    private func startMonitoring(field: AXUIElement) {
        isMonitoring = true
        currentOTPField = field

        onStateChanged?(.monitoring)
        codeSourceMonitor.start()
        startFieldValueChecking()
    }

    private func stopMonitoring() {
        isMonitoring = false
        currentOTPField = nil

        autoFillTimer?.invalidate()
        autoFillTimer = nil
        fieldLeftTimer?.invalidate()
        fieldLeftTimer = nil
        fieldValueCheckTimer?.invalidate()
        fieldValueCheckTimer = nil

        codeSourceMonitor.stop()

        onStateChanged?(.idle)
    }

    // MARK: - Code found → auto-fill

    private func handleCodeFound(_ code: String) {
        guard isMonitoring else { return }

        // Show the code in the cursor
        onStateChanged?(.codeReady(code: code))

        // Auto-fill after 1 second
        autoFillTimer?.invalidate()
        autoFillTimer = Timer.scheduledTimer(withTimeInterval: autoFillDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoFill(code: code)
            }
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
            // Confirm the value was set by posting a value changed notification
            AXUIElementPostNotification(field, kAXValueChangedNotification as CFString)
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

        // Check timeout
        if codeSourceMonitor.isTimedOut {
            stopMonitoring()
            return
        }

        // Check if user typed a code themselves
        let attrs = AXAttributes(element: field)
        if let value = attrs.value,
           value.count >= 4,
           value.allSatisfy({ $0.isNumber }) {
            stopMonitoring()
        }
    }

    // MARK: - Field left timer

    private func startFieldLeftTimer() {
        fieldLeftTimer?.invalidate()
        fieldLeftTimer = Timer.scheduledTimer(withTimeInterval: fieldLeftTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopMonitoring()
            }
        }
    }

    deinit {
        autoFillTimer?.invalidate()
        fieldLeftTimer?.invalidate()
        fieldValueCheckTimer?.invalidate()
    }
}
