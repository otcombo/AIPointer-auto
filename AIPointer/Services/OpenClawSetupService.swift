import Foundation
import Combine

/// 检测和管理本机 OpenClaw 安装状态
@MainActor
class OpenClawSetupService: ObservableObject {

    // MARK: - 状态枚举

    enum SetupPhase: Int, CaseIterable, Comparable {
        case install = 0, gateway = 1, apiKey = 2, verify = 3

        static func < (lhs: SetupPhase, rhs: SetupPhase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum PhaseStatus: Equatable {
        case pending
        case inProgress(String)
        case succeeded(String)
        case failed(String)
        case needsInput
    }

    // MARK: - Published 属性

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
    private var setupTask: Task<Void, Never>?

    // MARK: - Full Setup Flow

    /// 入口：取消上一次运行，重置状态，顺序执行 4 个 phase
    func runFullSetup() {
        runSetup(from: .install)
    }

    /// 从指定 phase 开始执行（用于智能重试）
    func runSetup(from startPhase: SetupPhase) {
        // Cancel any previous setup task
        setupTask?.cancel()

        // Reset phases from startPhase onwards to .pending
        for phase in SetupPhase.allCases where phase >= startPhase {
            phaseStatuses[phase] = .pending
        }

        setupTask = Task {
            if startPhase <= .install {
                await runInstallPhase()
                if Task.isCancelled { return }
                guard case .succeeded = phaseStatuses[.install] else { return }
            }

            if startPhase <= .gateway {
                await runGatewayPhase()
                if Task.isCancelled { return }
                guard case .succeeded = phaseStatuses[.gateway] else { return }
            }

            if startPhase <= .apiKey {
                await runAPIKeyPhase()
                if Task.isCancelled { return }
                // apiKey phase may pause at .needsInput — verify phase runs after user submits
                guard case .succeeded = phaseStatuses[.apiKey] else { return }
            }

            if startPhase <= .verify {
                await runVerifyPhase()
            }
        }
    }

    // MARK: - Phase 1: Install

    private func runInstallPhase() async {
        phaseStatuses[.install] = .inProgress(L("检测中...", "Checking..."))

        if let found = await findOpenClaw() {
            installedPath = found
            await fetchVersion(path: found)
            let desc = version.map { "v\($0)" } ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        // Not installed — run install
        phaseStatuses[.install] = .inProgress(L("正在安装...", "Installing..."))
        let result = await runShell(Self.installCommand)

        if Task.isCancelled { return }

        // Re-check after install
        if let found = await findOpenClaw() {
            installedPath = found
            await fetchVersion(path: found)
            let desc = version.map { "v\($0)" } ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        let errorMsg = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        phaseStatuses[.install] = .failed(L("安装失败", "Installation failed") + (errorMsg.isEmpty ? "" : ": \(errorMsg)"))
    }

    /// 查找 openclaw 可执行文件，返回路径或 nil
    private func findOpenClaw() async -> String? {
        if let path = await runShell("which openclaw") {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
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

    // MARK: - Phase 2: Gateway

    private func runGatewayPhase() async {
        phaseStatuses[.gateway] = .inProgress(L("检测 Gateway...", "Checking Gateway..."))

        // Check if already running on current port
        if await healthCheck(port: resolvedPort) {
            phaseStatuses[.gateway] = .succeeded(L("端口 \(resolvedPort)", "Port \(resolvedPort)"))
            return
        }

        // Check port availability and find a free port
        var port = resolvedPort
        for _ in 0..<10 {
            if let lsofOutput = await runShell("lsof -ti tcp:\(port)") {
                let trimmed = lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                // Take only the first PID (lsof may return multiple lines)
                guard let firstPid = trimmed.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) else {
                    break // No PID — port is free
                }

                // Port occupied — check if it's openclaw
                if let psOutput = await runShell("ps -p \(firstPid) -o comm=") {
                    if psOutput.contains("openclaw") {
                        // openclaw is using this port but health failed — try with this port
                        break
                    }
                }
                // Not openclaw, try next port
                port += 1
                continue
            }
            break // Port is free
        }

        if Task.isCancelled { return }

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
            if Task.isCancelled { return }
            if await healthCheck(port: port) {
                phaseStatuses[.gateway] = .succeeded(L("端口 \(port)", "Port \(port)"))
                return
            }
        }

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

        // Check environment variables (best-effort; .app bundles may not inherit shell env)
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
        // Cancel any previous setup task to avoid conflict
        setupTask?.cancel()

        setupTask = Task {
            phaseStatuses[.apiKey] = .inProgress(L("正在保存...", "Saving..."))

            guard let path = installedPath else {
                phaseStatuses[.apiKey] = .failed(L("找不到 openclaw 路径", "openclaw path not found"))
                return
            }

            // Escape single quotes in the API key
            let escapedKey = apiKey.replacingOccurrences(of: "'", with: "'\\''")
            let result = await runShell("\(path) config set models.providers.\(provider).apiKey '\(escapedKey)'")

            if Task.isCancelled { return }

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

    private func runVerifyPhase() async {
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
