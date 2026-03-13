import Foundation
import Combine

/// 检测和管理本机 OpenClaw 安装状态
@MainActor
class OpenClawSetupService: ObservableObject {

    // MARK: - 状态枚举

    enum SetupPhase: Int, CaseIterable, Comparable {
        case install = 0, gateway = 1, apiKey = 2

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

    private func log(_ msg: String) { OnboardingLog.log("OpenClaw", msg) }

    // MARK: - Full Setup Flow

    /// 入口：取消上一次运行，重置状态，顺序执行 4 个 phase
    func runFullSetup() {
        log("runFullSetup starting")
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
            }
        }
    }

    // MARK: - Phase 1: Install

    private func runInstallPhase() async {
        log("Phase[install] starting")
        phaseStatuses[.install] = .inProgress(L("检测中...", "Checking..."))

        if let found = await findOpenClaw() {
            installedPath = found
            await fetchVersion(path: found)
            let desc = version.map { "v\($0)" } ?? found
            log("Phase[install] found existing: \(found), version: \(version ?? "unknown")")
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        log("Phase[install] not found, running install command")
        // Not installed — run install
        phaseStatuses[.install] = .inProgress(L("正在安装...", "Installing..."))
        let result = await runShell(Self.installCommand)

        if Task.isCancelled { log("Phase[install] cancelled"); return }

        // Re-check after install
        if let found = await findOpenClaw() {
            installedPath = found
            await fetchVersion(path: found)
            let desc = version.map { "v\($0)" } ?? found
            log("Phase[install] succeeded after install: \(found)")
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        let errorMsg = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("Phase[install] FAILED: \(errorMsg)")
        phaseStatuses[.install] = .failed(L("安装失败", "Installation failed") + (errorMsg.isEmpty ? "" : ": \(errorMsg)"))
    }

    /// 查找 openclaw 可执行文件，返回路径或 nil
    private func findOpenClaw() async -> String? {
        log("findOpenClaw: running 'which openclaw'")
        if let path = await runShell("which openclaw") {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed) {
                log("findOpenClaw: found via which → \(trimmed)")
                return trimmed
            }
            log("findOpenClaw: 'which' returned '\(trimmed)' but file doesn't exist")
        }

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                log("findOpenClaw: found at commonPath → \(path)")
                return path
            }
        }

        log("findOpenClaw: not found (checked which + \(commonPaths.count) common paths)")
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
        log("Phase[gateway] starting, resolvedPort=\(resolvedPort)")
        phaseStatuses[.gateway] = .inProgress(L("检测 Gateway...", "Checking Gateway..."))

        // Check if already running on current port
        if await healthCheck(port: resolvedPort) {
            log("Phase[gateway] already running on port \(resolvedPort)")
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
                        log("Phase[gateway] port \(port) occupied by openclaw (pid \(firstPid)), will use it")
                        break
                    }
                    log("Phase[gateway] port \(port) occupied by: \(psOutput.trimmingCharacters(in: .whitespacesAndNewlines)) (pid \(firstPid)), trying next")
                }
                // Not openclaw, try next port
                port += 1
                continue
            }
            break // Port is free
        }

        if Task.isCancelled { log("Phase[gateway] cancelled"); return }

        resolvedPort = port
        UserDefaults.standard.set("http://localhost:\(port)", forKey: "backendURL")

        // Start gateway
        phaseStatuses[.gateway] = .inProgress(L("正在启动 Gateway...", "Starting Gateway..."))
        guard let path = installedPath else {
            log("Phase[gateway] FAILED: installedPath is nil")
            phaseStatuses[.gateway] = .failed(L("找不到 openclaw 路径", "openclaw path not found"))
            return
        }

        // Ensure gateway.mode=local is set (required by openclaw to start without interactive prompt)
        let _ = await runShell("\(path) config set gateway.mode local")

        let cmd = "\(path) gateway start --port \(port)"
        log("Phase[gateway] launching: \(cmd)")
        runShellBackground(cmd)

        // Poll health up to 30 times (1s interval)
        for i in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { log("Phase[gateway] cancelled during polling"); return }
            if await healthCheck(port: port) {
                log("Phase[gateway] healthy after \(i+1)s on port \(port)")
                phaseStatuses[.gateway] = .succeeded(L("端口 \(port)", "Port \(port)"))
                return
            }
        }

        log("Phase[gateway] FAILED: timed out after 30s on port \(port)")
        phaseStatuses[.gateway] = .failed(L("Gateway 启动超时", "Gateway start timed out"))
    }

    // MARK: - Phase 3: API Key

    private func runAPIKeyPhase() async {
        log("Phase[apiKey] starting")
        phaseStatuses[.apiKey] = .inProgress(L("检查 API Key...", "Checking API Key..."))

        // Check ~/.openclaw/openclaw.json for provider API keys
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
        log("Phase[apiKey] checking config: \(configPath), exists=\(FileManager.default.fileExists(atPath: configPath))")
        if FileManager.default.fileExists(atPath: configPath),
           let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            log("Phase[apiKey] config parsed, providers: \(Array(providers.keys))")
            for (providerName, providerConfig) in providers {
                if let config = providerConfig as? [String: Any],
                   let apiKey = config["apiKey"] as? String,
                   !apiKey.isEmpty {
                    log("Phase[apiKey] found key for provider '\(providerName)' (length=\(apiKey.count))")
                    phaseStatuses[.apiKey] = .succeeded(L("已配置", "Configured"))
                    return
                }
            }
            log("Phase[apiKey] no valid API key in any provider")
        } else {
            log("Phase[apiKey] config file missing or invalid JSON")
        }

        // Check environment variables (best-effort; .app bundles may not inherit shell env)
        let envKeys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        for key in envKeys {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                log("Phase[apiKey] found env var \(key) (length=\(value.count))")
                phaseStatuses[.apiKey] = .succeeded(L("已配置（环境变量）", "Configured (env var)"))
                return
            }
        }

        log("Phase[apiKey] no key found, requesting user input")
        // No key found — need user input
        phaseStatuses[.apiKey] = .needsInput
    }

    private func providerBaseURL(_ provider: String) -> String {
        switch provider {
        case "anthropic":   return "https://api.anthropic.com"
        case "openai":      return "https://api.openai.com"
        case "openrouter":  return "https://openrouter.ai/api"
        case "google":      return "https://generativelanguage.googleapis.com"
        case "groq":        return "https://api.groq.com/openai"
        case "mistral":     return "https://api.mistral.ai"
        case "xai":         return "https://api.x.ai"
        case "cerebras":    return "https://api.cerebras.ai"
        default:            return "https://api.\(provider).com"
        }
    }

    /// 用户提交 API Key 后调用
    func continueAfterAPIKey(provider: String, apiKey: String) {
        log("continueAfterAPIKey: provider=\(provider), keyLength=\(apiKey.count)")
        // Cancel any previous setup task to avoid conflict
        setupTask?.cancel()

        setupTask = Task {
            phaseStatuses[.apiKey] = .inProgress(L("正在保存...", "Saving..."))

            guard let path = installedPath else {
                phaseStatuses[.apiKey] = .failed(L("找不到 openclaw 路径", "openclaw path not found"))
                return
            }

            // Set baseUrl first (required by openclaw config validation)
            let baseURL = providerBaseURL(provider)
            let _ = await runShell("\(path) config set models.providers.\(provider).baseUrl '\(baseURL)'")

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
                return
            }

            // If config read fails but shell didn't error, still mark as succeeded
            if result != nil {
                phaseStatuses[.apiKey] = .succeeded(L("已配置", "Configured"))
            } else {
                phaseStatuses[.apiKey] = .failed(L("保存失败", "Save failed"))
            }
        }
    }

    // MARK: - Health Check

    private func healthCheck(port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    return true
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                log("healthCheck port=\(port) status=\(httpResponse.statusCode) body=\(body.prefix(200))")
            }
        } catch {
            // Only log non-connection-refused errors (connection refused is expected during startup polling)
            let nsError = error as NSError
            if nsError.code != -1004 { // NSURLErrorCannotConnectToHost
                log("healthCheck port=\(port) error: \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Shell 执行工具

    /// 运行 shell 命令并返回 stdout+stderr 合并输出
    private func runShell(_ command: String) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let exitCode = process.terminationStatus

                    let cmdShort = command.count > 80 ? String(command.prefix(80)) + "..." : command
                    if exitCode != 0 || !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OnboardingLog.log("OpenClaw", "shell exit=\(exitCode) cmd=\(cmdShort)")
                        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OnboardingLog.log("OpenClaw", "shell stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    }

                    // Return stdout; if empty and stderr has content, return stderr for error info
                    let result = stdout.isEmpty ? stderr : stdout
                    continuation.resume(returning: result.isEmpty ? nil : result)
                } catch {
                    OnboardingLog.log("OpenClaw", "shell exception: \(error) cmd=\(command)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 启动后台 shell 进程（不等待退出），stderr 写入日志
    private func runShellBackground(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()

                // Read stderr in background and log it when process exits
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    if process.terminationStatus != 0 || !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OnboardingLog.log("OpenClaw", "bg-shell exit=\(process.terminationStatus) cmd=\(command)")
                        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OnboardingLog.log("OpenClaw", "bg-shell stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    }
                }
            } catch {
                OnboardingLog.log("OpenClaw", "bg-shell exception: \(error) cmd=\(command)")
            }
        }
    }
}
