import AppKit
import os.log

private let log = OSLog(subsystem: "AIPointer", category: "SelectionCapture")

struct SelectionContextCapture {
    struct CapturedContext: Equatable {
        var selectedText: String?
        var filePaths: [String]

        var isEmpty: Bool { selectedText == nil && filePaths.isEmpty }
    }

    /// Last known non-self frontmost app, used as fallback when AIPointer is already frontmost.
    private static var _previousFrontApp: NSRunningApplication?
    private static let selfPID = ProcessInfo.processInfo.processIdentifier

    /// Capture must be called with the frontmost app snapshotted *before* any state change.
    static func capture(frontApp: NSRunningApplication?, completion: @escaping (CapturedContext) -> Void) {
        let effectiveApp: NSRunningApplication?
        if frontApp?.processIdentifier == selfPID {
            effectiveApp = _previousFrontApp
            os_log("[SelectionCapture] frontApp is self (pid %d), fallback to previous: %{public}@ (pid %d)",
                   log: log, selfPID,
                   _previousFrontApp?.bundleIdentifier ?? "nil",
                   _previousFrontApp?.processIdentifier ?? 0)
        } else {
            effectiveApp = frontApp
            _previousFrontApp = frontApp
            os_log("[SelectionCapture] frontApp: %{public}@ (pid %d)",
                   log: log, frontApp?.bundleIdentifier ?? "nil",
                   frontApp?.processIdentifier ?? 0)
        }
        let pid = effectiveApp?.processIdentifier ?? 0
        let bundleID = effectiveApp?.bundleIdentifier ?? ""
        let isFinder = bundleID == "com.apple.finder"

        os_log("[SelectionCapture] effectiveApp: %{public}@ isFinder=%d", log: log, bundleID, isFinder ? 1 : 0)

        DispatchQueue.global(qos: .userInitiated).async {
            let selectedText = readSelectedText(pid: pid)
            let finderPaths: [String] = isFinder ? readFinderSelection() : []
            if isFinder {
                os_log("[SelectionCapture] Finder paths: %d", log: log, finderPaths.count)
            }

            let context = CapturedContext(
                selectedText: selectedText,
                filePaths: finderPaths
            )
            DispatchQueue.main.async {
                completion(context)
            }
        }
    }

    // MARK: - AX Selected Text

    private static func readSelectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focusedRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else {
            return nil
        }
        let element = focused as! AXUIElement
        var textRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRaw) == .success,
              let text = textRaw as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Truncate to 500 characters
        if trimmed.count > 500 {
            return String(trimmed.prefix(500)) + "…"
        }
        return trimmed
    }

    // MARK: - Finder Selection

    private static func readFinderSelection() -> [String] {
        let script = """
        tell application "Finder"
            set sel to selection
            set out to ""
            repeat with f in sel
                set out to out & POSIX path of (f as alias) & "\n"
            end repeat
            return out
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            os_log("[SelectionCapture] osascript launch error: %{public}@", log: log, error.localizedDescription)
            return []
        }

        guard task.terminationStatus == 0 else {
            os_log("[SelectionCapture] osascript exit code: %d", log: log, task.terminationStatus)
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let paths = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(paths.prefix(10))
    }
}
