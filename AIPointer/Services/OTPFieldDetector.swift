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
    /// Also logs the reason for debugging false positives.
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

        // Split OTP with unknown maxLength but strong structural signal
        if attrs.maxLength == nil, isSplitOTPGroup(element: element) {
            return .tier2
        }

        // --- Tier 2: High confidence (keyword in id/name/class/identifier) ---
        // Uses word-boundary matching: "otp" matches "otp_field" / "sms-otp"
        // but NOT "tooltip" or "optional".

        let allIdentifiers = [attrs.domId, attrs.domName, attrs.domClass, attrs.identifier]
            .compactMap { $0?.lowercased() }
        for id in allIdentifiers {
            for keyword in tier2Keywords {
                if id.containsWord(keyword) {
                    return .tier2
                }
            }
        }

        // Tier 2: placeholder, label, description matches verification patterns
        // (but NOT title — window/element titles are too noisy)
        let textHints = [attrs.placeholderValue, attrs.label, attrs.axDescription]
            .compactMap { $0 }
        for text in textHints {
            if matchesVerificationPattern(text) {
                return .tier2
            }
        }

        // --- Tier 3: Combination signals (need 3+ to trigger) ---

        var signals: [String] = []

        // Numeric-only input with appropriate max length (4-8 digits)
        if isNumericConstrained(attrs: attrs) {
            signals.append("numericConstrained(maxLen=\(attrs.maxLength ?? 0))")
        }

        // inputmode="numeric" or type="tel" (browsers expose as AX attributes)
        if let inputMode = attrs.inputMode?.lowercased(),
           inputMode == "numeric" || inputMode == "tel" {
            signals.append("inputMode=\(inputMode)")
        }

        // Placeholder or label text matches verification code patterns
        for text in textHints {
            if matchesVerificationPattern(text) {
                signals.append("textHint='\(text.prefix(40))'")
                break
            }
        }

        // Window title contains verification-related keywords
        if let windowTitle = attrs.windowTitle, matchesVerificationPattern(windowTitle) {
            signals.append("windowTitle='\(windowTitle.prefix(40))'")
        }

        // Nearby text contains OTP-related phrases
        if scanNearbyText(element: element) {
            signals.append("nearbyText")
        }

        if signals.count >= 3 {
            return .tier3
        }

        return .none
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

    // MARK: - Tier 2 keywords (word-boundary match in id/name/class/identifier)
    // Safe to use short terms because containsWord() requires word boundaries:
    // "otp" matches "otp_field", "sms-otp" but NOT "tooltip", "optional"

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
            if childAttrs.isTextField {
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
                        if gcAttrs.isTextField {
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

    /// Check if the field constrains input to numeric with appropriate length.
    private static func isNumericConstrained(attrs: AXAttributes) -> Bool {
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

    /// Scan text content near the focused element for OTP-related phrases.
    private static func scanNearbyText(element: AXUIElement) -> Bool {
        var collected = ""
        var current = element

        for _ in 0..<5 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let parentElement = parent as! AXUIElement

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(parentElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                if children.count > 1 {
                    for child in children {
                        collectText(from: child, into: &collected, depth: 2)
                    }
                    let lower = collected.lowercased()
                    for phrase in pageContextPatterns {
                        if lower.contains(phrase) { return true }
                    }
                }
            }

            let role = AXAttributes(element: parentElement).string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" { break }

            current = parentElement
        }

        return false
    }

    private static func collectText(from element: AXUIElement, into buffer: inout String, depth: Int) {
        let attrs = AXAttributes(element: element)
        if let v = attrs.value, !v.isEmpty { buffer += " " + v }
        if let t = attrs.title, !t.isEmpty { buffer += " " + t }
        if let d = attrs.axDescription, !d.isEmpty { buffer += " " + d }

        guard depth > 1 else { return }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectText(from: child, into: &buffer, depth: depth - 1)
            }
        }
    }

    /// High-confidence page-level phrases that indicate an OTP flow.
    /// Each phrase must be specific enough to avoid matching general UI text.
    private static let pageContextPatterns: [String] = [
        // English — multi-word, specific to OTP flows
        "check your email", "check your inbox",
        "enter the code", "enter code below",
        "sent a code", "sent you a code",
        "we've sent", "we\u{2019}ve sent",
        "verification code",

        // Chinese — these are specific enough (2+ chars forming a distinct term)
        "验证码", "校验码", "确认码",
        "驗證碼", "確認碼",

        // Japanese
        "確認コード", "認証コード", "コードを入力",

        // Korean
        "인증번호", "인증 코드", "코드를 입력",
    ]

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
    /// Each must be specific enough to avoid matching general UI text.
    private static let verificationPatterns: [String] = [
        // English — multi-word or sufficiently unique
        "verification code", "verify code", "security code",
        "one-time code", "one-time password",
        "enter code", "enter the code", "digit code",
        "sent to your", "sent a code", "code sent",
        "check your email", "check your inbox",
        "confirm your email",

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
