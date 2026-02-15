# AIPointer — 功能依赖管理模块技术规格（Capability Manager）

> **目的**：技术实现规格，供 Claude Code 按此实现代码。
>
> **项目路径**：`/Users/otcombo/Documents/Playgrounds/AIPointer`
>
> **日期**：2026-02-15

---

## 1. 功能目标

统一管理 AIPointer 所有功能所需的系统权限、外部依赖和浏览器扩展。

**核心原则**：
- **不在安装时一口气要所有权限** — 只在用户开启某功能时，检查该功能需要什么
- **功能驱动，按需引导** — 缺什么引导什么，不缺不问
- **统一状态管理** — 设置面板中一个地方能看到所有权限和依赖的状态
- **可扩展** — 新增功能只需注册依赖关系，引导流程自动复用

---

## 2. 架构总览

```
┌── AIPointer App ──────────────────────────────────────────────────┐
│                                                                    │
│  Capability (NEW)              ← 枚举：所有权限/依赖定义          │
│  Feature (NEW)                 ← 枚举：功能 → Capability 映射     │
│  CapabilityChecker (NEW)       ← 各 Capability 的状态检查逻辑     │
│  CapabilityManager (NEW)       ← 编排层：检查 + 引导 + 状态管理   │
│  CapabilitySetupView (NEW)     ← 按需引导弹窗 UI                 │
│                                                                    │
│  SettingsView (MODIFY)         ← 新增 Dependencies section        │
│  AIPointerApp.swift (MODIFY)   ← 启动时用 CapabilityManager       │
│                                   替代现有的零散权限检查            │
└────────────────────────────────────────────────────────────────────┘
```

### 改动清单

| 文件 | 动作 | 说明 |
|------|------|------|
| `Core/Capability.swift` | **NEW** | Capability 枚举 + 元信息 |
| `Core/Feature.swift` | **NEW** | Feature 枚举 + 依赖映射 |
| `Core/CapabilityChecker.swift` | **NEW** | 各 Capability 的检查/修复逻辑 |
| `Core/CapabilityManager.swift` | **NEW** | 编排层 |
| `Views/CapabilitySetupView.swift` | **NEW** | 引导弹窗 |
| `Views/SettingsView.swift` | **MODIFY** | 新增 Dependencies section |
| `AIPointerApp.swift` | **MODIFY** | 替代现有权限检查 |

---

## 3. Capability 定义

### 文件：`AIPointer/Core/Capability.swift`

```swift
import Foundation

/// AIPointer 所有的权限和外部依赖
enum Capability: String, CaseIterable, Identifiable {
    // 系统权限
    case accessibility          // 辅助功能
    case inputMonitoring        // 输入监听
    case screenRecording        // 屏幕录制
    
    // 外部依赖
    case openClaw               // OpenClaw Gateway
    case clawHub                // ClawHub CLI
    case himalaya               // Himalaya 邮件 CLI
    
    // 浏览器扩展
    case browserRelay           // OpenClaw Browser Relay Extension
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        case .screenRecording:  return "Screen Recording"
        case .openClaw:         return "OpenClaw Gateway"
        case .clawHub:          return "ClawHub CLI"
        case .himalaya:         return "Himalaya (Email)"
        case .browserRelay:     return "Browser Relay Extension"
        }
    }
    
    var description: String {
        switch self {
        case .accessibility:    return "Read window titles, UI elements, and Tab information"
        case .inputMonitoring:  return "Track mouse movement and keyboard events for pointer"
        case .screenRecording:  return "Capture screenshots for AI analysis"
        case .openClaw:         return "AI backend for conversations and behavior analysis"
        case .clawHub:          return "Search and install community skills"
        case .himalaya:         return "Read emails for auto-verification"
        case .browserRelay:     return "Allow AI to operate browser pages"
        }
    }
    
    var category: Category {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording:
            return .systemPermission
        case .openClaw, .clawHub, .himalaya:
            return .dependency
        case .browserRelay:
            return .browserExtension
        }
    }
    
    /// 该 Capability 的图标（SF Symbols 名称）
    var iconName: String {
        switch self {
        case .accessibility:    return "hand.point.up.braille"
        case .inputMonitoring:  return "keyboard"
        case .screenRecording:  return "rectangle.dashed.badge.record"
        case .openClaw:         return "server.rack"
        case .clawHub:          return "shippingbox"
        case .himalaya:         return "envelope"
        case .browserRelay:     return "globe"
        }
    }
    
    enum Category: String, CaseIterable {
        case systemPermission = "System Permissions"
        case dependency = "Dependencies"
        case browserExtension = "Browser Extensions"
    }
}
```

---

## 4. Feature 定义

### 文件：`AIPointer/Core/Feature.swift`

```swift
/// AIPointer 的功能模块，每个功能声明自己需要哪些 Capabilities
enum Feature: String, CaseIterable, Identifiable {
    case pointer               // 基础指针
    case aiChat                // AI 对话
    case screenshotAnalysis    // 截屏分析
    case behaviorSensing       // 高频操作检测
    case focusDetection        // 语义聚焦检测
    case skillSearch           // Skill 搜索推荐
    case autoVerify            // 自动验证码填入
    case browserControl        // 浏览器操作
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .pointer:             return "Pointer"
        case .aiChat:              return "AI Chat"
        case .screenshotAnalysis:  return "Screenshot Analysis"
        case .behaviorSensing:     return "Behavior Sensing"
        case .focusDetection:      return "Focus Detection"
        case .skillSearch:         return "Skill Search"
        case .autoVerify:          return "Auto-Verify"
        case .browserControl:      return "Browser Control"
        }
    }
    
    /// 该功能必须的 Capabilities
    var requiredCapabilities: [Capability] {
        switch self {
        case .pointer:             return [.accessibility, .inputMonitoring]
        case .aiChat:              return [.accessibility, .inputMonitoring, .openClaw]
        case .screenshotAnalysis:  return [.screenRecording, .openClaw]
        case .behaviorSensing:     return [.accessibility, .openClaw]
        case .focusDetection:      return [.accessibility, .openClaw]
        case .skillSearch:         return [.accessibility, .openClaw, .clawHub]
        case .autoVerify:          return [.accessibility, .openClaw, .himalaya]
        case .browserControl:      return [.openClaw, .browserRelay]
        }
    }
    
    /// 核心功能不能被关闭（启动时必须满足）
    var isCoreFeature: Bool {
        switch self {
        case .pointer: return true
        default:       return false
        }
    }
}
```

---

## 5. CapabilityChecker — 检查与修复

### 文件：`AIPointer/Core/CapabilityChecker.swift`

```swift
import Cocoa
import ApplicationServices

enum CapabilityStatus: Equatable {
    case granted           // 权限已授予 / 依赖已安装并可用
    case denied            // 权限被拒绝
    case notInstalled      // 依赖未安装
    case notRunning        // 服务未运行（如 OpenClaw）
    case unknown           // 无法确定
    
    var isReady: Bool { self == .granted }
    
    var displayLabel: String {
        switch self {
        case .granted:       return "Ready"
        case .denied:        return "Not granted"
        case .notInstalled:  return "Not installed"
        case .notRunning:    return "Not running"
        case .unknown:       return "Unknown"
        }
    }
    
    var iconName: String {
        switch self {
        case .granted:  return "checkmark.circle.fill"
        case .denied:   return "xmark.circle.fill"
        case .notInstalled: return "minus.circle.fill"
        case .notRunning:   return "exclamationmark.circle.fill"
        case .unknown:  return "questionmark.circle"
        }
    }
    
    var color: NSColor {
        switch self {
        case .granted:  return .systemGreen
        case .denied, .notInstalled, .notRunning: return .systemRed
        case .unknown:  return .systemGray
        }
    }
}

struct CapabilityChecker {
    
    // MARK: - Check
    
    static func check(_ capability: Capability) async -> CapabilityStatus {
        switch capability {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
            
        case .inputMonitoring:
            return EventTapManager.checkPermission() ? .granted : .denied
            
        case .screenRecording:
            return await ScreenRecordingPermission.isGranted() ? .granted : .denied
            
        case .openClaw:
            return await checkOpenClaw()
            
        case .clawHub:
            return checkCLI("clawhub")
            
        case .himalaya:
            return checkCLI("himalaya")
            
        case .browserRelay:
            return checkBrowserRelay()
        }
    }
    
    // MARK: - Resolve (引导用户修复)
    
    static func resolve(_ capability: Capability) {
        switch capability {
        case .accessibility:
            openSystemPrefs("Privacy_Accessibility")
            
        case .inputMonitoring:
            openSystemPrefs("Privacy_ListenEvent")
            
        case .screenRecording:
            openSystemPrefs("Privacy_ScreenCapture")
            
        case .openClaw:
            // 打开 OpenClaw 文档或尝试启动
            if let url = URL(string: "https://docs.openclaw.ai/getting-started") {
                NSWorkspace.shared.open(url)
            }
            
        case .clawHub:
            // 提示安装命令
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("npm install -g clawhub", forType: .string)
            // 实际 UI 中会显示安装指引
            
        case .himalaya:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install himalaya", forType: .string)
            
        case .browserRelay:
            if let url = URL(string: "https://chromewebstore.google.com/detail/openclaw-browser-relay") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private static func openSystemPrefs(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private static func checkCLI(_ name: String) -> CapabilityStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .granted : .notInstalled
        } catch {
            return .notInstalled
        }
    }
    
    private static func checkOpenClaw() async -> CapabilityStatus {
        // 尝试 ping OpenClaw Gateway
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return .notRunning }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return .granted
            }
            return .notRunning
        } catch {
            // 连接被拒 → 服务未运行
            return .notRunning
        }
    }
    
    private static func checkBrowserRelay() -> CapabilityStatus {
        // Browser Relay 的检查方式：
        // 检查 Chrome 扩展目录中是否有 OpenClaw Browser Relay
        // 这是一个简化的检查，实际可能需要更精确的方法
        let chromExtDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions")
        
        guard FileManager.default.fileExists(atPath: chromExtDir.path) else {
            return .unknown  // Chrome 未安装或路径不同
        }
        
        // 简化：如果无法确定，返回 unknown
        // 后续可以通过检查特定 extension ID 来精确判断
        return .unknown
    }
}
```

---

## 6. CapabilityManager — 编排层

### 文件：`AIPointer/Core/CapabilityManager.swift`

```swift
import Cocoa
import Combine

@MainActor
class CapabilityManager: ObservableObject {
    static let shared = CapabilityManager()
    
    /// 所有 Capability 的当前状态
    @Published var statuses: [Capability: CapabilityStatus] = [:]
    
    private init() {
        // 初始化时全部检查一次
        Task { await refreshAll() }
    }
    
    // MARK: - 状态检查
    
    /// 刷新所有 Capability 状态
    func refreshAll() async {
        for cap in Capability.allCases {
            statuses[cap] = await CapabilityChecker.check(cap)
        }
    }
    
    /// 刷新单个 Capability 状态
    func refresh(_ capability: Capability) async {
        statuses[capability] = await CapabilityChecker.check(capability)
    }
    
    /// 检查某个 Feature 的所有依赖是否就绪
    func isReady(for feature: Feature) -> Bool {
        feature.requiredCapabilities.allSatisfy { statuses[$0]?.isReady == true }
    }
    
    /// 获取某个 Feature 缺失的 Capabilities
    func missingCapabilities(for feature: Feature) -> [Capability] {
        feature.requiredCapabilities.filter { statuses[$0]?.isReady != true }
    }
    
    // MARK: - 功能开启时的检查与引导
    
    /// 用户开启某功能时调用。
    /// 返回 true = 所有依赖就绪，可以开启。
    /// 返回 false = 有缺失依赖，已弹出引导弹窗。
    func ensureReady(for feature: Feature) async -> Bool {
        // 先刷新相关的 Capabilities
        for cap in feature.requiredCapabilities {
            await refresh(cap)
        }
        
        let missing = missingCapabilities(for: feature)
        if missing.isEmpty { return true }
        
        // 弹出引导弹窗
        showSetupSheet(for: feature, missing: missing)
        return false
    }
    
    /// 弹出引导弹窗
    private func showSetupSheet(for feature: Feature, missing: [Capability]) {
        // 通过 NotificationCenter 通知 UI 层弹窗
        NotificationCenter.default.post(
            name: .capabilitySetupNeeded,
            object: nil,
            userInfo: [
                "feature": feature,
                "missing": missing
            ]
        )
    }
    
    // MARK: - 首次启动
    
    /// 首次启动时检查核心功能的依赖
    /// 返回所有核心功能缺失的 Capabilities
    func checkCoreFeatures() async -> [Capability] {
        var allMissing = Set<Capability>()
        
        for feature in Feature.allCases where feature.isCoreFeature {
            for cap in feature.requiredCapabilities {
                await refresh(cap)
                if statuses[cap]?.isReady != true {
                    allMissing.insert(cap)
                }
            }
        }
        
        return Array(allMissing).sorted(by: { $0.rawValue < $1.rawValue })
    }
}

extension Notification.Name {
    static let capabilitySetupNeeded = Notification.Name("capabilitySetupNeeded")
}
```

---

## 7. CapabilitySetupView — 引导弹窗

### 文件：`AIPointer/Views/CapabilitySetupView.swift`

```swift
import SwiftUI

struct CapabilitySetupView: View {
    let feature: Feature
    let missing: [Capability]
    let onDismiss: () -> Void
    
    @StateObject private var manager = CapabilityManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "gearshape.2")
                    .font(.title2)
                Text("\(feature.displayName) needs:")
                    .font(.headline)
            }
            
            // 依赖列表
            ForEach(feature.requiredCapabilities, id: \.self) { cap in
                let status = manager.statuses[cap] ?? .unknown
                
                HStack(spacing: 12) {
                    Image(systemName: status.iconName)
                        .foregroundColor(Color(status.color))
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cap.displayName)
                            .fontWeight(.medium)
                        Text(cap.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if status.isReady {
                        Text("Ready")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button(resolveButtonLabel(for: cap, status: status)) {
                            CapabilityChecker.resolve(cap)
                            // 延迟刷新状态
                            Task {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                await manager.refresh(cap)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Divider()
            
            // 底部按钮
            HStack {
                Button("Refresh") {
                    Task {
                        for cap in feature.requiredCapabilities {
                            await manager.refresh(cap)
                        }
                    }
                }
                
                Spacer()
                
                Button("Cancel") {
                    onDismiss()
                }
                
                Button("Continue") {
                    onDismiss()
                }
                .disabled(!manager.isReady(for: feature))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
    
    private func resolveButtonLabel(for cap: Capability, status: CapabilityStatus) -> String {
        switch cap.category {
        case .systemPermission: return "Open Settings"
        case .dependency:
            return status == .notRunning ? "Start" : "Install"
        case .browserExtension: return "Install Extension"
        }
    }
}
```

### 首次启动引导弹窗

```swift
struct WelcomeSetupView: View {
    let missingCapabilities: [Capability]
    let onContinue: () -> Void
    let onQuit: () -> Void
    
    @StateObject private var manager = CapabilityManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            // Logo + 欢迎
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Welcome to AI Pointer")
                .font(.title)
            
            Text("To get started, we need a few system permissions:")
                .foregroundColor(.secondary)
            
            // 只显示核心功能需要的权限
            VStack(alignment: .leading, spacing: 12) {
                ForEach(missingCapabilities, id: \.self) { cap in
                    let status = manager.statuses[cap] ?? .unknown
                    
                    HStack(spacing: 12) {
                        Image(systemName: status.iconName)
                            .foregroundColor(Color(status.color))
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cap.displayName)
                                .fontWeight(.medium)
                            Text(cap.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if !status.isReady {
                            Button("Grant") {
                                CapabilityChecker.resolve(cap)
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                                    await manager.refresh(cap)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            
            // 底部
            HStack {
                Button("Quit") { onQuit() }
                Spacer()
                Button("Refresh") {
                    Task { await manager.refreshAll() }
                }
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!missingCapabilities.allSatisfy { manager.statuses[$0]?.isReady == true })
            }
        }
        .padding(30)
        .frame(width: 460)
    }
}
```

---

## 8. SettingsView — Dependencies Section

### 文件：`Views/SettingsView.swift`（新增 Section）

```swift
Section("Dependencies") {
    let manager = CapabilityManager.shared
    
    ForEach(Capability.Category.allCases, id: \.self) { category in
        let capsInCategory = Capability.allCases.filter { $0.category == category }
        
        if !capsInCategory.isEmpty {
            Text(category.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            ForEach(capsInCategory) { cap in
                let status = manager.statuses[cap] ?? .unknown
                
                HStack(spacing: 8) {
                    Image(systemName: cap.iconName)
                        .frame(width: 20)
                        .foregroundColor(.secondary)
                    
                    Text(cap.displayName)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Image(systemName: status.iconName)
                            .foregroundColor(Color(status.color))
                            .font(.caption)
                        Text(status.displayLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if !status.isReady {
                        Button("Fix") {
                            CapabilityChecker.resolve(cap)
                            Task {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                await manager.refresh(cap)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }
    
    // 底部刷新按钮
    HStack {
        Spacer()
        Button("Refresh All") {
            Task { await manager.refreshAll() }
        }
        .font(.caption)
    }
}
```

**显示效果**：

```
Dependencies
  System Permissions
  🤚 Accessibility             ✅ Ready
  ⌨️ Input Monitoring           ✅ Ready
  🔴 Screen Recording          ❌ Not granted    [Fix]

  Dependencies
  🖥 OpenClaw Gateway           ✅ Ready
  📦 ClawHub CLI                ✅ Ready
  ✉️ Himalaya (Email)           ❌ Not installed  [Fix]

  Browser Extensions
  🌐 Browser Relay Extension    ❓ Unknown        [Fix]

                                        [Refresh All]
```

---

## 9. AIPointerApp.swift 改造

### 替代现有的 `checkPermissionsAndStart()`

**之前**：

```swift
private func checkPermissionsAndStart() {
    if EventTapManager.checkPermission() {
        startPointerSystem()
    } else {
        // 弹 alert...
        NSApp.terminate(nil)
    }
}
```

**之后**：

```swift
private func checkPermissionsAndStart() {
    Task {
        let manager = CapabilityManager.shared
        let coreMissing = await manager.checkCoreFeatures()
        
        if coreMissing.isEmpty {
            // 所有核心权限就绪
            startPointerSystem()
        } else {
            // 显示首次启动引导弹窗
            await MainActor.run {
                showWelcomeSetup(missing: coreMissing)
            }
        }
    }
}

private func showWelcomeSetup(missing: [Capability]) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.center()
    window.title = "AI Pointer Setup"
    window.contentView = NSHostingView(rootView: WelcomeSetupView(
        missingCapabilities: missing,
        onContinue: { [weak self] in
            window.close()
            self?.startPointerSystem()
        },
        onQuit: {
            NSApp.terminate(nil)
        }
    ))
    window.makeKeyAndOrderFront(nil)
}
```

### 功能开关集成

在用户通过 SettingsView 开启某功能时，调用 CapabilityManager：

```swift
// 示例：用户开启 Focus Detection
Toggle("Enable focus detection", isOn: Binding(
    get: { focusDetectionEnabled },
    set: { newValue in
        if newValue {
            Task {
                let ready = await CapabilityManager.shared.ensureReady(for: .focusDetection)
                if ready {
                    focusDetectionEnabled = true
                }
                // 如果 not ready，ensureReady 已弹出引导弹窗
                // 用户修复后可以再次尝试开启
            }
        } else {
            focusDetectionEnabled = false
        }
    }
))
```

**需要保护的功能开关**：

| Toggle | Feature |
|--------|---------|
| Enable behavior sensing | `.behaviorSensing` |
| Enable focus detection | `.focusDetection` |
| Enable auto-verify | `.autoVerify` |

**不需要保护的**：
- 灵敏度、冷却期等参数调整（功能本身已启用，只是调参）

---

## 10. CapabilitySetupView 弹窗触发

通过 `NotificationCenter` 监听 `.capabilitySetupNeeded`：

```swift
// 在 AIPointerApp.swift 或主 Window 中
.onReceive(NotificationCenter.default.publisher(for: .capabilitySetupNeeded)) { notification in
    guard let info = notification.userInfo,
          let feature = info["feature"] as? Feature,
          let missing = info["missing"] as? [Capability] else { return }
    
    showCapabilitySetupSheet(feature: feature, missing: missing)
}

private func showCapabilitySetupSheet(feature: Feature, missing: [Capability]) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.center()
    window.title = "\(feature.displayName) Setup"
    window.contentView = NSHostingView(rootView: CapabilitySetupView(
        feature: feature,
        missing: missing,
        onDismiss: { window.close() }
    ))
    window.makeKeyAndOrderFront(nil)
}
```

---

## 11. 降级策略

当某个 Capability 不可用时，受影响的功能应优雅降级而不是崩溃：

| 不可用的 Capability | 受影响的功能 | 降级行为 |
|-------------------|------------|---------|
| `.openClaw` | AI Chat、行为感知、聚焦检测 | 静默禁用 AI 相关功能，指针基础功能正常 |
| `.clawHub` | Skill 搜索推荐 | 不搜索社区 skills，只检查已安装 skills |
| `.himalaya` | Auto-Verify | 不读邮件，其他验证方式（OCR）正常 |
| `.screenRecording` | 截屏分析 | 用到时再提示，不影响其他功能 |
| `.browserRelay` | 浏览器操作 | 不操作浏览器，其他建议正常 |

**原则**：缺少非核心依赖时，功能降级但不报错。只有核心依赖（Accessibility、Input Monitoring）缺失时才阻止启动。

---

## 12. 扩展性

新增功能时只需：

1. 在 `Feature` 枚举中新增一个 case
2. 声明 `requiredCapabilities`
3. 在功能开关处调用 `CapabilityManager.ensureReady(for:)`

如果需要新的 Capability 类型：

1. 在 `Capability` 枚举中新增一个 case
2. 在 `CapabilityChecker` 中实现 `check()` 和 `resolve()`
3. 其他全部自动复用

---

## 13. 分工

### Claude Code 负责：
- [ ] 创建 `Core/Capability.swift`
- [ ] 创建 `Core/Feature.swift`
- [ ] 创建 `Core/CapabilityChecker.swift`
- [ ] 创建 `Core/CapabilityManager.swift`
- [ ] 创建 `Views/CapabilitySetupView.swift`（含 `WelcomeSetupView`）
- [ ] 修改 `Views/SettingsView.swift`（新增 Dependencies section）
- [ ] 修改 `AIPointerApp.swift`（替代现有权限检查逻辑）
- [ ] 迁移现有的 `ScreenRecordingPermission.swift` 逻辑到 `CapabilityChecker`
- [ ] 验证 `swift build` 编译通过

### Han（手动测试）：
- [ ] 首次启动：撤销 Accessibility 权限，重新启动 App → 验证引导弹窗出现
- [ ] 功能开启：关闭 OpenClaw，在 Settings 中开启 Focus Detection → 验证引导弹窗
- [ ] 设置面板：打开 Dependencies section → 验证状态显示正确
- [ ] Fix 按钮：点击各 Fix 按钮 → 验证跳转到正确的设置页面
- [ ] 降级：关闭 OpenClaw → 验证 AI 功能静默禁用，指针基础功能正常

---

## 14. 边界情况

| 场景 | 行为 |
|------|------|
| macOS 版本差异导致权限检查 API 不同 | CapabilityChecker 中按 `@available` 分支处理 |
| OpenClaw 在使用过程中崩溃 | 定期刷新状态（可在 heartbeat 中执行），检测到 notRunning 时静默降级 |
| 用户手动撤销已授予的权限 | 下次刷新状态时发现 denied，功能自动降级 |
| Chrome 未安装导致 Browser Relay 检查失败 | 返回 unknown，不影响其他功能 |
| clawhub/himalaya 安装后需要重启 App | Refresh All 按钮可以重新检测 |

---

_End of specification._