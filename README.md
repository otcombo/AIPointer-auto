# AIPointer

一个 macOS 桌面 AI 助手，以自定义指针的形式常驻屏幕。按 Fn 键即可展开输入框与 AI 对话，支持截图分析、选中文字/文件上下文捕获、验证码自动填充和行为感知主动建议。

## 功能概览

### 核心交互
- **自定义指针** — 泪滴形指针替代系统光标，跟随鼠标移动
- **Fn 短按** — 展开输入框，输入问题后 Enter 发送，AI 流式回复
- **Fn 长按（≥0.4s）** — 进入截图模式，框选屏幕区域作为图片上下文发送
- **选中文字/文件捕获** — 按 Fn 时自动抓取当前 app 选中的文字或 Finder 选中的文件路径，附加为上下文

### 验证码自动填充
- 检测到网页中的 OTP 输入框时，指针变为绿色监控状态
- 通过 IMAP 获取验证码后自动填入

### 行为感知建议
- 被动监控用户操作（点击、复制、应用切换等）
- 当检测到可能需要帮助的行为模式时，主动弹出 AI 建议
- 用户按 Fn 接受建议后进入带上下文的对话

### Skill 补全
- 输入 `/` 触发 skill 列表自动补全，选择后注入 skill 上下文

## 系统要求

- **macOS 15 (Sequoia)** 或更高版本
- **Xcode 26 beta** 或更高版本（包含 Swift 6.2 工具链）
- 无第三方 SPM 依赖，仅使用系统框架

### 构建依赖

| 依赖 | 最低版本 | 安装方式 |
|------|----------|----------|
| **Xcode** | 26 beta+ | [developer.apple.com/xcode](https://developer.apple.com/xcode/) |
| **Swift 工具链** | 6.2+ | 随 Xcode 26 自带，或通过 [swift.org/install](https://swift.org/install) 单独安装 |
| **macOS SDK** | 26+ | 随 Xcode 26 自带 |
| **Command Line Tools** | 与 Xcode 版本匹配 | `xcode-select --install` |

> Package.swift 中 `platforms: [.macOS(.v26)]`，需要 macOS 26 SDK 才能编译。如果使用独立 Swift 工具链，确保 `xcrun --show-sdk-path` 指向正确的 SDK。

### 使用的系统框架

- **SwiftUI** — UI 层
- **AppKit (Cocoa)** — NSPanel、NSStatusItem、NSEvent、CGEvent tap
- **ScreenCaptureKit** — 截图功能（SCScreenshotManager）
- **ApplicationServices** — 辅助功能 API（AXUIElement）
- **CoreGraphics** — 事件拦截、坐标系统

## 权限配置

首次启动前需要在 **系统设置 → 隐私与安全性** 中授予以下权限：

| 权限 | 用途 | 设置路径 |
|------|------|----------|
| **输入监控** | 追踪鼠标移动、监听 Fn 键和 Cmd+C | 隐私与安全性 → 输入监控 |
| **辅助功能** | 读取前台应用的选中文字、检测 OTP 输入框 | 隐私与安全性 → 辅助功能 |
| **屏幕录制** | 截图功能（Fn 长按框选区域） | 隐私与安全性 → 屏幕录制 |

> 如果未授予输入监控权限，应用无法启动核心功能。

## 后端配置

AIPointer 需要连接 OpenClaw 后端服务。

### 1. 配置文件

创建 `~/.openclaw/openclaw.json`：

```json
{
  "gateway": {
    "auth": {
      "token": "your_gateway_token"
    }
  },
  "models": {
    "providers": {
      "your_provider": {
        "baseUrl": "https://api.anthropic.com",
        "apiKey": "sk-ant-...",
        "models": [
          {
            "id": "claude-sonnet-4-5-20250514",
            "input": ["text", "image"]
          }
        ]
      }
    }
  }
}
```

### 2. 应用内设置

启动后点击菜单栏图标 → Settings：

- **Server URL** — OpenClaw 后端地址（默认 `http://localhost:18789`）
- **Agent ID** — 路由标识（默认 `main`）
- **Response Language** — 回复语言（zh-CN / en）

## 构建与运行

```bash
# 克隆仓库
git clone https://github.com/otcombo/AIPointer-auto.git
cd AIPointer-auto

# 构建
swift build

# 运行
swift run AIPointer
```

应用启动后以菜单栏图标形式运行（不会出现在 Dock 中）。

## 使用指南

### 基本对话

1. 移动鼠标到目标位置
2. **短按 Fn** — 指针展开为输入框
3. 输入问题，按 **Enter** 发送
4. AI 流式回复显示在面板中
5. 按 **Escape** 或再次按 **Fn** 关闭面板

### 带截图的对话

1. **长按 Fn（≥0.4s）** — 进入截图模式
2. 拖拽框选屏幕区域（可多次框选）
3. 按 **Enter** 确认选区，截图自动附加到输入框
4. 输入问题后发送

### 带选中内容的对话

1. 在任意应用中选中文字，或在 Finder 中选中文件
2. **短按 Fn** — 输入框上方自动显示捕获的选中内容
3. 输入问题后发送，选中内容作为上下文一并发送

### 行为感知

1. 在设置中确认"Enable behavior sensing"已开启
2. 正常使用电脑，系统会被动分析操作模式
3. 当检测到可辅助的场景时，指针附近弹出建议气泡
4. 按 **Fn** 接受建议并进入带上下文的对话
5. 气泡会在 10 秒后自动消失（可在设置中调整）

## 状态说明

| 状态 | 外观 | 说明 |
|------|------|------|
| Idle | 泪滴形小指针 | 默认状态，跟随鼠标 |
| Monitoring | 绿色圆点 | 检测到 OTP 输入框 |
| Code Ready | 显示验证码数字 | 验证码就绪，即将自动填入 |
| Suggestion | 脉冲圆点 | AI 行为建议待确认 |
| Input | 展开的输入框 | 用户输入中 |
| Thinking | 加载动画 | 等待 AI 回复 |
| Responding | 流式文字 | AI 正在回复 |
| Response | 完整回复面板 | 回复完成，可继续追问 |

## 项目结构

```
AIPointer/
├── AIPointerApp.swift              # 入口、AppDelegate、权限检查
├── Core/
│   ├── EventTapManager.swift       # CGEvent 事件监听（鼠标、键盘）
│   ├── OverlayPanel.swift          # NSPanel 覆盖层窗口
│   ├── CursorHider.swift           # 系统光标隐藏/恢复
│   └── ScreenshotOverlayWindow.swift
├── Services/
│   ├── OpenClawService.swift       # OpenClaw API 客户端（SSE 流式）
│   ├── SelectionContextCapture.swift # Fn 按下时捕获选中文字/文件
│   ├── VerificationService.swift   # OTP 检测与自动填充
│   ├── BehaviorSensingService.swift # 行为感知分析
│   ├── BehaviorMonitor.swift       # 用户操作信号采集
│   ├── BehaviorScorer.swift        # 行为评分算法
│   ├── FocusDetectionService.swift # 长期专注模式检测
│   └── AccessibilityMonitor.swift  # 辅助功能事件监听
├── ViewModels/
│   ├── PointerViewModel.swift      # 核心状态管理
│   └── ScreenshotViewModel.swift
├── Views/
│   ├── PointerRootView.swift       # 主 UI（指针、输入、回复）
│   ├── InputBar.swift              # 输入栏
│   ├── ResponseCard.swift          # 回复卡片（Markdown 渲染）
│   ├── SettingsView.swift          # 设置界面
│   └── ...                         # 各状态指示器组件
├── State/
│   └── PointerState.swift          # 状态枚举定义
└── Models/
    ├── ChatMessage.swift
    └── SelectedRegion.swift
```

## License

Private project.
