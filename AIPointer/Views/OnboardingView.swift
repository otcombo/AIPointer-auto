import SwiftUI

/// 首次启动引导流程
struct OnboardingView: View {
    @StateObject private var permissions = PermissionChecker()
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("responseLanguage") private var responseLanguage = "zh-CN"

    @State private var currentStep: Step = .welcome
    @State private var pollTimer: Timer?

    var onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case configure = 2
        case ready = 3
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

    // MARK: - Step 3: Configure

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
}
