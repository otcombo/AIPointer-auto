import Cocoa
import ApplicationServices

/// Hides the system cursor even when this app is not the active/frontmost application.
///
/// Uses the private `CGSSetConnectionProperty("SetsCursorInBackground")` API to unlock
/// `CGDisplayHideCursor` for background/accessory apps. This is the approach used by
/// Pixel Picker, CursorHide, Cursorcerer, and other cursor-replacement apps.
///
/// A periodic timer re-hides the cursor because the system re-shows it whenever
/// the cursor style changes (e.g. hovering over text shows the I-beam).
class CursorHider {
    private var isHidden = false
    private var hideTimer: Timer?
    private var hideCount = 0  // Track how many times we called CGDisplayHideCursor

    private typealias CGSDefaultConnectionFunc = @convention(c) () -> CInt
    private typealias CGSSetConnectionPropertyFunc = @convention(c) (CInt, CInt, CFString, CFTypeRef) -> CGError

    private var defaultConnectionFunc: CGSDefaultConnectionFunc?
    private var setConnectionPropertyFunc: CGSSetConnectionPropertyFunc?

    init() {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }

        if let sym = dlsym(handle, "_CGSDefaultConnection") {
            defaultConnectionFunc = unsafeBitCast(sym, to: CGSDefaultConnectionFunc.self)
        }
        if let sym = dlsym(handle, "CGSSetConnectionProperty") {
            setConnectionPropertyFunc = unsafeBitCast(sym, to: CGSSetConnectionPropertyFunc.self)
        }

        enableBackgroundCursorControl()
    }

    private func enableBackgroundCursorControl() {
        if let getConn = defaultConnectionFunc,
           let setProp = setConnectionPropertyFunc {
            let cid = getConn()
            let _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
    }

    /// Hide the cursor and keep it hidden with a periodic timer.
    /// The system re-shows the cursor on style changes (e.g. I-beam over text),
    /// so we must continuously re-hide it.
    func hide() {
        guard !isHidden else { return }
        isHidden = true
        hideCount = 1
        CGDisplayHideCursor(CGMainDisplayID())

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isHidden else { return }
            CGDisplayHideCursor(CGMainDisplayID())
            self.hideCount += 1
        }
    }

    /// Show the system cursor and stop the hide timer.
    func restore() {
        guard isHidden else { return }
        isHidden = false
        hideTimer?.invalidate()
        hideTimer = nil

        // CGDisplayHideCursor/ShowCursor uses a counter.
        // We must call ShowCursor the same number of times as HideCursor to balance it.
        let display = CGMainDisplayID()
        for _ in 0..<hideCount {
            CGDisplayShowCursor(display)
        }
        hideCount = 0
    }
}
