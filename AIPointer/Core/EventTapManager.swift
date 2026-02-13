import Cocoa
import CoreGraphics

class EventTapManager {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onFnShortPress: (() -> Void)?   // fn 松开时触发（短按）
    var onFnLongPress: (() -> Void)?    // 长按超过阈值时触发

    /// When true, fn key events are consumed and won't trigger the system emoji picker.
    var suppressFnKey = true

    /// 长按触发截图的阈值（秒）
    var longPressThreshold: TimeInterval = 0.4

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var previousFnState = false
    private var fnLongPressTriggered = false
    private var fnPressWorkItem: DispatchWorkItem?
    private var tapHealthTimer: Timer?
    private var lastFnEventTime: UInt64 = 0  // mach_absolute_time of last fn flagsChanged

    private static var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func checkPermission() -> Bool {
        return CGPreflightListenEventAccess()
    }

    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    func start() {
        guard eventTap == nil else { return }

        // Event mask: mouse tracking + keyboard + system-defined + all other types.
        // We use ~0 (all types) because the fn/Globe emoji trigger uses synthetic
        // keyDown/keyUp (type 10/11) and system-defined (type 14) events that bypass
        // the normal flagsChanged path. Only by intercepting ALL event types can we
        // reliably suppress the emoji picker.
        let eventMask: CGEventMask = ~0

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            print("[EventTapManager] Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Periodically ensure the tap stays enabled (system can disable it)
        tapHealthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    func stop() {
        tapHealthTimer?.invalidate()
        tapHealthTimer = nil
        fnPressWorkItem?.cancel()
        fnPressWorkItem = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Milliseconds elapsed since last fn event.
    private func msSinceLastFn() -> UInt64 {
        guard lastFnEventTime > 0 else { return UInt64.max }
        let elapsed = mach_absolute_time() - lastFnEventTime
        let info = Self.timebaseInfo
        return (elapsed * UInt64(info.numer) / UInt64(info.denom)) / 1_000_000
    }

    /// Returns true if the event should be suppressed (swallowed).
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        let rawType = type.rawValue

        // --- Mouse events: track cursor position, never suppress ---
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let location = event.location
            if let primaryScreen = NSScreen.screens.first {
                let flipped = NSPoint(
                    x: location.x,
                    y: primaryScreen.frame.height - location.y
                )
                onMouseMoved?(flipped)
            }
            return false

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            return false

        // --- fn key flagsChanged: core detection + suppress ---
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 63 { // fn/Globe key
                lastFnEventTime = mach_absolute_time()
                let fnDown = event.flags.contains(.maskSecondaryFn)
                if fnDown && !previousFnState {
                    // fn pressed down
                    fnPressWorkItem?.cancel()
                    fnLongPressTriggered = false

                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self, self.previousFnState else { return }
                        self.fnLongPressTriggered = true
                        self.onFnLongPress?()
                    }
                    fnPressWorkItem = workItem
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + longPressThreshold,
                        execute: workItem
                    )
                } else if !fnDown && previousFnState {
                    // fn released
                    fnPressWorkItem?.cancel()
                    fnPressWorkItem = nil
                    if !fnLongPressTriggered {
                        // Short press — trigger on release
                        onFnShortPress?()
                    }
                    fnLongPressTriggered = false
                }
                previousFnState = fnDown
                return suppressFnKey
            }
            return false

        case .tapDisabledByTimeout:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false

        default:
            // --- Suppress synthetic keyboard & system events near fn press ---
            // When fn/Globe is pressed, macOS generates:
            //   1. flagsChanged (keyCode 63) — handled above
            //   2. Synthetic keyDown (10) + keyUp (11) on fn release — triggers emoji picker
            //   3. NX_SYSDEFINED (14) — system-level fn action event
            // We suppress types 10, 11, 14 within 300ms of fn press.
            // Type 29 (gesture/trackpad) is NOT suppressed to avoid freezing trackpad.
            guard suppressFnKey else { return false }

            let isKeyboardOrSystem = rawType == 10 || rawType == 11 || rawType == 14
            if isKeyboardOrSystem && msSinceLastFn() < 300 {
                return true
            }

            return false
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()

    let shouldSuppress = manager.handleEvent(type: type, event: event)
    if shouldSuppress {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
