import Cocoa
import ScreenCaptureKit

/// 统一管理三个系统权限的检查和请求
@MainActor
class PermissionChecker: ObservableObject {
    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    @Published var inputMonitoring: PermissionState = .unknown
    @Published var accessibility: PermissionState = .unknown
    @Published var screenRecording: PermissionState = .unknown

    /// 所有必要权限是否已授予（输入监控 + 辅助功能）
    var allRequiredGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    /// 所有权限（含可选）是否已授予
    var allGranted: Bool {
        allRequiredGranted && screenRecording == .granted
    }

    /// 检查所有权限状态
    func checkAll() async {
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        screenRecording = await checkScreenRecording()
    }

    /// 请求输入监控权限（触发系统弹窗）
    func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    /// 请求辅助功能权限（触发系统弹窗）
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 打开输入监控设置页
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开辅助功能设置页
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开屏幕录制设置页
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func checkScreenRecording() async -> PermissionState {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .granted
        } catch {
            return .denied
        }
    }
}
