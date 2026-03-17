import SwiftUI
import Cocoa

/// Standalone permission repair window shown when required permissions are missing at startup.
/// Polls every second; auto-closes and calls `onReady` once all required permissions are granted.
struct PermissionRepairView: View {
    @StateObject private var permissions = PermissionChecker()
    @State private var pollTimer: Timer?
    @State private var clickedPermissions: Set<String> = []
    @State private var pollsSinceFirstClick = 0
    @State private var isPresented = false

    var onReady: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("系统权限需要更新", "Permissions Need Update"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)

                    Text(L("应用更新后需要重新授权。请点击下方权限行打开系统设置，关闭后重新开启。",
                           "Permissions need to be re-granted after an app update. Tap a row to open System Settings, toggle OFF then ON."))
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.6))
                }

                permissionsContent
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            footer
        }
        .padding(12)
        .frame(width: 520, height: 400)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 32, x: 0, y: 16)
        .scaleEffect(isPresented ? 1.0 : 0.92)
        .opacity(isPresented ? 1.0 : 0.0)
        .padding(.horizontal, 60)
        .padding(.top, 44)
        .padding(.bottom, 92)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isPresented = true
            }
            startPolling()
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Permissions Content

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
                        trackClick("inputMonitoring")
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
                        trackClick("accessibility")
                        permissions.requestAccessibility()
                        permissions.openAccessibilitySettings()
                    }
                )
            }

            HStack(spacing: 4) {
                Image(systemName: shouldOfferRelaunch ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 11))
                if shouldOfferRelaunch {
                    Text(L("如果权限仍无法识别，请在系统设置中删除 AI Pointer 后重新添加",
                           "If permissions are still not recognized, remove AI Pointer from Settings and re-add it"))
                        .font(.system(size: 11))
                } else {
                    Text(L("在系统设置中授权后会自动检测",
                           "Permissions are detected automatically after granting"))
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(shouldOfferRelaunch ? .orange : .black.opacity(0.35))
        }
    }

    // MARK: - Permission Row

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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            if shouldOfferRelaunch {
                Button(action: relaunchApp) {
                    Text(L("退出并重新打开", "Quit & Reopen"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 100, minHeight: 36)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Polling

    private func startPolling() {
        permissions.checkRequired()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                permissions.checkRequired()

                if permissions.inputMonitoring == .granted { clickedPermissions.remove("inputMonitoring") }
                if permissions.accessibility == .granted { clickedPermissions.remove("accessibility") }

                if !clickedPermissions.isEmpty && !permissions.allRequiredGranted {
                    pollsSinceFirstClick += 1
                }

                if permissions.allRequiredGranted {
                    pollTimer?.invalidate()
                    pollTimer = nil
                    // Small delay so user sees the green checkmarks
                    try? await Task.sleep(for: .milliseconds(600))
                    onReady()
                }
            }
        }
    }

    private func trackClick(_ key: String) {
        clickedPermissions.insert(key)
        pollsSinceFirstClick = 0
    }

    private var shouldOfferRelaunch: Bool {
        !clickedPermissions.isEmpty
        && !permissions.allRequiredGranted
        && pollsSinceFirstClick >= 8
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

