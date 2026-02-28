import SwiftUI
import AVKit

/// 首次启动引导流程 — Figma onboarding dialog 样式
struct OnboardingView: View {
    @StateObject private var permissions = PermissionChecker()
    @StateObject private var openClawSetup = OpenClawSetupService()

    @State private var currentStep: Step = .fnKey
    @State private var pollTimer: Timer?
    @State private var clickedPermissions: Set<String> = []
    @State private var pollsSinceFirstClick = 0

    // API Key input state
    @State private var selectedProvider: String = "anthropic"
    @State private var apiKeyInput: String = ""
    @State private var showPatienceMessage: Bool = false
    @State private var setupStarted: Bool = false
    @State private var patienceWorkItem: DispatchWorkItem?

    var onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case fnKey = 0
        case autoVerify = 1
        case smartSuggest = 2
        case permissions = 3
        case openclawSetup = 4
    }

    private var showsIllustration: Bool {
        currentStep == .fnKey || currentStep == .autoVerify || currentStep == .smartSuggest
    }

    private var videoURL: URL? {
        let name: String
        switch currentStep {
        case .fnKey:        name = "AIPointer-Feature-1"
        case .autoVerify:   name = "AIPointer-Feature-2"
        case .smartSuggest: name = "AIPointer-Feature-3"
        default:            return nil
        }
        return Bundle.module.url(forResource: name, withExtension: "mp4")
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
        .padding(.horizontal, 60)  // (640 - 520) / 2 = 60
        .padding(.top, 44)          // shadow radius 32 + margin
        .padding(.bottom, 92)       // shadow radius 32 + y-offset 16 + margin
        .onAppear { }
        .onDisappear {
            pollTimer?.invalidate()
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

            if let url = videoURL {
                LoopingVideoPlayer(url: url)
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
                        trackPermissionClick("inputMonitoring")
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
                        trackPermissionClick("accessibility")
                        permissions.openAccessibilitySettings()
                    }
                )
                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: L("屏幕录制", "Screen Recording"),
                    subtitle: L("Fn 长按截图功能", "Screenshot via Fn long press"),
                    state: permissions.screenRecording, required: false,
                    action: {
                        clickedPermissions.insert("screenRecording")
                        permissions.openScreenRecordingSettings()
                    }
                )
            }

            HStack(spacing: 4) {
                Image(systemName: shouldOfferRelaunch ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 11))
                if shouldOfferRelaunch {
                    Text(L("部分权限需要重启应用后才能生效",
                           "Some permissions require restarting the app to take effect"))
                        .font(.system(size: 11))
                } else {
                    Text(L("授权后可能需要重启应用才能生效",
                           "You may need to restart the app after granting permissions"))
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(shouldOfferRelaunch ? .orange : .black.opacity(0.35))
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

    // MARK: - Step 5: OpenClaw Setup (4-phase checklist)

    private var openclawSetupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("AIPointer 正在自动配置 OpenClaw 后端。",
                       "AIPointer is automatically configuring the OpenClaw backend."))
                    .font(.system(size: 14))
                    .foregroundColor(.black.opacity(0.6))

                VStack(spacing: 6) {
                    phaseRow(.install,
                             icon: "shippingbox.fill",
                             title: L("安装 OpenClaw", "Install OpenClaw"))
                    phaseRow(.gateway,
                             icon: "bolt.fill",
                             title: L("启动 Gateway", "Start Gateway"))
                    phaseRow(.apiKey,
                             icon: "key.fill",
                             title: L("配置 API Key", "Configure API Key"))
                    phaseRow(.verify,
                             icon: "checkmark.shield.fill",
                             title: L("验证连接", "Verify Connection"))
                }

                // API Key input section
                if openClawSetup.phaseStatuses[.apiKey] == .needsInput {
                    apiKeyInputSection
                }

                // Patience message for long install
                if showPatienceMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 11))
                        Text(L("安装时间较长，请耐心等待",
                               "Installation is taking a while, please be patient"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .onAppear {
            guard !setupStarted else { return }
            setupStarted = true
            openClawSetup.runFullSetup()
            schedulePatienceMessage()
        }
    }

    private func phaseRow(_ phase: OpenClawSetupService.SetupPhase, icon: String, title: String) -> some View {
        let status = openClawSetup.phaseStatuses[phase] ?? .pending

        return HStack(spacing: 10) {
            phaseStatusIcon(status, defaultIcon: icon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black)

                if let subtitle = phaseSubtitle(status) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.black.opacity(0.4))
                }
            }

            Spacer()

            if case .failed = status {
                Button(action: { retryPhase(phase) }) {
                    Text(L("重试", "Retry"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(phaseRowBackground(status))
        )
    }

    @ViewBuilder
    private func phaseStatusIcon(_ status: OpenClawSetupService.PhaseStatus, defaultIcon: String) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.2))
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.red)
        case .needsInput:
            Image(systemName: "key.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
        }
    }

    private func phaseSubtitle(_ status: OpenClawSetupService.PhaseStatus) -> String? {
        switch status {
        case .inProgress(let text): return text
        case .succeeded(let text): return text.isEmpty ? nil : text
        case .failed(let text): return text
        case .needsInput: return L("需要输入 API Key", "API Key required")
        case .pending: return nil
        }
    }

    private func phaseRowBackground(_ status: OpenClawSetupService.PhaseStatus) -> Color {
        switch status {
        case .succeeded: return Color.green.opacity(0.05)
        case .failed: return Color.red.opacity(0.05)
        case .needsInput: return Color.orange.opacity(0.05)
        default: return Color.black.opacity(0.03)
        }
    }

    private func retryPhase(_ phase: OpenClawSetupService.SetupPhase) {
        showPatienceMessage = false
        openClawSetup.runSetup(from: phase)
        if phase == .install {
            schedulePatienceMessage()
        }
    }

    private func schedulePatienceMessage() {
        patienceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in
            if case .inProgress = openClawSetup.phaseStatuses[.install] ?? .pending {
                showPatienceMessage = true
            }
        }
        patienceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: workItem)
    }

    // MARK: - API Key Input Section

    private var apiKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Provider selector
            VStack(alignment: .leading, spacing: 4) {
                Text(L("LLM 提供商", "LLM Provider"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)

                Menu {
                    Button("Anthropic") { selectedProvider = "anthropic" }
                    Button("OpenAI") { selectedProvider = "openai" }
                    Button("OpenRouter") { selectedProvider = "openrouter" }
                    Menu(L("更多...", "More...")) {
                        Button("Google") { selectedProvider = "google" }
                        Button("Groq") { selectedProvider = "groq" }
                        Button("Mistral") { selectedProvider = "mistral" }
                        Button("xAI") { selectedProvider = "xai" }
                        Button("Cerebras") { selectedProvider = "cerebras" }
                    }
                } label: {
                    HStack {
                        Text(providerDisplayName(selectedProvider))
                            .font(.system(size: 13))
                            .foregroundColor(.black)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.black.opacity(0.4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // API Key input
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)

                HStack(spacing: 8) {
                    SecureField("sk-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    Button(action: {
                        guard !apiKeyInput.isEmpty else { return }
                        openClawSetup.continueAfterAPIKey(provider: selectedProvider, apiKey: apiKeyInput)
                    }) {
                        Text(L("保存", "Save"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(apiKeyInput.isEmpty ? Color.black.opacity(0.3) : Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKeyInput.isEmpty)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "anthropic":   return "Anthropic"
        case "openai":      return "OpenAI"
        case "openrouter":  return "OpenRouter"
        case "google":      return "Google"
        case "groq":        return "Groq"
        case "mistral":     return "Mistral"
        case "xai":         return "xAI"
        case "cerebras":    return "Cerebras"
        default:            return provider
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
                if currentStep == .permissions && shouldOfferRelaunch {
                    relaunchApp()
                } else if currentStep == .openclawSetup {
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
            if permissions.allRequiredGranted {
                return L("下一步", "Next")
            } else if shouldOfferRelaunch {
                return L("退出并重新打开", "Quit & Reopen")
            } else {
                return L("请先开启权限", "Grant permissions first")
            }
        case .openclawSetup:
            if openClawSetup.allPhasesSucceeded {
                return L("开始使用", "Get Started")
            } else {
                return L("设置中...", "Setting up...")
            }
        }
    }

    private var isNextDisabled: Bool {
        if currentStep == .permissions && !permissions.allRequiredGranted && !shouldOfferRelaunch {
            return true
        }
        if currentStep == .openclawSetup && !openClawSetup.allPhasesSucceeded {
            return true
        }
        return false
    }

    // MARK: - Permission Relaunch Logic

    /// Whether we should offer a "Quit & Reopen" button instead of the disabled next button.
    private var shouldOfferRelaunch: Bool {
        !clickedPermissions.isEmpty
        && !permissions.allRequiredGranted
        && pollsSinceFirstClick >= 5
    }

    private func trackPermissionClick(_ key: String) {
        clickedPermissions.insert(key)
        pollsSinceFirstClick = 0
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                permissions.checkRequired()

                // Check screen recording only after user has clicked that row
                if clickedPermissions.contains("screenRecording") && permissions.screenRecording != .granted {
                    permissions.screenRecording = await PermissionChecker.isScreenRecordingGranted() ? .granted : .denied
                }

                // Remove granted permissions from clicked set
                if permissions.inputMonitoring == .granted { clickedPermissions.remove("inputMonitoring") }
                if permissions.accessibility == .granted { clickedPermissions.remove("accessibility") }

                // Increment poll counter when user has clicked but permissions still denied
                if !clickedPermissions.isEmpty && !permissions.allRequiredGranted {
                    pollsSinceFirstClick += 1
                }

                // Auto-stop polling when all permissions granted
                if permissions.allGranted {
                    stopPermissionPolling()
                }
            }
        }
    }

    private func stopPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
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
