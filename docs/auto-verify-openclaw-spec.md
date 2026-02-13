# AIPointer Auto-Verify — Technical Specification

> **Purpose**: This document defines the implementation spec for AIPointer's auto-verify feature, specifically the OpenClaw integration for fetching verification codes via IMAP (himalaya CLI).
>
> **Audience**: Claude Code (or any coding agent implementing this spec)
>
> **Author**: Friday (OpenClaw AI assistant), in collaboration with Han
>
> **Date**: 2026-02-13

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  AIPointer App                                           │
│                                                          │
│  AccessibilityMonitor → OTPFieldDetector (UNCHANGED)     │
│           ↓                                              │
│  VerificationService (MINOR CHANGES)                     │
│           ↓                                              │
│  CodeSourceMonitor (REWRITE)                             │
│     ├── OpenClawCodeSource (NEW) ← calls OpenClaw API   │
│     └── NotificationCodeSource (KEEP) ← AX observer     │
│                                                          │
│  OpenClawService (ADD executeCommand method)             │
└──────────────┬──────────────────────────────────────────┘
               │
               │ HTTP POST (OpenAI chat completions format)
               ▼
┌─────────────────────────────────────────────────────────┐
│  OpenClaw (localhost:18789)                               │
│  Receives request → runs himalaya CLI → extracts code    │
│  → returns structured JSON response                      │
└─────────────────────────────────────────────────────────┘
```

### What to change

| Component | Action | Scope |
|-----------|--------|-------|
| `OTPFieldDetector.swift` | **NO CHANGE** | — |
| `AccessibilityMonitor.swift` | **NO CHANGE** | — |
| `VerificationService.swift` | **MINOR CHANGE** | Retry timing |
| `CodeSourceMonitor.swift` | **REWRITE** | Replace Mail.app + Chrome JS with OpenClaw API |
| `OpenClawService.swift` | **ADD METHOD** | `executeCommand()` for stateless requests |
| `SettingsView.swift` | **OPTIONAL CLEANUP** | Can simplify later |

---

## 2. OpenClawService — New `executeCommand()` Method

### Purpose

A **stateless, single-shot** request to OpenClaw. Unlike `chat()`, this does NOT maintain conversation history. Each call is independent.

### Interface

```swift
/// Stateless single-shot request to OpenClaw.
/// Does not maintain chat history — each call is independent.
/// Uses OpenAI chat completions format (same as chatOpenAI).
func executeCommand(prompt: String) -> AsyncThrowingStream<SSEEvent, Error>
```

### Implementation Notes

- Use the **OpenAI format** (`/v1/chat/completions`), same as `chatOpenAI()`
- `messages` array contains ONLY the single user message — no history
- `model` field: `"openclaw:\(agentId)"` (same as chat)
- `stream: true` (same as chat)
- `user: "aipointer-autoverify"` (distinct from chat's `"aipointer"` for logging)
- **Do NOT append to `self.messages`** — this is fire-and-forget

### Implementation

```swift
func executeCommand(prompt: String) -> AsyncThrowingStream<SSEEvent, Error> {
    return AsyncThrowingStream { continuation in
        Task {
            guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30 // 30 second timeout

            // Single message, no history
            let messages: [[String: Any]] = [
                ["role": "user", "content": prompt]
            ]

            let body: [String: Any] = [
                "model": "openclaw:\(agentId)",
                "messages": messages,
                "stream": true,
                "user": "aipointer-autoverify"
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let session = URLSession(configuration: .default)

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: URLError(.badServerResponse))
                    return
                }

                if httpResponse.statusCode != 200 {
                    continuation.yield(.error("HTTP \(httpResponse.statusCode)"))
                    continuation.finish()
                    return
                }

                var fullResponse = ""

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let choice = choices.first,
                          let delta = choice["delta"] as? [String: Any],
                          let content = delta["content"] as? String else {
                        continue
                    }

                    fullResponse += content
                    continuation.yield(.delta(content))
                }

                // Do NOT store in self.messages
                continuation.yield(.done("openclaw"))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

---

## 3. CodeSourceMonitor — Rewrite

### What to remove

- `pollMail()` — Mail.app AppleScript polling
- `pollBrowserTabs()` — Chrome tab title + JS injection scanning
- `runAppleScript()` helper (no longer needed after removing the above)
- Fixed-interval polling timer

### What to keep

- `NotificationCenter` AX observer (zero-cost, catches SMS banners)
- `extractCode(from:)` regex engine (reuse for fallback parsing)
- `deliverCode()` dedup logic

### What to add

- `OpenClawCodeSource`: calls `OpenClawService.executeCommand()` with a structured prompt
- Exponential backoff retry: 3 attempts at 2s, 5s, 8s intervals

### The Prompt

This is the exact prompt to send to OpenClaw. **Do not modify this without consulting the OpenClaw side** — the response format is a contract between AIPointer and OpenClaw.

```
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
```

### Response Parsing

```swift
struct OTPResponse {
    let code: String?
    let from: String?
    let subject: String?
    let ageSeconds: Int?
    let reason: String?
}

func parseOTPResponse(_ text: String) -> OTPResponse {
    // Step 1: Try JSON parsing
    // The LLM response might contain markdown fences or extra text.
    // Extract JSON from the response first.
    let jsonPattern = "\\{[^{}]*\"code\"[^{}]*\\}"
    if let jsonRange = text.range(of: jsonPattern, options: .regularExpression),
       let data = String(text[jsonRange]).data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return OTPResponse(
            code: json["code"] as? String,
            from: json["from"] as? String,
            subject: json["subject"] as? String,
            ageSeconds: json["age_seconds"] as? Int,
            reason: json["reason"] as? String
        )
    }

    // Step 2: Fallback — regex extract any 4-8 digit code from raw text
    if let code = extractCode(from: text) {
        return OTPResponse(code: code, from: nil, subject: nil, ageSeconds: nil, reason: nil)
    }

    return OTPResponse(code: nil, from: nil, subject: nil, ageSeconds: nil, reason: "parse_error")
}
```

### Retry Strategy

```
Attempt 1: T+2s after OTP field detected
Attempt 2: T+7s (5s after attempt 1)
Attempt 3: T+15s (8s after attempt 2)
Give up after attempt 3.
```

Why these intervals:
- **2s initial delay**: Give the email a moment to arrive. If user just clicked "send code", the email needs transit time.
- **5s second interval**: Most verification emails arrive within 5-10 seconds.
- **8s third interval**: Last chance. If it hasn't arrived by T+15s, it's probably not an email-based code, or there's a delivery issue.

### Rewritten CodeSourceMonitor

```swift
import Cocoa
import ApplicationServices

/// Monitors verification code sources:
/// - Primary: OpenClaw API (reads email via IMAP/himalaya)
/// - Secondary: Notification Center (catches SMS/notification banners)
final class CodeSourceMonitor {
    var onCodeFound: ((String) -> Void)?

    /// Inject the shared OpenClawService instance.
    /// Set this before calling start().
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
        debugLog("[CodeSource] ✅ Delivering code from \(source): \(code)")
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

    // MARK: - Notification Center (secondary source, kept as-is)

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

    // MARK: - Code extraction (regex engine — unchanged from original)

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
```

---

## 4. VerificationService — Minor Changes

### Change: Retry timing

The current `CodeSourceMonitor` uses a fixed 4-second polling interval. The new version handles its own retry schedule internally (2s → 5s → 8s). So `VerificationService` no longer needs to manage polling.

### Change: Inject OpenClawService

`VerificationService` needs to pass the `OpenClawService` instance to `CodeSourceMonitor`.

```swift
// In VerificationService, add:
var openClawService: OpenClawService?

// In startMonitoring(), before codeSourceMonitor.start():
codeSourceMonitor.openClawService = openClawService
```

### Where to set it

In `AIPointerApp.swift` (or wherever `VerificationService` is instantiated), pass the shared `OpenClawService`:

```swift
verificationService.openClawService = openClawService
```

---

## 5. Integration Checklist

### AIPointer side (Claude Code does this):

- [ ] Add `executeCommand(prompt:)` to `OpenClawService.swift`
- [ ] Rewrite `CodeSourceMonitor.swift` per spec above
- [ ] Add `openClawService` property to `VerificationService.swift`
- [ ] Wire up `openClawService` in app initialization
- [ ] Verify `swift build` compiles cleanly
- [ ] Test with a mock/stub that OpenClaw API calls go out correctly

### OpenClaw side (Friday does this):

- [ ] Configure `himalaya` with Han's email account
- [ ] Test `himalaya envelope list` and `himalaya message read` work
- [ ] Verify OpenClaw responds correctly to the `[AUTO-VERIFY]` prompt format
- [ ] Confirm JSON response format matches the spec

### Han (manual testing):

- [ ] Trigger a real verification code email
- [ ] Focus on an OTP input field
- [ ] Verify the full pipeline: detect → fetch → display → fill

---

## 6. Edge Cases & Error Handling

| Scenario | Behavior |
|----------|----------|
| OpenClaw not running | `executeCommand` gets connection refused → log error, skip to next retry |
| OpenClaw returns non-JSON | Fallback regex extraction on raw text |
| himalaya not configured | OpenClaw will report error in response → `{"code":null,"reason":"himalaya not configured"}` |
| Email hasn't arrived yet | First 1-2 attempts return null, third attempt catches it |
| User types code manually | `VerificationService.checkFieldValue()` detects filled field → stops monitoring |
| Multiple codes in mailbox | Prompt says "most recent" — OpenClaw returns the newest one |
| Network timeout | 30-second URLRequest timeout → catch error → next retry |
| Code already used/expired | Not our problem — we deliver what we find, user decides |

---

## 7. Future Improvements (Not in scope now)

- **Manual trigger**: Add a keyboard shortcut (e.g., Fn+V) to force-trigger code fetch, bypassing OTP field detection
- **Code source priority**: If Notification Center finds a code before OpenClaw responds, cancel the OpenClaw request
- **Caching**: If OpenClaw found a code but user hasn't focused OTP field yet, cache it for 60 seconds
- **Multiple email accounts**: Support `--account` flag in himalaya for users with multiple mailboxes
- **Rate limiting**: Track API calls per minute to avoid overwhelming OpenClaw

---

_End of specification._
