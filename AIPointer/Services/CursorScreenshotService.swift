import Cocoa
import ScreenCaptureKit

/// Captures a small screenshot around the current mouse position.
/// Used to provide visual context to the AI on every Fn press.
enum CursorScreenshotService {
    /// Capture a region around the mouse cursor.
    /// - Parameters:
    ///   - width: The logical pixel width of the capture region (default 150).
    ///   - height: The logical pixel height of the capture region (default 50).
    /// - Returns: An NSImage of the captured region, or nil if capture fails.
    static func capture(width: CGFloat = 150, height: CGFloat = 50) async -> NSImage? {
        // Check Screen Recording permission silently (no prompt)
        guard await ScreenRecordingPermission.isGranted() else { return nil }

        // Get mouse position in Quartz coordinates (origin top-left)
        let mouseAppKit = NSEvent.mouseLocation
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainHeight = mainScreen.frame.height
        let mouseQuartz = CGPoint(x: mouseAppKit.x, y: mainHeight - mouseAppKit.y)

        // Build capture rect centered on mouse
        let captureRect = CGRect(
            x: mouseQuartz.x - width / 2,
            y: mouseQuartz.y - height / 2,
            width: width,
            height: height
        )

        // Find which display the mouse is on
        let displays: [SCDisplay]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
        } catch {
            return nil
        }

        // Match display by mouse position
        guard let display = displays.first(where: { display in
            let frame = display.frame
            return frame.contains(mouseQuartz)
        }) ?? displays.first else { return nil }

        // Convert to display-local coordinates
        let displayOrigin = CGPoint(x: CGFloat(display.frame.origin.x),
                                     y: CGFloat(display.frame.origin.y))
        let localRect = CGRect(x: captureRect.origin.x - displayOrigin.x,
                                y: captureRect.origin.y - displayOrigin.y,
                                width: captureRect.width,
                                height: captureRect.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = Int(width)
        config.height = Int(height)
        config.showsCursor = false
        config.captureResolution = .best

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
