import Foundation

/// Shared logger for onboarding diagnostics.
/// Writes to ~/aipointer_debug.log — retrievable via Settings > Debug > Copy Log.
enum OnboardingLog {
    static let logPath = NSHomeDirectory() + "/aipointer_debug.log"

    /// Append a timestamped line to the log file.
    static func log(_ category: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logPath) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    /// Read the full log contents.
    static func readAll() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    /// Clear the log file.
    static func clear() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// System info header — call once at launch.
    static func logSystemInfo() {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersionString
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

        log("System", "macOS \(version)")
        log("System", "App: \(bundleId) v\(appVersion) (\(buildNumber))")
        log("System", "Path: \(bundlePath)")
        log("System", "Home: \(NSHomeDirectory())")
        log("System", "Arch: \(info.machineArchitecture)")
        log("System", "Locale: \(Locale.current.identifier), Lang: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
    }
}

// Helper to get machine architecture
private extension ProcessInfo {
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
