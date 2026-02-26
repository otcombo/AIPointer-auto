import SwiftUI

/// 首次启动引导流程
struct OnboardingView: View {
    @StateObject private var permissions = PermissionChecker()
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("responseLanguage") private var responseLanguage = "zh-CN"

    @StateObject private var openClawSetup = OpenClawSetupService()
    @State private var currentStep: Step = .welcome
    @State private var pollTimer: Timer?
    @State private var gatewayPollTimer: Timer?

    var onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case openclawSetup = 2
        case configure = 3
        case ready = 4
    }

    var body: some View {
        VStack(spacing: 0) {
            // 进度指示器
            progressBar
                .padding(.top, 20)
                .padding(.horizontal, 40)

            // 内容区域
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .openclawSetup:
                    openclawSetupStep
                case .configure:
                    configureStep
                case .ready:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 20)

            // 底部按钮
            bottomBar
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            Task { await permissions.checkAll() }
        }
        .onDisappear {
            pollTimer?.invalidate()
            gatewayPollTimer?.invalidate()
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue
                          ? Color.accentColor
                          : Color.secondary.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "pointer.arrow.ipad.rays")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("欢迎使用 AIPointer")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("AI 驱动的桌面助手，以自定义指针形式常驻屏幕。\n按 Fn 键即可与 AI 对话，支持截图分析和行为感知建议。")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Spacer()
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("系统权限")
                .font(.title2)
                .fontWeight(.bold)

            Text("AIPointer 需要以下权限才能正常工作。请逐一开启。")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "keyboard",
                    title: "输入监控",
                    subtitle: "追踪鼠标移动、监听 Fn 键（必需）",
                    state: permissions.inputMonitoring,
                    required: true,
                    action: {
                        permissions.requestInputMonitoring()
                        permissions.openInputMonitoringSettings()
                    }
                )

                permissionRow(
                    icon: "hand.raised",
                    title: "辅助功能",
                    subtitle: "读取选中文字、检测 OTP 输入框（必需）",
                    state: permissions.accessibility,
                    required: true,
                    action: {
                        permissions.requestAccessibility()
                    }
                )

                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "屏幕录制",
                    subtitle: "截图功能，Fn 长按框选区域（可选）",
                    state: permissions.screenRecording,
                    required: false,
                    action: {
                        permissions.openScreenRecordingSettings()
                    }
                )
            }

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("授权后可能需要重启应用才能生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

            Spacer()
        }
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        state: PermissionChecker.PermissionState,
        required: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if required {
                        Text("必需")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    } else {
                        Text("可选")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if state == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            } else {
                Button("开启") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state == .granted
                      ? Color.green.opacity(0.06)
                      : Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Step 3: OpenClaw Setup

    private var openclawSetupStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenClaw 后端")
                .font(.title2)
                .fontWeight(.bold)

            Text("AIPointer 需要 OpenClaw 作为 AI 后端。检测本机安装状态...")
                .font(.body)
                .foregroundColor(.secondary)

            // 安装状态卡片
            VStack(spacing: 12) {
                // 安装检测
                HStack(spacing: 12) {
                    Image(systemName: installStatusIcon)
                        .font(.title2)
                        .frame(width: 32)
                        .foregroundColor(installStatusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenClaw 安装")
                            .font(.headline)
                        Text(installStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !openClawSetup.installStatus.isInstalled {
                        Button("安装") {
                            openClawSetup.openTerminalWithInstall()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(openClawSetup.installStatus.isInstalled
                              ? Color.green.opacity(0.06)
                              : Color.orange.opacity(0.06))
                )

                // Gateway 状态（仅安装后显示）
                if openClawSetup.installStatus.isInstalled {
                    HStack(spacing: 12) {
                        Image(systemName: gatewayStatusIcon)
                            .font(.title2)
                            .frame(width: 32)
                            .foregroundColor(gatewayStatusColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gateway 服务")
                                .font(.headline)
                            Text(gatewayStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if openClawSetup.gatewayStatus == .stopped {
                            Button("启动") {
                                openClawSetup.startGatewayInTerminal()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if openClawSetup.gatewayStatus == .running {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(openClawSetup.gatewayStatus == .running
                                  ? Color.green.opacity(0.06)
                                  : Color.secondary.opacity(0.06))
                    )
                }
            }

            // 安装说明
            if !openClawSetup.installStatus.isInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("安装命令：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(OpenClawSetupService.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)

                    Text("安装完成后点击"重新检测"")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("重新检测") {
                        openClawSetup.checkInstallation()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("也可连接远程 OpenClaw 服务器，跳过本步骤在下一步配置地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

            Spacer()
        }
        .onAppear {
            openClawSetup.checkInstallation()
            startGatewayPolling()
        }
        .onDisappear {
            stopGatewayPolling()
        }
    }

    // OpenClaw Setup 辅助计算属性
    private var installStatusIcon: String {
        switch openClawSetup.installStatus {
        case .checking: return "arrow.clockwise"
        case .installed: return "shippingbox.fill"
        case .notInstalled: return "shippingbox"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var installStatusColor: Color {
        switch openClawSetup.installStatus {
        case .checking: return .secondary
        case .installed: return .green
        case .notInstalled: return .orange
        case .error: return .red
        }
    }

    private var installStatusText: String {
        switch openClawSetup.installStatus {
        case .checking: return "检测中..."
        case .installed(let path):
            if let ver = openClawSetup.version {
                return "已安装 \(ver) — \(path)"
            }
            return "已安装 — \(path)"
        case .notInstalled: return "未检测到 OpenClaw"
        case .error(let msg): return "检测出错：\(msg)"
        }
    }

    private var gatewayStatusIcon: String {
        switch openClawSetup.gatewayStatus {
        case .unknown: return "arrow.clockwise"
        case .running: return "bolt.fill"
        case .stopped: return "bolt.slash"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var gatewayStatusColor: Color {
        switch openClawSetup.gatewayStatus {
        case .unknown: return .secondary
        case .running: return .green
        case .stopped: return .orange
        case .error: return .red
        }
    }

    private var gatewayStatusText: String {
        switch openClawSetup.gatewayStatus {
        case .unknown: return "检测中..."
        case .running: return "Gateway 正在运行"
        case .stopped: return "Gateway 未运行"
        case .error(let msg): return "错误：\(msg)"
        }
    }

    // MARK: - Step 4: Configure

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接设置")
                .font(.title2)
                .fontWeight(.bold)

            Text("配置 OpenClaw 后端连接。如果不确定，保持默认即可。")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL")
                        .font(.headline)
                    TextField("http://localhost:18789", text: $backendURL)
                        .textFieldStyle(.roundedBorder)
                    Text("OpenClaw 服务器地址")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent ID")
                        .font(.headline)
                    TextField("main", text: $agentId)
                        .textFieldStyle(.roundedBorder)
                    Text("要对话的 Agent 名称")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("回复语言")
                        .font(.headline)
                    Picker("", selection: $responseLanguage) {
                        Text("中文").tag("zh-CN")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("一切就绪！")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                Text("按 **Fn** 打开输入框与 AI 对话")
                Text("长按 **Fn** 截图并分析")
                Text("AI 会在你需要时主动提供建议")
            }
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if currentStep != .welcome {
                Button("上一步") {
                    withAnimation {
                        if let prev = Step(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep == .ready {
                Button("开始使用") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(nextButtonTitle) {
                    withAnimation {
                        if let next = Step(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(currentStep == .permissions && !permissions.allRequiredGranted)
            }
        }
    }

    private var nextButtonTitle: String {
        switch currentStep {
        case .welcome: return "开始设置"
        case .permissions:
            return permissions.allRequiredGranted ? "下一步" : "请先开启必需权限"
        case .openclawSetup: return "下一步"
        case .configure: return "完成"
        case .ready: return "开始使用"
        }
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                await permissions.checkAll()
            }
        }
    }

    private func stopPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Gateway Polling

    private func startGatewayPolling() {
        openClawSetup.checkGatewayStatus(baseURL: backendURL)
        gatewayPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                openClawSetup.checkGatewayStatus(baseURL: backendURL)
            }
        }
    }

    private func stopGatewayPolling() {
        gatewayPollTimer?.invalidate()
        gatewayPollTimer = nil
    }
}
