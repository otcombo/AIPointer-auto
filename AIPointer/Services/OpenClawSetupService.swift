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
    
    // MARK: - Published 属性
    
    @Published var installStatus: InstallStatus = .checking
    @Published var gatewayStatus: GatewayStatus = .unknown
    @Published var version: String?
    
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
                    await fetchVersion(path: trimmed)
                    return
                }
            }
            
            // 检查常见路径
            for path in commonPaths {
                if FileManager.default.isExecutableFile(atPath: path) {
                    installStatus = .installed(path: path)
                    await fetchVersion(path: path)
                    return
                }
            }
            
            installStatus = .notInstalled
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
    
    // MARK: - 操作
    
    /// 打开终端并执行安装命令
    func openTerminalWithInstall() {
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.installCommand)"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[OpenClawSetup] AppleScript error: \(error)")
            }
        }
    }
    
    /// 打开终端执行 openclaw gateway start
    func startGatewayInTerminal() {
        guard case .installed(let path) = installStatus else { return }
        
        let script = """
        tell application "Terminal"
            activate
            do script "\(path) gateway start"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
    
    /// 打开终端进行高级配置
    func openTerminalForConfig() {
        guard case .installed(let path) = installStatus else { return }
        
        let script = """
        tell application "Terminal"
            activate
            do script "echo '=== OpenClaw 配置 ===' && \(path) status && echo '' && echo '编辑配置: \(path) config edit'"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
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
