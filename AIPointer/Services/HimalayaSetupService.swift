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

    // MARK: - Setup Flow

    func runFullSetup() {
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
        setupTask?.cancel()
        for phase in SetupPhase.allCases {
            phaseStatuses[phase] = .skipped
        }
        isSkipped = true
    }

    // MARK: - Phase 1: Install

    private func runInstallPhase() async {
        phaseStatuses[.install] = .inProgress(L("检测中...", "Checking..."))

        if let found = await findHimalaya() {
            installedPath = found
            let version = await fetchVersion(path: found)
            let desc = version ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

        // Not installed — try brew first
        phaseStatuses[.install] = .inProgress(L("正在安装...", "Installing..."))

        let brewAvailable = await runShell("which brew") != nil
        if brewAvailable {
            let _ = await runShell("brew install himalaya")
        } else {
            // Download from GitHub releases
            let binDir = NSHomeDirectory() + "/.local/bin"
            let _ = await runShell("mkdir -p '\(binDir)'")

            let arch = await runShell("uname -m")
            let archTrimmed = arch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "arm64"
            let target = archTrimmed == "x86_64" ? "x86_64-apple-darwin" : "aarch64-apple-darwin"
            let downloadCmd = """
            curl -sL "https://github.com/pimalaya/himalaya/releases/latest/download/himalaya-\(target).tar.gz" | tar xz -C '\(binDir)'
            """
            let _ = await runShell(downloadCmd)
        }

        if Task.isCancelled { return }

        // Re-check after install
        if let found = await findHimalaya() {
            installedPath = found
            let version = await fetchVersion(path: found)
            let desc = version ?? found
            phaseStatuses[.install] = .succeeded(L("已安装 \(desc)", "Installed \(desc)"))
            return
        }

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
        phaseStatuses[.email] = .inProgress(L("检查邮箱配置...", "Checking email config..."))

        // Check if config already exists
        if FileManager.default.fileExists(atPath: configPath) {
            // Try to verify the account
            if let path = installedPath {
                let result = await runShell("\(path) account doctor")
                if Task.isCancelled { return }
                if let output = result, !output.contains("error") && !output.contains("Error") {
                    phaseStatuses[.email] = .succeeded(L("已配置", "Configured"))
                    return
                }
            }
        }

        if Task.isCancelled { return }

        // No config or check failed — need user input
        phaseStatuses[.email] = .needsInput
    }

    /// 用户提交邮箱和 App Password 后调用
    func continueAfterEmail(email: String, appPassword: String) {
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
            } catch {
                phaseStatuses[.email] = .failed(L("配置写入失败", "Failed to write config"))
                return
            }

            if Task.isCancelled { return }

            // Verify
            guard let path = installedPath else {
                phaseStatuses[.email] = .failed(L("找不到 himalaya", "himalaya not found"))
                return
            }

            let result = await runShell("\(path) account doctor")
            if Task.isCancelled { return }

            if let output = result, !output.lowercased().contains("error") {
                phaseStatuses[.email] = .succeeded(L("验证通过", "Verified"))
            } else {
                let errorMsg = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = pipe
                process.standardError = pipe
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
}
