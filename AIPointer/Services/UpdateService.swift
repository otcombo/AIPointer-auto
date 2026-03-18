import Foundation
import AppKit

/// Self-update via GitHub Releases.
/// Checks `GET /repos/{owner}/{repo}/releases/latest`, compares semver,
/// downloads .zip asset, replaces the running .app, and relaunches.
@MainActor
final class UpdateService {

    // MARK: - Configuration

    private let owner = "otcombo"
    private let repo = "AIPointer-auto"
    private let assetName = "AIPointer.zip" // expected asset filename in the release

    // MARK: - State

    enum State: Equatable {
        case idle
        case checking
        case available(version: String, url: URL)
        case downloading(progress: Double)
        case readyToInstall(version: String, zipURL: URL)
        case installing
        case error(String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// Called on every state change (always on MainActor).
    var onStateChanged: ((State) -> Void)?

    // MARK: - Check (daily-gated)

    /// Check for updates, but at most once per calendar day.
    func checkIfNeeded() {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: "updateLastCheckDate") as? Date ?? .distantPast
        if Calendar.current.isDateInToday(lastCheck) {
            log(" Already checked today, skipping")
            return
        }
        check()
    }

    /// Force check regardless of daily gate.
    func check() {
        guard state != .checking else { return }
        state = .checking
        log(" Checking for updates…")

        Task {
            do {
                let release = try await fetchLatestRelease()
                UserDefaults.standard.set(Date(), forKey: "updateLastCheckDate")

                guard let remoteVersion = release.tagName.stripLeadingV,
                      let currentVersion = currentAppVersion,
                      remoteVersion.isNewerThan(currentVersion) else {
                    log(" Up to date (remote: \(release.tagName), current: \(currentAppVersion ?? "?"))")
                    state = .idle
                    return
                }

                guard let asset = release.assets.first(where: { $0.name == assetName }),
                      let downloadURL = URL(string: asset.browserDownloadURL) else {
                    log(" No matching asset '\(assetName)' in release")
                    state = .idle
                    return
                }

                let version = remoteVersion
                log(" New version available: \(version)")
                state = .available(version: version, url: downloadURL)
            } catch {
                log(" Check failed: \(error)")
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Download & Install

    func downloadAndInstall() {
        guard case .available(let version, let url) = state else { return }
        state = .downloading(progress: 0)

        Task {
            do {
                let zipURL = try await download(url: url)
                state = .readyToInstall(version: version, zipURL: zipURL)
                let newAppURL = try extractApp(zipURL: zipURL)
                try launchInstallerAndQuit(newAppURL: newAppURL)
            } catch {
                log(" Install failed: \(error)")
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.apiError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Download

    private func download(url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        // Move to a stable temp path (URLSession temp files get cleaned up)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("AIPointer-update.zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        log(" Downloaded to \(dest.path)")
        state = .downloading(progress: 1.0)
        return dest
    }

    // MARK: - Extract

    /// Extract the zip and return the path to the .app inside.
    private func extractApp(zipURL: URL) throws -> URL {
        state = .installing

        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent("AIPointer-extract")
        try? fm.removeItem(at: extractDir)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Extract using ditto (preserves code signatures, resource forks)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipURL.path, extractDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError.extractFailed
        }

        // Clean up zip
        try? fm.removeItem(at: zipURL)

        // Find the .app inside extracted directory
        let contents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppFound
        }

        log(" Extracted to \(newApp.path)")
        return newApp
    }

    // MARK: - Launch installer script & quit

    /// Spawn a shell script that waits for this process to exit, then replaces
    /// the .app bundle and relaunches. This avoids replacing a running binary.
    private func launchInstallerAndQuit(newAppURL: URL) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw UpdateError.notRunningAsApp
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        # Wait for the current process to exit
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        # Replace the .app bundle
        rm -rf "\(currentApp.path)"
        mv "\(newAppURL.path)" "\(currentApp.path)"
        # Clean up extract directory
        rm -rf "\(newAppURL.deletingLastPathComponent().path)"
        # Relaunch
        open "\(currentApp.path)"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try task.run()

        log(" Installer script launched, quitting…")

        // Quit the app so the script can replace it
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func log(_ msg: String) {
        #if DEBUG
        print(msg)
        #endif
    }

    private var currentAppVersion: String? {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return v
        }
        // Walk up from executable to find enclosing .app bundle
        let execURL = Bundle.main.executableURL ?? Bundle.main.bundleURL
        var url = execURL
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app",
               let bundle = Bundle(url: url),
               let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                return v
            }
        }
        return nil
    }

    enum UpdateError: LocalizedError {
        case invalidURL
        case apiError(String)
        case downloadFailed
        case extractFailed
        case noAppFound
        case notRunningAsApp
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API URL"
            case .apiError(let s): return "GitHub API: \(s)"
            case .downloadFailed: return "Download failed"
            case .extractFailed: return "Failed to extract update"
            case .noAppFound: return "No .app found in update archive"
            case .notRunningAsApp: return "Not running from a .app bundle"
            case .replaceFailed(let s): return "Failed to replace app: \(s)"
            }
        }
    }
}

// MARK: - Semver comparison

private extension String {
    /// Strip leading "v" or "V" from a tag like "v1.2.3"
    var stripLeadingV: String? {
        let s = self.hasPrefix("v") || self.hasPrefix("V") ? String(self.dropFirst()) : self
        // Validate it looks like semver
        let parts = s.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return s
    }

    /// True if self (e.g. "1.1.0") is newer than other (e.g. "1.0.0")
    func isNewerThan(_ other: String) -> Bool {
        let lhs = self.split(separator: ".").compactMap { Int($0) }
        let rhs = other.split(separator: ".").compactMap { Int($0) }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return false
    }
}
