# AIPointer

一个 macOS 桌面 AI 助手，以自定义指针的形式常驻屏幕。按 Fn 键即可展开输入框与 AI 对话，支持截图分析、选中文字/文件上下文捕获、验证码自动填充。

## 功能概览

### 核心交互
- **自定义指针** — 泪滴形指针替代系统光标，跟随鼠标移动
- **Fn 短按** — 展开输入框，输入问题后 Enter 发送，AI 流式回复
- **Fn 长按（≥0.4s）** — 进入截图模式，框选屏幕区域作为图片上下文发送
- **选中文字/文件捕获** — 按 Fn 时自动抓取当前 app 选中的文字或 Finder 选中的文件路径，附加为上下文

### 验证码自动填充
- 自动检测浏览器中的 OTP 输入框（支持 Chrome、Safari、Firefox 等）
- 检测到时指针变为绿色监控状态
- 通过 IMAP 邮件或系统通知获取验证码后自动填入
- 检测策略：字段属性（autocomplete、id/name/class）→ placeholder/label 文字 → 多信号评分
- 已知限制：自定义 div 实现的 OTP 输入框（如 Substack）无法通过 AX API 检测，详见 [docs/otp-detection-limitations.md](docs/otp-detection-limitations.md)

## 系统要求

- **macOS 26** 或更高版本
- **Xcode 26 beta** 或更高版本（包含 Swift 6.2 工具链）
- 零第三方依赖，仅使用系统框架

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

## 后端配置

AIPointer 直接调用 Anthropic Messages API（`/v1/messages` SSE），无需中间网关。

启动后通过首次引导或菜单栏 → Settings 配置 **Anthropic API Key**。密钥存储在 UserDefaults 中。

## 构建与运行

```bash
# 克隆仓库
git clone https://github.com/otcombo/AIPointer-auto.git
cd AIPointer-auto

# 构建
swift build

# 运行（需要输入监控权限）
swift run AIPointer

# Release 构建
swift build -c release
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

## 状态说明

| 状态 | 外观 | 说明 |
|------|------|------|
| Idle | 泪滴形小指针 | 默认状态，跟随鼠标 |
| Monitoring | 绿色圆点 | 检测到 OTP 输入框 |
| Code Ready | 显示验证码数字 | 验证码就绪，即将自动填入 |
| Input | 展开的输入框 | 用户输入中 |
| Thinking | 加载动画 | 等待 AI 回复 |
| Responding | 流式文字 | AI 正在回复 |
| Response | 完整回复面板 | 回复完成，可继续追问 |

## 项目结构

```
AIPointer/
├── AIPointerApp.swift              # 入口、AppDelegate、权限检查
├── Core/
│   ├── EventTapManager.swift       # CGEvent 事件监听（鼠标、键盘、Fn）
│   ├── OverlayPanel.swift          # NSPanel 覆盖层窗口
│   ├── CursorHider.swift           # 系统光标隐藏/恢复
│   └── ScreenshotOverlayWindow.swift
├── Services/
│   ├── OpenClawService.swift       # Anthropic Messages API 客户端（SSE 流式）
│   ├── SelectionContextCapture.swift # Fn 按下时捕获选中文字/文件
│   ├── VerificationService.swift   # OTP 检测与自动填充编排
│   ├── OTPFieldDetector.swift      # OTP 字段识别（多信号评分）
│   ├── AccessibilityMonitor.swift  # 浏览器焦点元素监听
│   ├── CodeSourceMonitor.swift     # 验证码来源（IMAP 邮件 + 通知）
│   └── UpdateService.swift         # GitHub Releases 自动更新
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
└── docs/
    └── otp-detection-limitations.md # OTP 检测已知限制
```

## License

Private project.
