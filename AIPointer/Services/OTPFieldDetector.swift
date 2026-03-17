import Cocoa
import ApplicationServices

/// Detects whether a focused UI element is a verification code / OTP input field.
///
/// Design principles:
/// - Only examine the field's own attributes and immediate form structure
/// - Never scan page text content (causes false positives in rich editors like Notion)
/// - Follow browser industry practice: autocomplete attribute > field identifiers > form structure
struct OTPFieldDetector {

    enum Confidence {
        case none
        case detected   // Sufficient signals to trigger monitoring
        case definitive // Explicit standard signal (autocomplete, exact id, split OTP)
    }

    /// Analyze the given AXUIElement and return detection confidence.
    static func detect(element: AXUIElement) -> Confidence {
        let attrs = AXAttributes(element: element)

        // Only check single-line text input fields.
        // OTP fields are always <input> (AXTextField), never <textarea> (AXTextArea).
        // This filters out rich text editors (Notion, Google Docs, etc.).
        guard attrs.isSingleLineTextField else { return .none }

        // --- Definitive: single signal is enough ---

        // W3C autocomplete="one-time-code" — the gold standard
        if let autocomplete = attrs.autocomplete?.lowercased(),
           autocomplete.contains("one-time-code") {
            return .definitive
        }

        // Exact id/name match for known OTP field identifiers
        let identifiers = [attrs.domId, attrs.domName, attrs.identifier].compactMap { $0?.lowercased() }
        for id in identifiers {
            if definitiveIds.contains(id) {
                return .definitive
            }
        }

        // Split OTP: 4-8 single-char inputs grouped together
        if attrs.maxLength == 1, isSplitOTPGroup(element: element) {
            return .definitive
        }
        if attrs.maxLength == nil, isSplitOTPGroup(element: element) {
            return .detected
        }

        // --- Signal scoring: need 2+ independent signals ---
        // Signals must be truly independent facts. "numeric input" and "inputmode=numeric"
        // are the same fact expressed differently, so they count as one signal together.

        var score = 0

        // Signal: OTP keyword in id/name/class (word-boundary matched)
        let allIds = [attrs.domId, attrs.domName, attrs.domClass, attrs.identifier]
            .compactMap { $0?.lowercased() }
        if matchesOTPKeyword(in: allIds) {
            score += 1
        }

        // Signal: placeholder text matches OTP pattern
        if let placeholder = attrs.placeholderValue, matchesOTPPlaceholder(placeholder) {
            score += 1
        }

        // Signal: associated label matches OTP pattern
        if let label = attrs.label, matchesOTPPlaceholder(label) {
            score += 1
        }

        // Signal: short numeric input field (maxlength 4-8 + numeric type/inputmode).
        // This is ONE signal — "numeric" and "maxlength" together describe the same
        // physical characteristic (a short digit-only box). Date fields (dd/mm/yyyy),
        // phone area codes, and zip codes also match, so this alone is weak.
        if isNumericShortField(attrs: attrs) {
            score += 1
        }

        // Signal: nearby submit button has verification-related text
        if hasVerifyButtonNearby(element: element) {
            score += 1
        }

        if score >= 2 {
            return .detected
        }

        return .none
    }

    // MARK: - Definitive IDs (from real websites)

    private static let definitiveIds: Set<String> = [
        // Google
        "idvpin", "totppin",
        // Microsoft
        "idtxtbx_otp_input", "iproofentrypoint",
        // Amazon
        "auth-mfa-otpcode", "cvf-input-code",
        // GitHub
        "otp", "app_totp", "sms_totp",
        // Apple
        "verification_code", "security_code",
        // Stripe
        "otp-input",
        // Generic
        "otpcode", "otp_code", "otp-code",
        "verification-code", "verificationcode",
        "mfa-code", "mfacode", "mfa_code",
        "2fa-code", "2facode",
        "totp", "totp-code",
    ]

    // MARK: - OTP keywords (word-boundary match in id/name/class)

    private static let otpKeywords: [String] = [
        "otp", "totp", "2fa", "mfa",
        "one-time", "onetime",
        "passcode",
        "verification-code", "verificationcode", "verification_code",
        "verify-code", "verifycode", "verify_code",
        "auth-code", "authcode", "auth_code",
        "security-code", "securitycode", "security_code",
        "pin-code", "pincode", "pin_code",
        "sms-code", "smscode", "sms_code",
        "email-code", "emailcode", "email_code",
        "confirm-code", "confirmcode", "confirm_code",
    ]

    private static func matchesOTPKeyword(in identifiers: [String]) -> Bool {
        for id in identifiers {
            for keyword in otpKeywords {
                if id.containsWord(keyword) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Placeholder / label matching

    /// Match placeholder or label text against OTP-specific patterns.
    /// These must be short, field-level hints — not general page content.
    private static let placeholderPatterns: [String] = [
        // English
        "verification code", "security code", "one-time code",
        "enter code", "enter the code", "digit code",
        "enter otp", "enter pin",

        // Chinese
        "验证码", "校验码", "确认码", "动态码",
        "驗證碼", "確認碼",
        "请输入验证码", "输入验证码",

        // Japanese
        "確認コード", "認証コード", "検証コード",

        // Korean
        "인증번호", "인증 코드", "확인 코드",
    ]

    private static func matchesOTPPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        for pattern in placeholderPatterns {
            if lower.contains(pattern) { return true }
        }
        return false
    }

    // MARK: - Numeric short field check

    /// A short numeric-only input (maxlength 4-8 + numeric hint).
    /// Both conditions must hold — this is a single composite signal because
    /// "numeric" and "short" together just mean "small digit box", which is
    /// common in dates, phone prefixes, zip codes, etc.
    private static func isNumericShortField(attrs: AXAttributes) -> Bool {
        let maxLen = attrs.maxLength ?? 0
        guard maxLen >= 4 && maxLen <= 8 else { return false }

        if let inputMode = attrs.inputMode?.lowercased(),
           inputMode == "numeric" || inputMode == "tel" {
            return true
        }
        if let inputType = attrs.inputType?.lowercased(),
           inputType == "number" || inputType == "tel" {
            return true
        }
        if let pattern = attrs.pattern,
           pattern.contains("[0-9]") || pattern.contains("\\d") {
            return true
        }
        return false
    }

    // MARK: - Split OTP group detection

    private static func isSplitOTPGroup(element: AXUIElement) -> Bool {
        var current = element

        for _ in 0..<8 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let parentElement = parent as! AXUIElement

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parentElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { break }

            if children.count <= 1 {
                current = parentElement
                continue
            }

            let count = countTextFieldChildren(among: children)
            if count >= 4 && count <= 8 {
                return true
            }

            let role = AXAttributes(element: parentElement).string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" { break }

            current = parentElement
        }

        return false
    }

    private static func countTextFieldChildren(among children: [AXUIElement]) -> Int {
        var count = 0
        for child in children {
            let childAttrs = AXAttributes(element: child)
            if childAttrs.isSingleLineTextField {
                let maxLen = childAttrs.maxLength
                if maxLen == 1 || maxLen == nil {
                    count += 1
                }
            } else {
                var grandchildrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandchildrenRef) == .success,
                   let grandchildren = grandchildrenRef as? [AXUIElement] {
                    for gc in grandchildren {
                        let gcAttrs = AXAttributes(element: gc)
                        if gcAttrs.isSingleLineTextField {
                            let maxLen = gcAttrs.maxLength
                            if maxLen == 1 || maxLen == nil {
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        return count
    }

    // MARK: - Button proximity detection

    /// Walk up the AX tree to find a form-like container, then check if it has
    /// a submit button with verification-related text ("Verify", "Submit Code", etc.).
    private static func hasVerifyButtonNearby(element: AXUIElement) -> Bool {
        var current = element

        // Walk up at most 6 levels to find a form/group container
        for _ in 0..<6 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let parentElement = parent as! AXUIElement

            let role = AXAttributes(element: parentElement).string(kAXRoleAttribute) ?? ""

            // Stop at web area boundary
            if role == "AXWebArea" || role == "AXScrollArea" { break }

            // Check children of this container for buttons
            if scanForVerifyButton(in: parentElement) {
                return true
            }

            current = parentElement
        }

        return false
    }

    /// Scan direct children (and one level of grandchildren) for buttons with verify text.
    private static func scanForVerifyButton(in container: AXUIElement) -> Bool {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            if isVerifyButton(child) { return true }

            // One level deeper
            var grandchildrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandchildrenRef) == .success,
               let grandchildren = grandchildrenRef as? [AXUIElement] {
                for gc in grandchildren {
                    if isVerifyButton(gc) { return true }
                }
            }
        }
        return false
    }

    private static func isVerifyButton(_ element: AXUIElement) -> Bool {
        let attrs = AXAttributes(element: element)
        let role = attrs.string(kAXRoleAttribute) ?? ""
        guard role == "AXButton" || role == "AXLink" else { return false }

        let texts = [attrs.title, attrs.value, attrs.axDescription, attrs.label]
            .compactMap { $0?.lowercased() }

        for text in texts {
            for pattern in buttonPatterns {
                if text.contains(pattern) { return true }
            }
        }
        return false
    }

    /// Button text patterns that indicate a verification code form.
    /// Must be OTP-specific — avoid generic words like "verify" or "validate"
    /// which appear on many non-OTP forms (immigration, identity, payment).
    private static let buttonPatterns: [String] = [
        // English — code-specific
        "verify code", "confirm code", "submit code",
        "resend code", "send code", "send again",
        "didn't receive", "didn\u{2019}t receive",
        "resend otp", "send otp",

        // Chinese — code-specific
        "确认验证码", "发送验证码", "重新发送验证码",
        "获取验证码", "重新获取验证码", "发送动态码",
        "確認驗證碼", "發送驗證碼",

        // Japanese
        "コードを送信", "コード再送信",

        // Korean
        "코드 전송", "코드 재전송",
    ]
}

// MARK: - AXAttributes helper

/// Convenience wrapper for reading AXUIElement attributes.
struct AXAttributes {
    let element: AXUIElement

    /// Single-line text input only. Excludes AXTextArea (rich editors, contenteditable).
    var isSingleLineTextField: Bool {
        guard let role = string(kAXRoleAttribute) else { return false }
        return role == kAXTextFieldRole as String
            || subrole == kAXSecureTextFieldSubrole as String
    }

    /// Any text input including multi-line (kept for other use cases).
    var isTextField: Bool {
        guard let role = string(kAXRoleAttribute) else { return false }
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || subrole == kAXSecureTextFieldSubrole as String
    }

    var subrole: String? { string(kAXSubroleAttribute) }
    var identifier: String? { string(kAXIdentifierAttribute) }
    var placeholderValue: String? { string(kAXPlaceholderValueAttribute) }
    var label: String? { string(kAXLabelValueAttribute) }
    var axDescription: String? { string(kAXDescriptionAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var value: String? { string(kAXValueAttribute) }
    var windowTitle: String? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success else { return nil }
        let window = windowRef as! AXUIElement
        return AXAttributes(element: window).title
    }

    // Browser-specific DOM attributes (exposed via AX enhanced mode)
    var autocomplete: String? { string("AXAutocomplete") }
    var domId: String? { string("AXDOMIdentifier") }
    var domName: String? { string("AXDOMName" as CFString) }
    var domClass: String? { string("AXDOMClassList") }
    var inputMode: String? { string("AXInputMode") }
    var inputType: String? { string("AXInputType") }
    var pattern: String? { string("AXPattern") }

    var maxLength: Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMaxLength" as CFString, &ref) == .success else { return nil }
        if let num = ref as? NSNumber { return num.intValue }
        return nil
    }

    func string(_ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    func string(_ attr: CFString) -> String? {
        string(attr as String)
    }
}

// MARK: - Word-boundary matching

private extension String {
    /// Check if `word` appears as a whole word within the string.
    /// Word boundaries are: start/end of string, or any non-alphanumeric character.
    /// Examples for word = "otp":
    ///   "otp_field" → true,  "sms-otp" → true,  "otp" → true
    ///   "tooltip"   → false, "optional" → false, "footprint" → false
    func containsWord(_ word: String) -> Bool {
        guard let range = self.range(of: word) else { return false }
        let before = range.lowerBound == startIndex || {
            let c = self[self.index(before: range.lowerBound)]
            return !(c.isLetter || c.isNumber)
        }()
        let after = range.upperBound == endIndex || {
            let c = self[range.upperBound]
            return !(c.isLetter || c.isNumber)
        }()
        return before && after
    }
}
