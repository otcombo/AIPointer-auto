import Cocoa
import ApplicationServices

/// Hides the system cursor even when this app is not the active/frontmost application.
///
/// Uses the private `CGSSetConnectionProperty("SetsCursorInBackground")` API to unlock
/// `CGDisplayHideCursor` for background/accessory apps. This is the approach used by
/// Pixel Picker, CursorHide, Cursorcerer, and other cursor-replacement apps.
class CursorHider {
    private var isHidden = false

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
    }

    /// Enable background cursor control, then hide the cursor.
    func hide() {
        guard !isHidden else { return }
        isHidden = true

        // Allow this (non-frontmost) process to control the cursor
        if let getConn = defaultConnectionFunc,
           let setProp = setConnectionPropertyFunc {
            let cid = getConn()
            let _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }

        CGDisplayHideCursor(CGMainDisplayID())
    }

    func restore() {
        guard isHidden else { return }
        isHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
