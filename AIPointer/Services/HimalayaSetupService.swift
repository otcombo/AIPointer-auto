import Foundation

/// 检测和管理 himalaya CLI 安装及邮箱 IMAP 配置
@MainActor
class HimalayaSetupService: ObservableObject {

    // MARK: - 状态枚举

    enum SetupPhase: Int, CaseIterable, Comparable {
        case install = 0, email = 1

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
        case skipped
    }

    // MARK: - Published 属性

    @Published var phaseStatuses: [SetupPhase: PhaseStatus] = [
        .install: .pending,
        .email: .pending,
    ]
    @Published var isSkipped: Bool = false

    var allPhasesSucceeded: Bool {
        SetupPhase.allCases.allSatisfy { phase in
            if case .succeeded = phaseStatuses[phase] { return true }
            return false
        }
    }

    var isFinished: Bool {
        isSkipped || allPhasesSucceeded
    }

    // himalaya 可能安装在这些路径
    private let commonPaths = [
        "/usr/local/bin/himalaya",
        "/opt/homebrew/bin/himalaya",
        "\(NSHomeDirectory())/.local/bin/himalaya",
        "\(NSHomeDirectory())/.cargo/bin/himalaya",
    ]

    private let configPath = NSHomeDirectory() + "/.config/himalaya/config.toml"

    private var installedPath: String?
    private var setupTask: Task<Void, Never>?

    // MARK: - 域名 → IMAP 映射

    static let imapServers: [String: (host: String, port: Int)] = [
        "gmail.com": ("imap.gmail.com", 993),
        "qq.com": ("imap.qq.com", 993),
        "163.com": ("imap.163.com", 993),
        "outlook.com": ("outlook.office365.com", 993),
        "hotmail.com": ("outlook.office365.com", 993),
        "live.com": ("outlook.office365.com", 993),
        "icloud.com": ("imap.mail.me.com", 993),
        "me.com": ("imap.mail.me.com", 993),
        "yahoo.com": ("imap.mail.yahoo.com", 993),
    ]

    /// 根据邮箱域名返回 IMAP 服务器信息
    static func imapServer(for email: String) -> (host: String, port: Int) {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        return imapServers[domain] ?? ("imap.\(domain)", 993)
    }

    /// 根据邮箱域名返回获取 App Password 的帮助信息（指引文案 + URL）
    static func appPasswordHelp(for email: String) -> (guide: String, url: URL)? {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        switch domain {
        case "gmail.com":
            return (
                L("Google 账号 → 安全性 → 两步验证 → 应用专用密码",
                  "Google Account → Security → 2-Step Verification → App passwords"),
                URL(string: "https://myaccount.google.com/apppasswords")!
            )
        case "qq.com":
            return (
                L("QQ 邮箱 → 设置 → 账户 → POP3/IMAP 服务 → 生成授权码",
                  "QQ Mail → Settings → Account → POP3/IMAP → Generate auth code"),
                URL(string: "https://service.mail.qq.com/detail/0/75")!
            )
        case "163.com":
            return (
                L("网易邮箱 → 设置 → POP3/SMTP/IMAP → 开启 IMAP → 生成授权码",
                  "163 Mail → Settings → POP3/SMTP/IMAP → Enable IMAP → Generate auth code"),
                URL(string: "https://help.mail.163.com/faqDetail.do?code=d7a5dc8471cd0c0e8b4b8f4f8e49998b374173cfe9171305fa1ce630d7f67ac2")!
            )
        case "outlook.com", "hotmail.com", "live.com":
            return (
                L("Microsoft 账户 → 安全 → 高级安全选项 → 应用密码",
                  "Microsoft Account → Security → Advanced options → App passwords"),
                URL(string: "https://support.microsoft.com/account-billing/using-app-passwords-with-apps-that-don-t-support-two-step-verification-5896ed9b-4263-e681-128a-a6f2979a7944")!
            )
        case "icloud.com", "me.com":
            return (
                L("Apple ID → 登录和安全 → 应用专用密码 → 生成",
                  "Apple ID → Sign-In and Security → App-Specific Passwords → Generate"),
                URL(string: "https://support.apple.com/en-us/102654")!
            )
        case "yahoo.com":
            return (
                L("Yahoo 账户 → 账户安全 → 生成应用密码",
                  "Yahoo Account → Account Security → Generate app password"),
                URL(string: "https://help.yahoo.com/kb/generate-manage-third-party-passwords-sln15241.html")!
            )
        default:
            return nil
        }
    }

    private func log(_ msg: String) { OnboardingLog.log("Himalaya", msg) }

    // MARK: - Setup Flow

    func runFullSetup() {
        log("runFullSetup starting")
        guard !isSkipped else { return }
        setupTask?.cancel()

        for phase in SetupPhase.allCases {
            phaseStatuses[phase] = .pending
        }

        setupTask = Task {
            await runInstallPhase()
            if Task.isCancelled { return }
            guard case .succeeded = phaseStatuses[.install] else { return }

            await runEmailPhase()
        }
    }

    func skip() {
        log("user skipped himalaya setup")
        setupTask?.cancel()
        for phase in SetupPhase.allCases {
            phaseStatuses[phase] = .skipped
        }
        isSkipped = true
    }

    // MARK: - Phase 1: Install

    private func runInstallPhase() async {
        log("Phase[install] starting")
        phaseStatuses[.install] = .inProgress(L("检测中...", "Checking..."))

        if let found = await findHimalaya() {
            installedPath = found
            let version = await fetchVersion(path: found)
            log("Phase[install] found existing: \(found), version: \(version ?? "unknown")")
            let desc = version ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        // Not installed — try brew first
        log("Phase[install] not found, attempting installation")
        phaseStatuses[.install] = .inProgress(L("正在安装...", "Installing..."))

        let brewAvailable = await runShell("which brew") != nil
        log("Phase[install] brew available: \(brewAvailable)")
        if brewAvailable {
            let result = await runShell("brew install himalaya")
            log("Phase[install] brew install result: \(result?.prefix(200) ?? "nil")")
        } else {
            // Download from GitHub releases
            let binDir = NSHomeDirectory() + "/.local/bin"
            let _ = await runShell("mkdir -p '\(binDir)'")

            let arch = await runShell("uname -m")
            let archTrimmed = arch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "arm64"
            let target = archTrimmed == "x86_64" ? "x86_64-apple-darwin" : "aarch64-apple-darwin"
            log("Phase[install] downloading for target: \(target)")
            let downloadCmd = """
            curl -sL "https://github.com/pimalaya/himalaya/releases/latest/download/himalaya-\(target).tar.gz" | tar xz -C '\(binDir)'
            """
            let result = await runShell(downloadCmd)
            log("Phase[install] download result: \(result?.prefix(200) ?? "nil")")
        }

        if Task.isCancelled { log("Phase[install] cancelled"); return }

        // Re-check after install
        if let found = await findHimalaya() {
            installedPath = found
            let version = await fetchVersion(path: found)
            log("Phase[install] succeeded after install: \(found)")
            let desc = version ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        log("Phase[install] FAILED: not found after install attempt")
        phaseStatuses[.install] = .failed(L("安装失败", "Installation failed"))
    }

    private func findHimalaya() async -> String? {
        if let path = await runShell("which himalaya") {
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

    private func fetchVersion(path: String) async -> String? {
        if let output = await runShell("\(path) --version") {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Phase 2: Email

    private func runEmailPhase() async {
        log("Phase[email] starting, configPath=\(configPath)")
        phaseStatuses[.email] = .inProgress(L("检查邮箱配置...", "Checking email config..."))

        // Check if config already exists
        let configExists = FileManager.default.fileExists(atPath: configPath)
        log("Phase[email] config exists: \(configExists)")
        if configExists {
            // Try to verify the account
            if let path = installedPath {
                log("Phase[email] running 'himalaya account doctor'")
                let result = await runShell("\(path) account doctor")
                if Task.isCancelled { return }
                if let output = result, !output.contains("error") && !output.contains("Error") {
                    log("Phase[email] existing config verified OK")
                    phaseStatuses[.email] = .succeeded(L("已配置", "Configured"))
                    return
                }
                log("Phase[email] account doctor output: \(result?.prefix(300) ?? "nil")")
            }
        }

        if Task.isCancelled { return }

        log("Phase[email] requesting user input")
        // No config or check failed — need user input
        phaseStatuses[.email] = .needsInput
    }

    /// 用户提交邮箱和 App Password 后调用
    func continueAfterEmail(email: String, appPassword: String) {
        log("continueAfterEmail: \(email), server=\(Self.imapServer(for: email))")
        setupTask?.cancel()

        setupTask = Task {
            phaseStatuses[.email] = .inProgress(L("正在配置...", "Configuring..."))

            let server = Self.imapServer(for: email)

            let configContent = """
            [accounts.default]
            default = true
            email = "\(email)"

            backend.type = "imap"
            backend.host = "\(server.host)"
            backend.port = \(server.port)
            backend.encryption.type = "tls"
            backend.login = "\(email)"
            backend.auth.type = "password"
            backend.auth.raw = "\(appPassword)"
            """

            // Ensure config directory exists
            let configDir = (configPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

            // Write config file
            do {
                try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                log("Phase[email] config written to \(configPath)")
            } catch {
                log("Phase[email] FAILED to write config: \(error)")
                phaseStatuses[.email] = .failed(L("配置写入失败", "Failed to write config"))
                return
            }

            if Task.isCancelled { return }

            // Verify
            guard let path = installedPath else {
                log("Phase[email] FAILED: installedPath is nil")
                phaseStatuses[.email] = .failed(L("找不到 himalaya", "himalaya not found"))
                return
            }

            log("Phase[email] running 'himalaya account doctor' for verification")
            let result = await runShell("\(path) account doctor")
            if Task.isCancelled { return }

            if let output = result, !output.lowercased().contains("error") {
                log("Phase[email] verification succeeded")
                phaseStatuses[.email] = .succeeded(L("验证通过", "Verified"))
            } else {
                let errorMsg = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                log("Phase[email] verification FAILED: \(errorMsg)")
                phaseStatuses[.email] = .failed(
                    L("验证失败", "Verification failed") + (errorMsg.isEmpty ? "" : ": \(errorMsg)")
                )
            }
        }
    }

    /// 重试指定 phase
    func retrySetup(from phase: SetupPhase) {
        setupTask?.cancel()

        for p in SetupPhase.allCases where p >= phase {
            phaseStatuses[p] = .pending
        }

        setupTask = Task {
            if phase <= .install {
                await runInstallPhase()
                if Task.isCancelled { return }
                guard case .succeeded = phaseStatuses[.install] else { return }
            }

            if phase <= .email {
                await runEmailPhase()
            }
        }
    }

    // MARK: - Shell 执行工具

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
                        OnboardingLog.log("Himalaya", "shell exit=\(exitCode) cmd=\(cmdShort)")
                        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OnboardingLog.log("Himalaya", "shell stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    }

                    let result = stdout.isEmpty ? stderr : stdout
                    continuation.resume(returning: result.isEmpty ? nil : result)
                } catch {
                    OnboardingLog.log("Himalaya", "shell exception: \(error) cmd=\(command)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
