import SwiftUI
import AVKit

/// 首次启动引导流程 — Figma onboarding dialog 样式
struct OnboardingView: View {
    @StateObject private var permissions = PermissionChecker()
    @StateObject private var himalayaSetup = HimalayaSetupService()

    @State private var currentStep: Step = .fnKey
    @State private var pollTimer: Timer?
    @State private var clickedPermissions: Set<String> = []
    @State private var pollsSinceFirstClick = 0

    // API Key input state
    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var apiKeySaved: Bool = false

    // Himalaya email input state
    @State private var himalayaEmailInput: String = ""
    @State private var himalayaPasswordInput: String = ""
    @State private var isPresented = false

    var onComplete: () -> Void

    private func log(_ msg: String) { OnboardingLog.log("Onboarding", msg) }

    enum Step: Int, CaseIterable {
        case fnKey = 0
        case autoVerify = 1
        case permissions = 2
        case apiKeySetup = 3
    }

    private var showsIllustration: Bool {
        currentStep == .fnKey || currentStep == .autoVerify
    }

    private var videoURL: URL? {
        let name: String
        switch currentStep {
        case .fnKey:        name = "AIPointer-Feature-1"
        case .autoVerify:   name = "AIPointer-Feature-2"
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
                Spacer().frame(height: 14)
            }

            VStack(alignment: .leading, spacing: showsIllustration ? 8 : 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stepTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)

                    if let subtitle = stepSubtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.black.opacity(0.6))
                    }
                }

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
        .scaleEffect(isPresented ? 1.0 : 0.92)
        .opacity(isPresented ? 1.0 : 0.0)
        .padding(.horizontal, 60)  // (640 - 520) / 2 = 60
        .padding(.top, 44)          // shadow radius 32 + margin
        .padding(.bottom, 92)       // shadow radius 32 + y-offset 16 + margin
        .onAppear {
            log("view appeared, starting at step=\(currentStep)")
            // Load existing API key if any
            apiKeyInput = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
            baseURLInput = UserDefaults.standard.string(forKey: "anthropicBaseURL") ?? ""
            apiKeySaved = !apiKeyInput.isEmpty
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isPresented = true
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Step Title

    private var stepTitle: String {
        switch currentStep {
        case .fnKey:         return L("Fn 键，你的 AI 入口", "Fn Key, Your AI Gateway")
        case .autoVerify:    return L("验证码自动填充", "Auto-fill Verification Codes")
        case .permissions:   return L("系统权限", "System Permissions")
        case .apiKeySetup:   return L("AI 配置", "AI Configuration")
        }
    }

    private var stepSubtitle: String? {
        switch currentStep {
        case .permissions:
            return L("点击对应权限行打开系统设置页面，授权后自动检测。",
                     "Tap a row to open System Settings. Permissions are detected automatically.")
        case .apiKeySetup:
            return L("输入你的 Anthropic API Key 以启用 AI 功能。",
                     "Enter your Anthropic API Key to enable AI features.")
        default:
            return nil
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
        case .permissions:   permissionsContent
        case .apiKeySetup:   apiKeySetupContent
        }
    }

    // MARK: - Step 1: Fn Key

    private var fnKeyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(title: L("短按 Fn", "Tap Fn"),
                       desc: L("展开输入框，输入问题按 Enter 发送", "Open input, type your question and press Enter"))
            featureRow(title: L("长按 Fn", "Hold Fn"),
                       desc: L("框选屏幕区域作为图片上下文", "Select a screen region as image context"))
            featureRow(title: L("选中文字或文件后按 Fn", "Select text or files, then Fn"),
                       desc: L("自动捕获选中内容作为上下文", "Captured as context for your conversation"))
        }
    }

    // MARK: - Step 2: Auto Verify

    private var autoVerifyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(title: L("自动检测", "Auto Detect"),
                       desc: L("识别 OTP 输入框", "Detect OTP fields"))
            featureRow(title: L("邮件获取", "Email Fetch"),
                       desc: L("读取验证码", "Read verification codes"))
            featureRow(title: L("自动填入", "Auto Fill"),
                       desc: L("验证码就绪后自动填入", "Fill codes automatically"))

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(L("需要配置邮箱 IMAP（最后一步可设置）",
                       "Requires IMAP config (set up in last step)"))
                    .font(.system(size: 11))
            }
            .foregroundColor(.black.opacity(0.35))
            .padding(.top, 2)
        }
    }

    // MARK: - Step 3: Permissions

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                permissionRow(
                    icon: "keyboard",
                    title: L("输入监控", "Input Monitoring"),
                    subtitle: L("鼠标追踪、Fn 键监听、Cmd+C 检测",
                               "Mouse tracking, Fn key, Cmd+C detection"),
                    state: permissions.inputMonitoring, required: true,
                    action: {
                        trackPermissionClick("inputMonitoring")
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
                        // Check once to trigger the system prompt, then open settings
                        Task {
                            let granted = await PermissionChecker.isScreenRecordingGranted()
                            if !granted {
                                permissions.openScreenRecordingSettings()
                            } else {
                                permissions.screenRecording = .granted
                            }
                        }
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
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)
                    .foregroundColor(.black)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.black)
                        if required {
                            Text("*")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.red)
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
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 13)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(state == .granted ? Color.green.opacity(0.05) : Color.black.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: API Key + Himalaya Setup

    private var apiKeySetupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // API Key card
                apiKeyCard

                // Himalaya section (optional)
                if !himalayaSetup.isSkipped {
                    himalayaSection
                }
            }
        }
        .onAppear {
            // Start himalaya setup in background
            himalayaSetup.runFullSetup()
        }
    }

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)
                    .foregroundColor(.black)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Anthropic API Key")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)

                    Text(apiKeySaved
                         ? L("已配置", "Configured")
                         : L("需要 API Key 以使用 AI 功能", "Required for AI features"))
                        .font(.system(size: 11))
                        .foregroundColor(.black.opacity(0.4))
                }

                Spacer()

                if apiKeySaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 13)
            .frame(minHeight: 58)

            if !apiKeySaved {
                Rectangle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 10)

                VStack(alignment: .trailing, spacing: 12) {
                    HStack {
                        Text("API Key")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black)

                        Spacer()

                        SecureField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    HStack {
                        Text("Base URL")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black)

                        Spacer()

                        TextField("https://api.anthropic.com", text: $baseURLInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    Button(action: saveApiKey) {
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
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(apiKeySaved ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
        )
    }

    private func saveApiKey() {
        guard !apiKeyInput.isEmpty else { return }
        UserDefaults.standard.set(apiKeyInput, forKey: "anthropicAPIKey")
        UserDefaults.standard.set(baseURLInput, forKey: "anthropicBaseURL")
        apiKeySaved = true
        log("API key saved, baseURL=\(baseURLInput.isEmpty ? "(default)" : baseURLInput)")
    }

    // MARK: - Himalaya Section

    private var himalayaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Divider with label
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
                Text(L("邮件验证码自动填充（可选）", "Auto-fill Email OTP (Optional)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black.opacity(0.35))
                    .fixedSize()
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.top, 4)

            himalayaMailRow

            // Skip button
            if !himalayaSetup.isFinished {
                Button(action: { himalayaSetup.skip() }) {
                    Text(L("跳过", "Skip"))
                        .font(.system(size: 12))
                        .foregroundColor(.black.opacity(0.35))
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Combined himalaya row: install + email config in one card
    private var himalayaMailRow: some View {
        let installStatus = himalayaSetup.phaseStatuses[.install] ?? .pending
        let emailStatus = himalayaSetup.phaseStatuses[.email] ?? .pending

        // Derive combined status for background/icon
        let combinedStatus: HimalayaSetupService.PhaseStatus = {
            if case .failed = installStatus { return installStatus }
            if case .failed = emailStatus { return emailStatus }
            if case .succeeded = emailStatus { return emailStatus }
            if emailStatus == .needsInput { return emailStatus }
            if case .inProgress = emailStatus { return emailStatus }
            if case .inProgress = installStatus { return installStatus }
            if case .succeeded = installStatus { return installStatus }
            if case .skipped = installStatus { return installStatus }
            return .pending
        }()

        // Derive subtitle
        let subtitle: String? = {
            if case .failed(let text) = installStatus { return text }
            if case .failed(let text) = emailStatus { return text }
            if let sub = himalayaPhaseSubtitle(emailStatus) { return sub }
            if let sub = himalayaPhaseSubtitle(installStatus) { return sub }
            return L("从邮箱读取验证码并自动填入", "Reads OTP codes from email and auto-fills them")
        }()

        // Which phase to retry
        let retryPhase: HimalayaSetupService.SetupPhase = {
            if case .failed = installStatus { return .install }
            return .email
        }()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)
                    .foregroundColor(.black)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("配置邮箱", "Configure Mail"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.black.opacity(0.4))
                    }
                }

                Spacer()

                if case .failed = combinedStatus {
                    Button(action: { himalayaSetup.retrySetup(from: retryPhase) }) {
                        Text(L("重试", "Retry"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    himalayaPhaseStatusIcon(combinedStatus)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 13)
            .frame(minHeight: 58)

            if emailStatus == .needsInput {
                Rectangle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                himalayaEmailInputSection
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(himalayaPhaseRowBackground(combinedStatus))
        )
    }

    @ViewBuilder
    private func himalayaPhaseStatusIcon(_ status: HimalayaSetupService.PhaseStatus) -> some View {
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
        case .needsInput:
            Image(systemName: "envelope.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
        case .failed:
            EmptyView()
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.2))
        }
    }

    private func himalayaPhaseSubtitle(_ status: HimalayaSetupService.PhaseStatus) -> String? {
        switch status {
        case .inProgress(let text): return text
        case .succeeded(let text): return text.isEmpty ? nil : text
        case .failed(let text): return text
        case .needsInput: return L("需要输入邮箱和 App Password", "Email and App Password required")
        case .skipped: return L("已跳过", "Skipped")
        case .pending: return nil
        }
    }

    private func himalayaPhaseRowBackground(_ status: HimalayaSetupService.PhaseStatus) -> Color {
        switch status {
        case .succeeded: return Color.green.opacity(0.05)
        case .failed: return Color.red.opacity(0.05)
        case .needsInput: return Color.orange.opacity(0.05)
        case .skipped: return Color.black.opacity(0.02)
        default: return Color.black.opacity(0.03)
        }
    }

    private var himalayaEmailInputSection: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Email input
            HStack {
                Text(L("邮箱地址", "Email Address"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)

                Spacer()

                TextField("user@example.com", text: $himalayaEmailInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            // App Password input
            HStack {
                Text("App Password")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)

                Spacer()

                SecureField(L("应用专用密码", "App-specific password"), text: $himalayaPasswordInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            // Inline guidance + clickable link based on email domain
            if !himalayaEmailInput.isEmpty,
               let help = HimalayaSetupService.appPasswordHelp(for: himalayaEmailInput) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(help.guide)
                        .font(.system(size: 11))
                        .foregroundColor(.black.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: {
                        NSWorkspace.shared.open(help.url)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                            Text(L("打开设置页面", "Open settings page"))
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.blue.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Save button
            Button(action: {
                guard !himalayaEmailInput.isEmpty && !himalayaPasswordInput.isEmpty else { return }
                himalayaSetup.continueAfterEmail(email: himalayaEmailInput, appPassword: himalayaPasswordInput)
            }) {
                Text(L("保存", "Save"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        (himalayaEmailInput.isEmpty || himalayaPasswordInput.isEmpty)
                        ? Color.black.opacity(0.3) : Color.black
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(himalayaEmailInput.isEmpty || himalayaPasswordInput.isEmpty)
        }
    }

    // MARK: - Shared Components

    private func featureRow(title: String, desc: String) -> some View {
        HStack(spacing: 6) {
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
                        .foregroundColor(.black.opacity(0.25))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }

            onboardingButton(nextButtonTitle) {
                if currentStep == .permissions && shouldOfferRelaunch {
                    relaunchApp()
                } else if currentStep == .apiKeySetup {
                    log("onboarding completing (Get Started pressed)")
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                        isPresented = false
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        onComplete()
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if let next = Step(rawValue: currentStep.rawValue + 1) {
                            log("step \(currentStep) → \(next)")
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
        case .permissions:
            if permissions.allRequiredGranted {
                return L("继续", "Continue")
            } else if shouldOfferRelaunch {
                return L("退出并重新打开", "Quit & Reopen")
            } else {
                return L("请先开启权限", "Grant permissions first")
            }
        case .apiKeySetup:
            return L("开始使用", "Get Started")
        }
    }

    private var isNextDisabled: Bool {
        if currentStep == .permissions && !permissions.allRequiredGranted && !shouldOfferRelaunch {
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
        log("permission clicked: \(key)")
        clickedPermissions.insert(key)
        pollsSinceFirstClick = 0
    }

    private func relaunchApp() {
        log("relaunchApp from bundlePath=\(Bundle.main.bundlePath)")
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        permissions.checkRequired()
        log("Step[permissions] polling started, inputMonitoring=\(permissions.inputMonitoring), accessibility=\(permissions.accessibility), screenRecording=\(permissions.screenRecording)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                permissions.checkRequired()

                // Screen recording: only re-check if user clicked the row AND we haven't granted yet
                // Use CGPreflightScreenCaptureAccess (no prompt) instead of SCShareableContent (triggers prompt)
                if clickedPermissions.contains("screenRecording") && permissions.screenRecording != .granted {
                    if CGPreflightScreenCaptureAccess() {
                        permissions.screenRecording = .granted
                    }
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
