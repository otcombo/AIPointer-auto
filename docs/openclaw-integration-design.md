# OpenClaw 集成设计文档

## 目标

AIPointer 作为 macOS 桌面客户端，需要连接 OpenClaw 后端。为降低用户门槛，App 应：
1. 检测本机是否已安装 OpenClaw
2. 在 Onboarding 中引导用户安装/配置
3. 提供 API Key 配置入口
4. 可选：随 App 启动/关闭 OpenClaw 进程

## 方案：轻量引导 + 终端安装

### 为什么不直接 bundle？

OpenClaw 依赖 Node.js 22+，运行时约 200-300MB。嵌入到 App Bundle 会：
- 大幅增加 App 体积
- 需要维护 Node.js 版本更新
- 增加沙箱复杂度

### 推荐方案

**阶段一（当前）：引导式安装**
- Onboarding 新增 "OpenClaw 设置" 步骤
- 检测 `openclaw` 命令是否存在（PATH 检查 + 常见路径）
- 未安装：显示一键安装命令，提供"打开终端"按钮
- 已安装：检测 Gateway 是否运行，提供启动按钮
- 引导用户配置 API Key（LLM provider）

**阶段二（未来）：自动管理**
- App 内嵌安装脚本，一键安装
- 随 App 启动自动启动 Gateway
- 随 App 退出自动停止 Gateway

## 实现计划

### 1. OpenClawSetupService（新文件）

```swift
// Services/OpenClawSetupService.swift
class OpenClawSetupService: ObservableObject {
    enum InstallStatus { case checking, installed, notInstalled, error(String) }
    enum GatewayStatus { case unknown, running, stopped, error(String) }
    
    @Published var installStatus: InstallStatus = .checking
    @Published var gatewayStatus: GatewayStatus = .unknown
    @Published var version: String?
    
    func checkInstallation()     // 执行 `which openclaw` 或检查常见路径
    func checkGatewayStatus()    // GET /api/status 或 `openclaw gateway status`
    func openTerminalWithInstall() // 打开 Terminal.app 执行安装命令
    func startGateway()          // 启动 Gateway 进程
}
```

### 2. Onboarding 改造

当前步骤：Welcome → Permissions → Configure → Ready

新步骤：Welcome → Permissions → **OpenClaw Setup** → Configure → Ready

OpenClaw Setup 页面：
- 自动检测安装状态
- 未安装：显示安装说明 + "打开终端安装" 按钮
- 已安装：显示版本 + Gateway 状态
- Gateway 未运行：提供 "启动" 按钮
- 可跳过（用户可能用远程 OpenClaw）

### 3. Settings 页面增强

在现有 OpenClaw section 增加：
- 连接状态指示器（绿/红点）
- "测试连接" 按钮
- API Key 配置入口（打开 OpenClaw 配置文件或终端）

## 文件变更清单

1. **新增** `Services/OpenClawSetupService.swift`
2. **修改** `Views/OnboardingView.swift` — 增加 OpenClaw Setup 步骤
3. **修改** `Views/SettingsView.swift` — 增加连接状态和测试按钮
