import Cocoa

enum ScreenRecordingPermission {
    /// Check if Screen Recording permission is granted by attempting a 1x1 capture.
    static func isGranted() -> Bool {
        let image = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            []
        )
        return image != nil
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show an alert prompting the user to grant Screen Recording permission.
    @MainActor
    static func promptIfNeeded() -> Bool {
        if isGranted() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Required"
        alert.informativeText = "AI Pointer needs Screen Recording permission to capture screenshots.\n\nPlease grant access in System Settings → Privacy & Security → Screen Recording, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSettings()
        }
        return false
    }
}
