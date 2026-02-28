# AIPointer

macOS menu-bar AI assistant that replaces the system cursor with a teardrop NSPanel. Press Fn to chat with AI; long-press Fn to screenshot. Zero third-party dependencies.

**Stack**: Swift 6.2 (language mode v5) · SPM · macOS 26+ · SwiftUI + AppKit hybrid

## Development

```bash
swift build                    # build
swift run AIPointer            # run from terminal (needs Input Monitoring permission)
swift build -c release         # release build
```

Build output: `.build/debug/AIPointer` or `.build/release/AIPointer`.

Config file: `~/.openclaw/openclaw.json` (backend URL, API keys). Read by `OpenClawService`.

## Architecture

### State Machine — the single source of truth

All UI is driven by `PointerState` enum in `State/PointerState.swift`:

```
idle → input → thinking → responding(text) → response(text)
     → monitoring → codeReady(code)        # OTP flow
     → suggestion(observation, suggestion?) # behavior sensing
```

Use `isExpanded` (panel mode) and `isFixed` (stops following mouse) computed properties when branching on state groups. Never match individual cases when a computed property exists.

### Hub-and-Spoke wiring

`AppDelegate.startPointerSystem()` is the single wiring point. All components connect via typed closures (`onFnShortPress`, `onMouseMoved`, `onStateChanged`, etc.) — no Combine, no NotificationCenter.

When adding a new component: instantiate it in `AppDelegate`, wire its closures in `startPointerSystem()`, and store a strong reference.

### Key components

| Layer | Component | Role |
|-------|-----------|------|
| Core | `EventTapManager` | CGEvent tap (headInsert) — mouse, keyboard, Fn |
| Core | `OverlayPanel` | `.screenSaver`-level NSPanel, click-through when idle |
| Core | `CursorHider` | Hides system cursor via `CGDisplayHideCursor` |
| ViewModel | `PointerViewModel` | State machine owner, AI communication |
| Service | `OpenClawService` | Dual-backend SSE client (OpenClaw + Anthropic) |
| Service | `VerificationService` | OTP detection → auto-fill pipeline |
| Service | `BehaviorSensingService` | Behavior scoring (2s) + focus detection (30s) |
| View | `PointerRootView` | Top-level `switch` on `PointerState` |

### Fn/Emoji four-layer defense

macOS Fn/Globe triggers the emoji picker. Four layers suppress it — preserve all four when modifying Fn handling:

1. **CGEvent tap** — intercept `flagsChanged` + synthesized keyboard events
2. **OverlayPanel.flagsChanged** — window-level swallow
3. **Custom NSTextFieldCell FieldEditor** — editor-level intercept (`AppKitTextField`)
4. **Method swizzle** — `NSApplication.orderFrontCharacterPalette` noop as last resort

### Dual AI backend

| Input | Backend | Protocol |
|-------|---------|----------|
| Text only | OpenClaw gateway | OpenAI-compatible SSE `/v1/chat/completions` |
| With image | Anthropic Messages API | Anthropic SSE `/v1/messages` |

Images are auto-compressed to ≤300KB, dimensions clamped to 200–1568px.

## Coding Rules

### Thread safety

Mark all UI-touching classes `@MainActor`. WHY: SwiftUI observation and AppKit window APIs require main thread.

Run `AXUIElement` calls on a dedicated serial queue (see `BehaviorMonitor.axQueue`). WHY: AX calls can block; blocking main thread deadlocks the event tap.

Never use `DispatchQueue.main.sync` from the main actor — it deadlocks. Use `await MainActor.run {}` or direct calls instead.

### Closures over Combine

Use typed closure properties for inter-component communication. WHY: Hub-and-Spoke is the established pattern; mixing in Combine or NotificationCenter fragments the data flow.

### State transitions

Transition state only inside `PointerViewModel`. Views read state; they never write it.

When adding a new state case, update: (1) `PointerState` enum + computed properties, (2) `PointerRootView` switch, (3) `OverlayPanel` sizing/interaction logic.

### UserDefaults

Read booleans with `UserDefaults.standard.bool(forKey:)` — it returns `false` for missing keys. If your boolean's *default* should be `true`, register it in `Defaults` or use `object(forKey:) == nil` to distinguish "unset" from "false".

### SwiftUI + AppKit boundary

`OverlayPanel` hosts SwiftUI via `NSHostingView`. Pass data through `PointerViewModel` (observed by SwiftUI), not through AppKit responder chain.

Keep NSPanel configuration (level, collection behavior, ignoresMouseEvents) in `OverlayPanel.swift`. Keep visual layout in SwiftUI views.

### i18n

Use `Defaults.L.key` for user-facing strings. Inline localization via system language detection — no `.strings` files.

### Style

- No third-party dependencies. Use system frameworks only.
- Prefer `async/await` for new asynchronous code. The project uses Swift language mode v5 but targets Swift 6.2 toolchain.
- Keep files focused: one primary type per file.

## Modification Guide

### Add a new PointerState case
1. Add case to `PointerState` enum
2. Update `isExpanded`, `isFixed`, and any other computed properties
3. Add view branch in `PointerRootView`
4. Add panel sizing in `OverlayPanel` if the new state has unique dimensions
5. Add transition logic in `PointerViewModel`

### Add a new service
1. Create service class in `Services/`
2. Instantiate in `AppDelegate`
3. Wire closures in `startPointerSystem()`
4. Store strong reference in `AppDelegate` property

### Add an onboarding step
Onboarding has **5 steps** (fnKey → autoVerify → smartSuggest → permissions → openclawSetup). Steps are defined in `OnboardingView.Step` enum. To add a step: add a case, implement its view section, and update the step dot indicators.

### Add a new event handler
1. Add closure property to `EventTapManager` (e.g., `var onNewEvent: ((SomeType) -> Void)?`)
2. Call it from the CGEvent callback
3. Wire it in `AppDelegate.startPointerSystem()`

### Change AI communication
Modify `OpenClawService`. Text-only goes through OpenClaw gateway; image-attached goes through Anthropic direct. Both return `AsyncThrowingStream<SSEEvent>`. Keep the stream contract: `.delta` for incremental text, `.done` for completion.
