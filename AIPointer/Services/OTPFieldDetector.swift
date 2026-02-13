import Cocoa
import ApplicationServices

/// Detects whether a focused UI element is a verification code / OTP input field.
/// Uses a tier-based approach derived from W3C standards, Chromium autofill heuristics,
/// and real-world HTML patterns from major websites.
struct OTPFieldDetector {

    enum Confidence {
        case none
        case tier3  // Combo signals (numeric + maxlength, placeholder format, etc.)
        case tier2  // High confidence (id/name/class contains OTP keywords)
        case tier1  // Definitive (autocomplete="one-time-code", exact id match, split OTP)
    }

    /// Analyze the given AXUIElement and return detection confidence.
    static func detect(element: AXUIElement) -> Confidence {
        let attrs = AXAttributes(element: element)

        // Only check text input fields
        guard attrs.isTextField else { return .none }

        // --- Tier 1: Definitive signals ---

        // W3C autocomplete="one-time-code" (exposed as AXAutocomplete in browsers)
        if let autocomplete = attrs.autocomplete?.lowercased(),
           autocomplete.contains("one-time-code") {
            return .tier1
        }

        // Exact id/name match for common OTP field identifiers
        let identifiers = [attrs.domId, attrs.domName, attrs.identifier].compactMap { $0?.lowercased() }
        for id in identifiers {
            if tier1ExactIds.contains(id) {
                return .tier1
            }
        }

        // Split OTP pattern: multiple single-char inputs in sequence
        if attrs.maxLength == 1, isSplitOTPGroup(element: element) {
            return .tier1
        }

        // --- Tier 2: High confidence (keyword in id/name/class) ---

        let allIdentifiers = identifiers + [attrs.domClass].compactMap { $0?.lowercased() }
        for id in allIdentifiers {
            for keyword in tier2Keywords {
                if id.contains(keyword) {
                    return .tier2
                }
            }
        }

        // Tier 2: placeholder, label, description, or title matches verification patterns
        let textHints = [attrs.placeholderValue, attrs.label, attrs.axDescription, attrs.title]
            .compactMap { $0 }
        for text in textHints {
            if matchesVerificationPattern(text) {
                return .tier2
            }
        }

        // --- Tier 3: Combination signals ---

        var signals = 0

        // Numeric-only input with appropriate max length (4-8 digits)
        if isNumericConstrained(attrs: attrs) {
            signals += 1
        }

        // Placeholder or label text matches verification code patterns
        let textFields = [attrs.placeholderValue, attrs.label, attrs.axDescription, attrs.title]
            .compactMap { $0 }
        for text in textFields {
            if matchesVerificationPattern(text) {
                signals += 1
                break
            }
        }

        // Window title contains verification-related keywords
        if let windowTitle = attrs.windowTitle, matchesVerificationPattern(windowTitle) {
            signals += 1
        }

        // inputmode="numeric" or type="tel" (browsers expose as AX attributes)
        if let inputMode = attrs.inputMode?.lowercased(),
           inputMode == "numeric" || inputMode == "tel" {
            signals += 1
        }

        return signals >= 2 ? .tier3 : .none
    }

    // MARK: - Tier 1 exact IDs (from real websites)

    private static let tier1ExactIds: Set<String> = [
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

    // MARK: - Tier 2 keywords (substring match in id/name/class)

    private static let tier2Keywords: [String] = [
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

    // MARK: - Tier 3 helpers

    /// Check if the element is part of a split OTP group (multiple single-digit inputs).
    private static func isSplitOTPGroup(element: AXUIElement) -> Bool {
        // Get the parent and check if it has multiple single-char text field children
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return false }
        let parentElement = parent as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parentElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        // Count text fields with maxLength == 1
        var singleCharCount = 0
        for child in children {
            let childAttrs = AXAttributes(element: child)
            if childAttrs.isTextField && childAttrs.maxLength == 1 {
                singleCharCount += 1
            }
        }

        // Typical split OTP: 4-8 single-char inputs
        return singleCharCount >= 4 && singleCharCount <= 8
    }

    /// Check if the field constrains input to numeric with appropriate length.
    private static func isNumericConstrained(attrs: AXAttributes) -> Bool {
        let maxLen = attrs.maxLength ?? 0
        guard maxLen >= 4 && maxLen <= 8 else { return false }

        // Check inputmode, type, or pattern attributes
        if let inputMode = attrs.inputMode?.lowercased(),
           inputMode == "numeric" || inputMode == "tel" {
            return true
        }
        if let inputType = attrs.inputType?.lowercased(),
           inputType == "number" || inputType == "tel" {
            return true
        }
        // Pattern like [0-9]* or \d{6}
        if let pattern = attrs.pattern,
           pattern.contains("[0-9]") || pattern.contains("\\d") {
            return true
        }
        return false
    }

    /// Match text against verification code patterns in multiple languages.
    private static func matchesVerificationPattern(_ text: String) -> Bool {
        let lower = text.lowercased()
        for pattern in verificationPatterns {
            if lower.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// Verification code keywords across languages.
    private static let verificationPatterns: [String] = [
        // English
        "verification code", "verify code", "security code",
        "one-time", "otp", "2fa", "mfa",
        "enter code", "enter the code", "digit code",
        "passcode", "pin code",
        "sent to your", "sent a code", "code sent",

        // Chinese (Simplified + Traditional)
        "验证码", "校验码", "确认码", "动态码",
        "驗證碼", "確認碼",
        "短信验证", "邮箱验证", "邮件验证",

        // Japanese
        "確認コード", "認証コード", "検証コード",
        "ワンタイムパスワード",

        // Korean
        "인증번호", "인증 코드", "확인 코드",

        // German
        "bestätigungscode", "verifizierungscode", "sicherheitscode",

        // French
        "code de vérification", "code de confirmation", "code de sécurité",

        // Spanish
        "código de verificación", "código de confirmación", "código de seguridad",

        // Portuguese
        "código de verificação",

        // Russian
        "код подтверждения", "код верификации",
    ]
}

// MARK: - AXAttributes helper

/// Convenience wrapper for reading AXUIElement attributes.
struct AXAttributes {
    let element: AXUIElement

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
