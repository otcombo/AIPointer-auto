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
    @Published var finderAutomation: PermissionState = .unknown

    /// 所有必要权限是否已授予（输入监控 + 辅助功能）
    var allRequiredGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    /// 所有权限（含可选）是否已授予
    var allGranted: Bool {
        allRequiredGranted && screenRecording == .granted && finderAutomation == .granted
    }

    /// 检查所有权限状态（含屏幕录制，会触发系统弹窗）
    func checkAll() async {
        checkRequired()
        screenRecording = await checkScreenRecording()
    }

    /// 只检查必需权限（不触发任何系统弹窗）
    func checkRequired() {
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    /// 请求输入监控权限（触发系统弹窗）
    /// macOS 26+ 需要实际尝试创建 event tap 才会在 Input Monitoring 列表中显示 app
    func requestInputMonitoring() {
        CGRequestListenEventAccess()
        // Attempt to create an event tap so macOS registers this app in Input Monitoring list
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        if let tap { CFMachPortInvalidate(tap) }
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

    // MARK: - Finder Automation (Apple Events)

    /// 请求 Finder 自动化权限 — 执行最小 AppleScript 触发系统弹窗
    /// macOS 没有预请求 API，只能通过实际发送 Apple Event 触发
    func requestFinderAutomation() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Finder\" to get name of front window"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let granted = task.terminationStatus == 0
                DispatchQueue.main.async {
                    self?.finderAutomation = granted ? .granted : .denied
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finderAutomation = .denied
                }
            }
        }
    }

    /// 检查 Finder 自动化权限（通过尝试执行最小命令）
    func checkFinderAutomation() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Finder\" to get name of front window"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let granted = task.terminationStatus == 0
                DispatchQueue.main.async {
                    self?.finderAutomation = granted ? .granted : .denied
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finderAutomation = .denied
                }
            }
        }
    }

    /// 打开自动化设置页
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording (shared logic)

    /// Shared screen recording check — used by both PermissionChecker and ScreenRecordingPermission.
    static func isScreenRecordingGranted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    private func checkScreenRecording() async -> PermissionState {
        await Self.isScreenRecordingGranted() ? .granted : .denied
    }
}
