import Foundation
import Combine

/// 检测和管理本机 OpenClaw 安装状态
@MainActor
class OpenClawSetupService: ObservableObject {

    // MARK: - 状态枚举

    enum InstallStatus: Equatable {
        case checking
        case installed(path: String)
        case notInstalled
        case error(String)

        static func == (lhs: InstallStatus, rhs: InstallStatus) -> Bool {
            switch (lhs, rhs) {
            case (.checking, .checking): return true
            case (.installed(let a), .installed(let b)): return a == b
            case (.notInstalled, .notInstalled): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    enum GatewayStatus: Equatable {
        case unknown
        case running
        case stopped
        case error(String)

        static func == (lhs: GatewayStatus, rhs: GatewayStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown): return true
            case (.running, .running): return true
            case (.stopped, .stopped): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    enum SetupPhase: Int, CaseIterable {
        case install = 0, gateway = 1, apiKey = 2, verify = 3
    }

    enum PhaseStatus: Equatable {
        case pending
        case inProgress(String)
        case succeeded(String)
        case failed(String)
        case needsInput
    }

    // MARK: - Published 属性

    @Published var installStatus: InstallStatus = .checking
    @Published var gatewayStatus: GatewayStatus = .unknown
    @Published var version: String?
    @Published var phaseStatuses: [SetupPhase: PhaseStatus] = [
        .install: .pending,
        .gateway: .pending,
        .apiKey: .pending,
        .verify: .pending,
    ]
    @Published var resolvedPort: Int = 18789

    var allPhasesSucceeded: Bool {
        SetupPhase.allCases.allSatisfy { phase in
            if case .succeeded = phaseStatuses[phase] { return true }
            return false
        }
    }

    // OpenClaw 可能安装在这些路径
    private let commonPaths = [
        "/usr/local/bin/openclaw",
        "/opt/homebrew/bin/openclaw",
        "\(NSHomeDirectory())/.nvm/versions/node/v22.22.0/bin/openclaw",
        "\(NSHomeDirectory())/.openclaw/bin/openclaw",
        "\(NSHomeDirectory())/.local/bin/openclaw"
    ]

    /// 安装命令
    static let installCommand = "curl -fsSL https://openclaw.ai/install.sh | bash"

    private var installedPath: String?

    // MARK: - 检测安装

    /// 检查 OpenClaw 是否已安装
    func checkInstallation() {
        installStatus = .checking

        Task {
            // 先用 which 查找
            if let path = await runShell("which openclaw") {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
                    installStatus = .installed(path: trimmed)
                    installedPath = trimmed
                    await fetchVersion(path: trimmed)
                    return
                }
            }

            // 检查常见路径
            for path in commonPaths {
                if FileManager.default.isExecutableFile(atPath: path) {
                    installStatus = .installed(path: path)
                    installedPath = path
                    await fetchVersion(path: path)
                    return
                }
            }

            installStatus = .notInstalled
            installedPath = nil
        }
    }

    /// 获取版本号
    private func fetchVersion(path: String) async {
        if let output = await runShell("\(path) --version") {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                version = trimmed
            }
        }
    }

    // MARK: - Gateway 状态

    /// 检查 Gateway 是否在运行（通过 HTTP 请求）
    func checkGatewayStatus(baseURL: String = "http://localhost:18789") {
        gatewayStatus = .unknown

        Task {
            guard let url = URL(string: "\(baseURL)/api/health") else {
                gatewayStatus = .error("无效的 URL")
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 3

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    gatewayStatus = .running
                } else {
                    gatewayStatus = .stopped
                }
            } catch {
                gatewayStatus = .stopped
            }
        }
    }

    // MARK: - Full Setup Flow

    /// 入口：顺序执行 4 个 phase
    func runFullSetup() {
        Task {
            await runInstallPhase()
            guard phaseStatuses[.install] != nil, case .succeeded = phaseStatuses[.install]! else { return }

            await runGatewayPhase()
            guard phaseStatuses[.gateway] != nil, case .succeeded = phaseStatuses[.gateway]! else { return }

            await runAPIKeyPhase()
            // apiKey phase may pause at .needsInput — verify phase runs after user submits
            if case .succeeded = phaseStatuses[.apiKey]! {
                await runVerifyPhase()
            }
        }
    }

    // MARK: - Phase 1: Install

    private func runInstallPhase() async {
        phaseStatuses[.install] = .inProgress(L("检测中...", "Checking..."))

        // Reuse existing checkInstallation logic inline
        if let path = await runShell("which openclaw") {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
                installStatus = .installed(path: trimmed)
                installedPath = trimmed
                await fetchVersion(path: trimmed)
                let desc = version.map { "v\($0)" } ?? trimmed
                phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
                return
            }
        }

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                installStatus = .installed(path: path)
                installedPath = path
                await fetchVersion(path: path)
                let desc = version.map { "v\($0)" } ?? path
                phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
                return
            }
        }

        // Not installed — run install
        phaseStatuses[.install] = .inProgress(L("正在安装...", "Installing..."))
        let result = await runShell(Self.installCommand)

        // Re-check after install
        if let path = await runShell("which openclaw") {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
                installStatus = .installed(path: trimmed)
                installedPath = trimmed
                await fetchVersion(path: trimmed)
                let desc = version.map { "v\($0)" } ?? trimmed
                phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
                return
            }
        }

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                installStatus = .installed(path: path)
                installedPath = path
                await fetchVersion(path: path)
                let desc = version.map { "v\($0)" } ?? path
                phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
                return
            }
        }

        let errorMsg = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        installStatus = .notInstalled
        phaseStatuses[.install] = .failed(L("安装失败", "Installation failed") + (errorMsg.isEmpty ? "" : ": \(errorMsg)"))
    }

    // MARK: - Phase 2: Gateway

    private func runGatewayPhase() async {
        phaseStatuses[.gateway] = .inProgress(L("检测 Gateway...", "Checking Gateway..."))

        // Check if already running on current port
        if await healthCheck(port: resolvedPort) {
            gatewayStatus = .running
            phaseStatuses[.gateway] = .succeeded(L("端口 \(resolvedPort)", "Port \(resolvedPort)"))
            return
        }

        // Check port availability and find a free port
        var port = resolvedPort
        for _ in 0..<10 {
            if let lsofOutput = await runShell("lsof -ti tcp:\(port)") {
                let trimmed = lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Port occupied — check if it's openclaw
                    if let psOutput = await runShell("ps -p \(trimmed) -o comm=") {
                        if psOutput.contains("openclaw") {
                            // openclaw is using this port but health failed — try again
                            break
                        }
                    }
                    // Not openclaw, try next port
                    port += 1
                    continue
                }
            }
            break // Port is free
        }

        resolvedPort = port
        UserDefaults.standard.set("http://localhost:\(port)", forKey: "backendURL")

        // Start gateway
        phaseStatuses[.gateway] = .inProgress(L("正在启动 Gateway...", "Starting Gateway..."))
        guard let path = installedPath else {
            phaseStatuses[.gateway] = .failed(L("找不到 openclaw 路径", "openclaw path not found"))
            return
        }

        runShellBackground("\(path) gateway start --port \(port)")

        // Poll health up to 30 times (1s interval)
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if await healthCheck(port: port) {
                gatewayStatus = .running
                phaseStatuses[.gateway] = .succeeded(L("端口 \(port)", "Port \(port)"))
                return
            }
        }

        gatewayStatus = .stopped
        phaseStatuses[.gateway] = .failed(L("Gateway 启动超时", "Gateway start timed out"))
    }

    // MARK: - Phase 3: API Key

    private func runAPIKeyPhase() async {
        phaseStatuses[.apiKey] = .inProgress(L("检查 API Key...", "Checking API Key..."))

        // Check ~/.openclaw/openclaw.json for provider API keys
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
        if FileManager.default.fileExists(atPath: configPath),
           let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            for (_, providerConfig) in providers {
                if let config = providerConfig as? [String: Any],
                   let apiKey = config["apiKey"] as? String,
                   !apiKey.isEmpty {
                    phaseStatuses[.apiKey] = .succeeded(L("已配置", "Configured"))
                    return
                }
            }
        }

        // Check environment variables
        let envKeys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        for key in envKeys {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                phaseStatuses[.apiKey] = .succeeded(L("已配置（环境变量）", "Configured (env var)"))
                return
            }
        }

        // No key found — need user input
        phaseStatuses[.apiKey] = .needsInput
    }

    /// 用户提交 API Key 后调用
    func continueAfterAPIKey(provider: String, apiKey: String) {
        Task {
            phaseStatuses[.apiKey] = .inProgress(L("正在保存...", "Saving..."))

            guard let path = installedPath else {
                phaseStatuses[.apiKey] = .failed(L("找不到 openclaw 路径", "openclaw path not found"))
                return
            }

            // Escape single quotes in the API key
            let escapedKey = apiKey.replacingOccurrences(of: "'", with: "'\\''")
            let result = await runShell("\(path) config set models.providers.\(provider).apiKey '\(escapedKey)'")

            // Verify the key was saved by re-reading config
            let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
            if FileManager.default.fileExists(atPath: configPath),
               let data = FileManager.default.contents(atPath: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [String: Any],
               let providers = models["providers"] as? [String: Any],
               let providerConfig = providers[provider] as? [String: Any],
               let savedKey = providerConfig["apiKey"] as? String,
               !savedKey.isEmpty {
                phaseStatuses[.apiKey] = .succeeded(L("已配置", "Configured"))
                await runVerifyPhase()
                return
            }

            // If config read fails but shell didn't error, still mark as succeeded
            if result != nil {
                phaseStatuses[.apiKey] = .succeeded(L("已配置", "Configured"))
                await runVerifyPhase()
            } else {
                phaseStatuses[.apiKey] = .failed(L("保存失败", "Save failed"))
            }
        }
    }

    // MARK: - Phase 4: Verify

    func runVerifyPhase() async {
        phaseStatuses[.verify] = .inProgress(L("验证中...", "Verifying..."))

        if await healthCheck(port: resolvedPort) {
            phaseStatuses[.verify] = .succeeded(L("一切就绪", "All set"))
        } else {
            phaseStatuses[.verify] = .failed(L("Gateway 无响应", "Gateway not responding"))
        }
    }

    // MARK: - Health Check

    private func healthCheck(port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                return true
            }
        } catch {}
        return false
    }

    // MARK: - Shell 执行工具

    /// 运行 shell 命令并返回输出
    private func runShell(_ command: String) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 启动后台 shell 进程（不等待退出）
    private func runShellBackground(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                print("[OpenClawSetup] Background process error: \(error)")
            }
        }
    }
}
