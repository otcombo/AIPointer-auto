# Auto Verification Code Detection — Implementation Notes

## Goal

User focuses on an OTP input field in Chrome → system automatically finds the verification code from Gmail → cursor shows digits → click to fill.

## Current Architecture

```
AccessibilityMonitor (AX API)
  → detects focused element changes
  → passes to OTPFieldDetector

OTPFieldDetector
  → analyzes AX attributes (placeholder, id, autocomplete, label...)
  → returns confidence tier (tier1/tier2/tier3/none)

VerificationService (orchestrator)
  → on tier1-3: enters .monitoring state (green dot), starts CodeSourceMonitor
  → on code found: enters .codeReady state (cursor shows digits)
  → on click: fills code into the OTP field

CodeSourceMonitor (code source scanner)
  → polls Mail.app via AppleScript (reads unread emails from last 5 min)
  → polls Chrome tabs via AppleScript (reads tab titles + JS content extraction)
  → monitors Notification Center via AX observer (SMS banners)
  → extracts codes via multilingual regex engine
```

## What Works

- OTP field detection: `placeholder="Enter verification code"` → `confidence=tier2`
- Polling detects focus changes within Chrome (AX polling fallback for Chrome)
- Green dot appears/disappears based on OTP field focus
- Unified poll timer runs Mail.app + browser scan in parallel every 4 seconds
- Duplicate code prevention (`lastFoundCode`)
- Debug logging throughout (`~/AIPointer-debug.log`, prefix `[CodeSource]`)

## What Doesn't Work: Code Source Scanning

### Mail.app Polling
- Works in principle, but user doesn't use Mail.app for receiving codes
- Returns empty every poll cycle

### Browser Tab Scanning (AppleScript approach)
- **Phase 1 (tab titles)**: Works — successfully reads `TAB:Inbox (1) - otcombo@gmail.com - Gmail`
- **Phase 2 (JS content extraction)**: Fails — Chrome requires user to manually enable "View → Developer → Allow JavaScript from Apple Events"
- Even if JS is enabled, Gmail's DOM selectors (`.zE .y2`, `.a3s`) are fragile and may break with Gmail updates
- Tab titles alone don't contain verification codes (Gmail shows "Inbox (1)" not the email subject)

### Notification Center
- Registered, but only catches SMS/notification banners — not useful for email-based codes

## The Missing Piece: OpenClaw

OpenClaw is a local AI agent running at `localhost:18789` with an OpenAI-compatible chat API. It has a **Browser Relay** Chrome extension that, when connected, gives the agent direct access to read browser tab content.

### Why OpenClaw is the Right Approach

| | AppleScript + JS Injection | OpenClaw Browser Relay |
|---|---|---|
| Requires manual Chrome setting | Yes ("Allow JS from Apple Events") | No (just install extension) |
| DOM selector stability | Fragile (Gmail can change anytime) | Agent reads content semantically |
| Code extraction | Regex only | AI can understand context |
| Multi-provider support | Need selectors per provider | Agent handles any email UI |
| Background tab access | Limited | Full access via extension |

### Proposed Flow with OpenClaw

```
CodeSourceMonitor detects .monitoring state
  → sends request to OpenClaw: "Read my email tabs in Chrome, find any verification code received in the last few minutes, return only the digit code"
  → OpenClaw uses Browser Relay to read Gmail tab content
  → OpenClaw returns the code (e.g. "482937")
  → CodeSourceMonitor delivers code → cursor shows digits
```

### Current Blocker

OpenClaw's Browser Relay extension is not connected in Chrome. Need to:
1. Confirm the extension is installed
2. Click the extension icon to activate it (badge shows "ON")
3. Then OpenClaw can read tab content

## Files Modified

- `AIPointer/Services/CodeSourceMonitor.swift` — all scanning logic lives here
- `AIPointer/Services/OpenClawService.swift` — existing OpenClaw API client (chat completions)
- `AIPointer/Services/VerificationService.swift` — orchestrator, calls CodeSourceMonitor
- `AIPointer/Services/AccessibilityMonitor.swift` — focus detection, `debugLog` function
- `AIPointer/Services/OTPFieldDetector.swift` — OTP field confidence scoring

## Open Questions

1. Should CodeSourceMonitor call OpenClaw directly, or go through VerificationService?
2. Polling interval — is 4 seconds appropriate for OpenClaw requests (they involve an LLM call)?
3. Should we keep AppleScript tab-title scanning as a fallback when OpenClaw is unavailable?
4. How to handle OpenClaw response latency vs. user expectation of instant code appearance?
5. Cost/rate-limit considerations for sending repeated LLM requests every few seconds?
