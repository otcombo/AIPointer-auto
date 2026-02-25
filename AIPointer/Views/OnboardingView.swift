import SwiftUI
import AVKit

/// 首次启动引导流程 — Figma onboarding dialog 样式
struct OnboardingView: View {
    @StateObject private var permissions = PermissionChecker()
    @StateObject private var openClawSetup = OpenClawSetupService()
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("responseLanguage") private var responseLanguage = defaultResponseLanguage

    @State private var currentStep: Step = .fnKey
    @State private var pollTimer: Timer?
    @State private var gatewayPollTimer: Timer?

    var onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case fnKey = 0
        case autoVerify = 1
        case smartSuggest = 2
        case permissions = 3
        case openclawSetup = 4
        case configure = 5
    }

    private var showsIllustration: Bool {
        currentStep == .fnKey || currentStep == .autoVerify || currentStep == .smartSuggest
    }

    private static let videoDir = "/Users/otcombo/Documents/Playgrounds/AIPointer Video"

    private var videoFileName: String? {
        switch currentStep {
        case .fnKey:        return "AIPointer-Feature-1.mp4"
        case .autoVerify:   return "AIPointer-Feature-2.mp4"
        case .smartSuggest: return "AIPointer-Feature-3.mp4"
        default:            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsIllustration {
                illustrationArea
                    .padding(.bottom, 24)
            } else {
                Spacer().frame(height: 24)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(stepTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.black)

                stepContent
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            footer
        }
        .padding(12)
        .frame(width: 520, height: 520)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 32, x: 0, y: 16)
        .onAppear {
            Task { await permissions.checkAll() }
        }
        .onDisappear {
            pollTimer?.invalidate()
            gatewayPollTimer?.invalidate()
        }
    }

    // MARK: - Step Title

    private var stepTitle: String {
        switch currentStep {
        case .fnKey:         return L("Fn 键，你的 AI 入口", "Fn Key, Your AI Gateway")
        case .autoVerify:    return L("验证码自动填充", "Auto-fill Verification Codes")
        case .smartSuggest:  return L("行为感知，主动推荐", "Behavior-Aware Suggestions")
        case .permissions:   return L("系统权限", "System Permissions")
        case .openclawSetup: return L("OpenClaw 后端", "OpenClaw Backend")
        case .configure:     return L("连接设置", "Connection Settings")
        }
    }

    // MARK: - Illustration Area

    private var illustrationArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                )

            if let fileName = videoFileName {
                LoopingVideoPlayer(url: URL(fileURLWithPath: "\(Self.videoDir)/\(fileName)"))
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .fnKey:         fnKeyContent
        case .autoVerify:    autoVerifyContent
        case .smartSuggest:  smartSuggestContent
        case .permissions:   permissionsContent
        case .openclawSetup: openclawSetupContent
        case .configure:     configureContent
        }
    }

    // MARK: - Step 1: Fn Key

    private var fnKeyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(icon: "keyboard",
                       title: L("短按 Fn", "Tap Fn"),
                       desc: L("展开输入框，输入问题按 Enter 发送", "Open input, type your question and press Enter"))
            featureRow(icon: "camera.viewfinder",
                       title: L("长按 Fn", "Hold Fn"),
                       desc: L("框选屏幕区域作为图片上下文", "Select a screen region as image context"))
            featureRow(icon: "text.cursor",
                       title: L("选中后按 Fn", "Select then Fn"),
                       desc: L("自动捕获选中文字或 Finder 文件路径", "Capture selected text or Finder file paths"))
        }
    }

    // MARK: - Step 2: Auto Verify

    private var autoVerifyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(icon: "eye",
                       title: L("自动检测", "Auto Detect"),
                       desc: L("识别页面中的 OTP 输入框", "Detect OTP input fields on web pages"))
            featureRow(icon: "envelope.open",
                       title: L("邮件获取", "Email Fetch"),
                       desc: L("通过 himalaya CLI 读取验证码", "Read codes via himalaya CLI"))
            featureRow(icon: "text.insert",
                       title: L("自动填入", "Auto Fill"),
                       desc: L("验证码就绪后自动填入，无需手动操作", "Fills the code automatically, no manual work"))

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(L("需要安装 himalaya CLI 并配置邮箱 IMAP",
                       "Requires himalaya CLI with IMAP configured"))
                    .font(.system(size: 11))
            }
            .foregroundColor(.black.opacity(0.35))
            .padding(.top, 2)
        }
    }

    // MARK: - Step 3: Smart Suggest

    private var smartSuggestContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(icon: "waveform.path.ecg",
                       title: L("行为采集", "Activity Capture"),
                       desc: L("记录点击、复制、应用切换等操作信号（本地处理，不上传）",
                              "Track clicks, copies, app switches (local only, never uploaded)"))
            featureRow(icon: "brain.head.profile",
                       title: L("意图分析", "Intent Analysis"),
                       desc: L("AI 分析操作模式，判断你可能需要的帮助",
                              "AI analyzes patterns to predict what help you need"))
            featureRow(icon: "text.bubble",
                       title: L("主动建议", "Proactive Suggestions"),
                       desc: L("在指针附近弹出建议气泡，按 Fn 接受并开始对话",
                              "A suggestion bubble appears near the pointer — tap Fn to accept"))
        }
    }

    // MARK: - Step 4: Permissions

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("点击对应权限行打开系统设置页面，授权后自动检测。",
                   "Tap a row to open System Settings. Permissions are detected automatically."))
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.6))

            VStack(spacing: 6) {
                permissionRow(
                    icon: "keyboard",
                    title: L("输入监控", "Input Monitoring"),
                    subtitle: L("鼠标追踪、Fn 键监听、Cmd+C 检测",
                               "Mouse tracking, Fn key, Cmd+C detection"),
                    state: permissions.inputMonitoring, required: true,
                    action: {
                        permissions.requestInputMonitoring()
                        permissions.openInputMonitoringSettings()
                    }
                )
                permissionRow(
                    icon: "hand.raised",
                    title: L("辅助功能", "Accessibility"),
                    subtitle: L("读取选中文字、检测 OTP 输入框、读取窗口标题",
                               "Read selected text, detect OTP fields, read window titles"),
                    state: permissions.accessibility, required: true,
                    action: {
                        permissions.requestAccessibility()
                        permissions.openAccessibilitySettings()
                    }
                )
                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: L("屏幕录制", "Screen Recording"),
                    subtitle: L("Fn 长按截图功能", "Screenshot via Fn long press"),
                    state: permissions.screenRecording, required: false,
                    action: { permissions.openScreenRecordingSettings() }
                )
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(L("授权后可能需要重启应用才能生效",
                       "You may need to restart the app after granting permissions"))
                    .font(.system(size: 11))
            }
            .foregroundColor(.black.opacity(0.35))
        }
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    private func permissionRow(
        icon: String, title: String, subtitle: String,
        state: PermissionChecker.PermissionState,
        required: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 24)
                    .foregroundColor(.black.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.black)
                        if required {
                            Text(L("必需", "Required"))
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12))
                                .foregroundColor(.red)
                                .cornerRadius(4)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.black.opacity(0.4))
                }

                Spacer()

                if state == .granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.black.opacity(0.3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(state == .granted ? Color.green.opacity(0.05) : Color.black.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 5: OpenClaw Setup

    private var openclawSetupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("AIPointer 需要 OpenClaw 作为 AI 后端。",
                       "AIPointer requires OpenClaw as its AI backend."))
                    .font(.system(size: 14))
                    .foregroundColor(.black.opacity(0.6))

                // Install status
                statusRow(
                    icon: installStatusIcon,
                    iconColor: installStatusColor,
                    title: L("OpenClaw 安装", "OpenClaw Installation"),
                    subtitle: installStatusText,
                    trailing: {
                        if !openClawSetup.installStatus.isInstalled {
                            smallActionButton(L("安装", "Install")) {
                                openClawSetup.openTerminalWithInstall()
                            }
                        }
                    }
                )

                // Gateway status (only after installed)
                if openClawSetup.installStatus.isInstalled {
                    statusRow(
                        icon: gatewayStatusIcon,
                        iconColor: gatewayStatusColor,
                        title: L("Gateway 服务", "Gateway Service"),
                        subtitle: gatewayStatusText,
                        trailing: {
                            if openClawSetup.gatewayStatus == .stopped {
                                smallActionButton(L("启动", "Start")) {
                                    openClawSetup.startGatewayInTerminal()
                                }
                            }
                        }
                    )
                }

                // API Key config (only after gateway running)
                if openClawSetup.gatewayStatus == .running {
                    statusRow(
                        icon: "key.fill",
                        iconColor: .orange,
                        title: L("配置 API Key", "Configure API Key"),
                        subtitle: L("OpenClaw 需要 LLM 提供商的 API Key",
                                   "OpenClaw needs an LLM provider API Key"),
                        trailing: {
                            smallActionButton(L("打开终端", "Open Terminal")) {
                                openClawSetup.openTerminalForConfig()
                            }
                        }
                    )
                }

                // Install command hint
                if !openClawSetup.installStatus.isInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(OpenClawSetupService.installCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)

                        Button(action: { openClawSetup.checkInstallation() }) {
                            Text(L("重新检测", "Re-check"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(L("也可连接远程 OpenClaw 服务器，跳过本步骤在下一步配置",
                           "You can also connect to a remote OpenClaw server in the next step"))
                        .font(.system(size: 11))
                }
                .foregroundColor(.black.opacity(0.35))
            }
        }
        .onAppear {
            openClawSetup.checkInstallation()
            startGatewayPolling()
        }
        .onDisappear { stopGatewayPolling() }
    }

    private func statusRow<Trailing: View>(
        icon: String, iconColor: Color,
        title: String, subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.4))
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func smallActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // OpenClaw status helpers
    private var installStatusIcon: String {
        switch openClawSetup.installStatus {
        case .checking:     return "arrow.clockwise"
        case .installed:    return "shippingbox.fill"
        case .notInstalled: return "shippingbox"
        case .error:        return "exclamationmark.triangle"
        }
    }

    private var installStatusColor: Color {
        switch openClawSetup.installStatus {
        case .checking:     return .secondary
        case .installed:    return .green
        case .notInstalled: return .orange
        case .error:        return .red
        }
    }

    private var installStatusText: String {
        switch openClawSetup.installStatus {
        case .checking:
            return L("检测中...", "Checking...")
        case .installed(let path):
            if let ver = openClawSetup.version {
                return L("已安装 \(ver) — \(path)", "Installed \(ver) — \(path)")
            }
            return L("已安装 — \(path)", "Installed — \(path)")
        case .notInstalled:
            return L("未检测到 OpenClaw", "OpenClaw not found")
        case .error(let msg):
            return L("检测出错：\(msg)", "Error: \(msg)")
        }
    }

    private var gatewayStatusIcon: String {
        switch openClawSetup.gatewayStatus {
        case .unknown: return "arrow.clockwise"
        case .running: return "bolt.fill"
        case .stopped: return "bolt.slash"
        case .error:   return "exclamationmark.triangle"
        }
    }

    private var gatewayStatusColor: Color {
        switch openClawSetup.gatewayStatus {
        case .unknown: return .secondary
        case .running: return .green
        case .stopped: return .orange
        case .error:   return .red
        }
    }

    private var gatewayStatusText: String {
        switch openClawSetup.gatewayStatus {
        case .unknown:      return L("检测中...", "Checking...")
        case .running:      return L("Gateway 正在运行", "Gateway is running")
        case .stopped:      return L("Gateway 未运行", "Gateway is not running")
        case .error(let m): return L("错误：\(m)", "Error: \(m)")
        }
    }

    // MARK: - Step 6: Configure

    private var configureContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("配置 OpenClaw 后端连接。如果不确定，保持默认即可。",
                       "Configure the OpenClaw backend connection. Keep defaults if unsure."))
                    .font(.system(size: 14))
                    .foregroundColor(.black.opacity(0.6))

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(L("服务器连接", "SERVER CONNECTION"))
                    fieldGroup(label: "Server URL", placeholder: "http://localhost:18789", text: $backendURL)
                    fieldGroup(label: "Agent ID", placeholder: "main", text: $agentId)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("回复语言", "Response Language"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black)
                        Picker("", selection: $responseLanguage) {
                            Text("中文").tag("zh-CN")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(L("配置文件", "CONFIG FILES"))
                    configCheckRow(
                        icon: "doc.text",
                        title: "~/.openclaw/openclaw.json",
                        desc: L("API 密钥、模型配置、网关认证 Token",
                               "API keys, model config, gateway auth token")
                    )
                    configCheckRow(
                        icon: "envelope",
                        title: "himalaya CLI + IMAP",
                        desc: L("验证码自动填充功能所需，brew install himalaya",
                               "Required for auto-fill verification codes — brew install himalaya")
                    )

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text(L("如果只用对话功能，配置 openclaw.json 即可",
                               "For chat only, just configure openclaw.json"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.black.opacity(0.35))
                }
            }
        }
    }

    // MARK: - Shared Components

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundColor(.black.opacity(0.5))

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.black)

            Text(desc)
                .font(.system(size: 13))
                .foregroundColor(.black.opacity(0.5))
                .lineLimit(2)
        }
    }

    private func configCheckRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 20, height: 18)
                .foregroundColor(.black.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(.black)
                Text(desc).font(.system(size: 12)).foregroundColor(.black.opacity(0.45))
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black.opacity(0.35))
            .textCase(.uppercase)
    }

    private func fieldGroup(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(.black)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step == currentStep ? Color.black : Color.black.opacity(0.1))
                        .frame(width: step == currentStep ? 48 : 16, height: 4)
                        .animation(.easeInOut(duration: 0.25), value: currentStep)
                }
            }
            .padding(.leading, 12)

            Spacer()

            if currentStep.rawValue > 0 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if let prev = Step(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }) {
                    Text(L("上一步", "Back"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }

            onboardingButton(nextButtonTitle) {
                if currentStep == .configure {
                    onComplete()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if let next = Step(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
            }
            .opacity(isNextDisabled ? 0.4 : 1.0)
            .disabled(isNextDisabled)
        }
        .padding(.top, 12)
    }

    private func onboardingButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(minWidth: 100, minHeight: 36)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var nextButtonTitle: String {
        switch currentStep {
        case .fnKey:         return L("继续", "Continue")
        case .autoVerify:    return L("继续", "Continue")
        case .smartSuggest:  return L("继续", "Continue")
        case .permissions:
            return permissions.allRequiredGranted
                ? L("下一步", "Next")
                : L("请先开启权限", "Grant permissions first")
        case .openclawSetup: return L("下一步", "Next")
        case .configure:     return L("开始使用", "Get Started")
        }
    }

    private var isNextDisabled: Bool {
        currentStep == .permissions && !permissions.allRequiredGranted
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

// MARK: - Looping Video Player

struct LoopingVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        player.play()

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url,
              currentURL != url else { return }
        let item = AVPlayerItem(url: url)
        nsView.player?.replaceCurrentItem(with: item)
        nsView.player?.play()
    }
}
