# OTP Detection: Known Limitations

## Custom div-based OTP inputs

**Affected sites**: Substack, and others using custom UI component libraries for split OTP input.

**Symptom**: OTP detection does not trigger when focusing the code input boxes.

**Root cause**: These sites use `<div>` + JS event listeners (or Shadow DOM) instead of standard `<input>` elements. Chrome's AX bridge reports the focused element as `AXWebArea` (the entire web page) instead of individual input fields. Our detector never receives the actual input element, so no detection can occur.

**Discovered**: 2026-03-17 on substack.com.

### Potential future approaches

| Approach | Pros | Cons |
|----------|------|------|
| Chrome DevTools Protocol | Can inspect actual DOM, works with any element | Requires connecting to Chrome's debug port; privacy concerns |
| Browser extension | Full DOM access, can detect any field type | Requires user to install an extension; maintenance burden |
| Clipboard monitoring | Detects pasted codes regardless of field type | Only works if user copies/pastes; doesn't detect the field itself |
| Notification-based standalone trigger | Already exists (CodeSourceMonitor); no field detection needed | Can't auto-fill without knowing which field to fill |

### Current workaround

For sites with custom OTP inputs, users must manually type or paste the verification code. The `CodeSourceMonitor` (email/notification monitoring) still detects incoming codes, but cannot auto-fill without a recognized OTP field.
