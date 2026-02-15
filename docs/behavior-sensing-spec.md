# AIPointer — 行为感知技术规格

> **目的**：技术实现规格，供 Claude Code 按此实现代码。
>
> **前置文档**：`docs/behavior-sensing-design.md`（设计方案，已确认）
>
> **项目路径**：`/Users/otcombo/Documents/Playgrounds/AIPointer`
>
> **日期**：2026-02-14

---

## 1. 架构总览

```
┌── AIPointer App ──────────────────────────────────────────┐
│                                                            │
│  BehaviorBuffer (NEW)         ← 环形缓冲区，存储行为事件   │
│  BehaviorScorer (NEW)         ← 评分系统，滑动窗口打分     │
│  BehaviorMonitor (NEW)        ← 采集层，监听各种信号源     │
│  BehaviorSensingService (NEW) ← 编排层，串联整个流程       │
│                                                            │
│  AccessibilityMonitor (EXIST) ← 已有，供行为感知复用       │
│  OpenClawService (EXIST)      ← 已有 executeCommand()     │
│  PointerViewModel (MODIFY)    ← 新增行为感知状态           │
│  PointerState (MODIFY)        ← 新增 .suggestion 状态     │
│  SettingsView (MODIFY)        ← 新增灵敏度调节             │
│  AppDelegate (MODIFY)         ← 接线 BehaviorSensingService│
└────────────────────────────────────────────────────────────┘
```

### 改动清单

| 文件 | 动作 | 说明 |
|------|------|------|
| `Services/BehaviorBuffer.swift` | **NEW** | 环形缓冲区 |
| `Services/BehaviorScorer.swift` | **NEW** | 评分系统 |
| `Services/BehaviorMonitor.swift` | **NEW** | 信号采集 |
| `Services/BehaviorSensingService.swift` | **NEW** | 编排层 |
| `State/PointerState.swift` | **MODIFY** | 新增 `.suggestion` 状态 |
| `ViewModels/PointerViewModel.swift` | **MODIFY** | 处理 suggestion 状态 + Fn 交互 |
| `Views/SettingsView.swift` | **MODIFY** | 新增灵敏度滑块 |
| `AIPointerApp.swift` (AppDelegate) | **MODIFY** | 接线 BehaviorSensingService |

---

## 2. BehaviorBuffer — 环形缓冲区

### 文件：`AIPointer/Services/BehaviorBuffer.swift`

**职责**：内存中保留最近 5 分钟的行为事件，最多 200 条。

**事件类型**：

```swift
enum BehaviorEventKind: String {
    case appSwitch       // 应用切换，detail = "Excel → Chrome"
    case windowTitle     // 窗口标题变化，detail = 标题文本
    case clipboard       // 剪贴板变化，detail = 内容前 200 字符（密码用 [REDACTED]）
    case click           // 鼠标点击，detail = 应用名，context = AX 元素描述
    case dwell           // 鼠标悬停 >1.5s，detail = 应用名，context = AX 元素描述
    case copy            // Cmd+C，detail = 应用名，context = 焦点元素的 AX 描述
    case tabSwitch       // 浏览器 tab 切换（窗口标题变化但应用未切换，且应用是 Chrome 系）
    case fileOp          // Finder 文件操作
}

struct BehaviorEvent {
    let timestamp: Date
    let kind: BehaviorEventKind
    let detail: String
    let context: String?    // AX 上下文，可选
}
```

**接口**：
- `append(_ event:)` — 追加事件，自动淘汰超龄/超量
- `snapshot(lastSeconds:)` — 获取最近 N 秒的事件数组
- `recentClipboards(count:)` — 获取最近 N 次剪贴板内容的 detail 字符串数组

**约束**：
- `maxEvents = 200`
- `maxAge = 300`（5 分钟）
- 纯内存，不写磁盘

---

## 3. BehaviorScorer — 评分系统

### 文件：`AIPointer/Services/BehaviorScorer.swift`

**职责**：基于 2 分钟滑动窗口，计算忙碌分数。

**评分规则**：

| 信号 | 条件 | 分数 | 判定逻辑 |
|------|------|------|---------|
| 跨应用高频切换 | 同一对应用来回切换 ≥3 次（即该对出现 ≥3 次连续切换） | +3 | 统计 appSwitch 事件中应用对的出现次数 |
| 剪贴板高频变化 | clipboard 事件 ≥4 次 | +3 | 计数 |
| 剪贴板内容结构相似 | 最近 4 次剪贴板：长度一致性 + 字符类型一致性都通过 | +2 | 见下方详述 |
| 同应用长时间停留 + 低产出 | 3 分钟内无 appSwitch，但 dwell/click ≥10 次 | +2 | 计数 |
| 浏览器多 tab 切换 | tabSwitch 事件 ≥5 次 | +2 | 计数 |
| Finder 连续文件操作 | fileOp 事件 ≥5 次 | +2 | 计数 |

**触发阈值**：`baseThreshold = 5`

**灵敏度**：
- 通过 `sensitivity` 属性调节（0.5 ~ 2.0，默认 1.0）
- 实际阈值 = `max(2, round(baseThreshold / sensitivity))`
- 灵敏度 0.5 → 阈值 10（不敏感），灵敏度 2.0 → 阈值 3（非常敏感）

**剪贴板结构相似判断**：

取最近 4 条剪贴板内容：

1. **长度一致性**：最长 / 最短 ≤ 3 倍
2. **字符类型一致性**：
   - 每条内容分类为 `chinese` / `english` / `numeric` / `mixed`
   - 分类规则：按 unicode 统计中文字符、ASCII 字母、数字（含 ¥$€%.）的占比，>50% 的类型为该类，否则 mixed
   - ≥3 条类型相同 → 通过

两个检查都通过 → +2 分。只通过一个 → 不加分。

---

## 4. BehaviorMonitor — 信号采集

### 文件：`AIPointer/Services/BehaviorMonitor.swift`

**职责**：监听系统事件，写入 BehaviorBuffer。

### 信号源

**4.1 应用切换**
- 来源：`NSWorkspace.didActivateApplicationNotification`
- 写入：`appSwitch`，detail = `"AppA → AppB"`
- 同时触发窗口标题采集

**4.2 窗口标题**
- 来源：应用切换时主动采集（`AXFocusedWindow` → `AXTitle`）
- 写入：`windowTitle`，detail = 标题文本
- 判断是否为浏览器 tab 切换：如果应用没变（仍是 Chrome 系）但标题变了，额外写入 `tabSwitch`

**4.3 剪贴板**
- 来源：每 1 秒轮询 `NSPasteboard.general.changeCount`
- 写入：`clipboard`，detail = 内容前 200 字符
- 密码检测：长度 8-64、无空格、含大小写+数字+特殊字符中 ≥3 类 → 记为 `[REDACTED]`

**4.4 鼠标悬停（Dwell）**
- 来源：每 0.5 秒检查鼠标位置，连续 3 帧（1.5s）位移 <5px → 判定为悬停
- 触发：`AXUIElementCopyElementAtPosition` 采样该位置元素
- 写入：`dwell`，detail = 当前应用名，context = AX 元素描述
- 每次悬停只采样一次（mouseStillFrames == 阈值时触发，之后不重复）

**4.5 点击**
- 来源：外部调用 `recordClick(at:)`（由 EventTapManager 的 mouseDown 事件触发）
- 触发：`AXUIElementCopyElementAtPosition` 采样点击位置
- 写入：`click`，detail = 当前应用名，context = AX 元素描述

**4.6 复制（Cmd+C）**
- 来源：外部调用 `recordCopy()`（由 EventTapManager 的 keyDown 事件检测 Cmd+C）
- 触发：采样当前焦点元素（`AXFocusedUIElement`）
- 写入：`copy`，detail = 当前应用名，context = 焦点元素 AX 描述

### AX 元素描述格式

将 AX 元素压缩为单行文本：

```
role=AXCell, value="¥2,450,000", title="金额", parent=AXRow, parentTitle="上海分公司"
```

读取的属性：
- `AXRole`
- `AXValue`（前 100 字符）
- `AXTitle`
- `AXPlaceholderValue`
- `AXDescription`
- `AXParent` → 其 `AXRole` 和 `AXTitle`

### EventTapManager 需要新增的回调

`EventTapManager` 已有 `onMouseMoved`、`onFnShortPress`、`onFnLongPress`。需要新增：

```swift
var onMouseDown: ((CGPoint) -> Void)?   // 鼠标点击位置
var onCmdC: (() -> Void)?               // Cmd+C 按键
```

在 EventTapManager 的事件处理中：
- `kCGEventLeftMouseDown` → 调用 `onMouseDown?(event.location)`
- `kCGEventKeyDown` + 检测 Cmd+C（keyCode 8 + command flag）→ 调用 `onCmdC?()`

---

## 5. BehaviorSensingService — 编排层

### 文件：`AIPointer/Services/BehaviorSensingService.swift`

**职责**：定期检查分数，触发时调用 OpenClaw 分析，派发结果。

### 流程

```
每 2 秒：
├── 从 buffer 取最近 2 分钟事件
├── 调用 scorer 计算分数
├── 分数 < 阈值 → 什么都不做
└── 分数 ≥ 阈值 且 isAnalyzing == false →
    ├── isAnalyzing = true
    ├── 从 buffer 取最近 3 分钟事件
    ├── 压缩成文本（最多 30 条事件）
    ├── 构建 prompt，调用 OpenClawService.executeCommand()
    ├── 解析 JSON 响应
    ├── isAnalyzing = false
    └── confidence != low → 调用 onAnalysisResult 回调
```

### Prompt 格式

```
[BEHAVIOR-ASSIST] 以下是用户最近的操作记录。请分析用户在做什么，判断你是否能帮上忙。

--- 操作记录 ---
03:05:01 appSwitch: Excel → Chrome
03:05:03 windowTitle: 飞书文档 - 销售报表
03:05:05 clipboard: 上海分公司
03:05:05 copy: Chrome [role=AXTextField, placeholder="输入内容"]
03:05:08 appSwitch: Chrome → Excel
03:05:09 dwell: Excel [role=AXCell, value="深圳分公司", parent=AXRow]
03:05:12 clipboard: 深圳分公司
...

--- 你的能力 ---
你可以：读写文件、运行脚本（Python/Node/Shell）、操作浏览器（Chromium系）、读邮件、发消息、提取网页内容、搜索网页。

--- 响应格式（严格 JSON，不要任何其他文字）---
高置信度：{"confidence":"high","observation":"你观察到了什么","suggestion":"你能怎么帮忙"}
中置信度：{"confidence":"medium","observation":"你观察到了什么","suggestion":null}
低置信度：{"confidence":"low","observation":"","suggestion":null}
```

**事件压缩规则**：
- 取最近 3 分钟，最多 30 条
- 时间格式 `HH:mm:ss`
- 有 context 的事件在末尾加 `[context内容]`

### 响应解析

1. 正则提取 JSON：`\{[^{}]*"confidence"[^{}]*\}`
2. 解析 `confidence`、`observation`、`suggestion` 字段
3. 解析失败 → 返回 `confidence: .low`

### OpenClaw Agent

`executeCommand()` 的 agent ID 应使用 `aipointer`（独立 agent，已在 OpenClaw 中配置）。

当前 `executeCommand()` 读取 `UserDefaults` 的 `agentId`。行为感知请求需要**强制使用 `aipointer` agent**，不受 Settings 中 agent ID 配置影响。

两种实现方式（Claude Code 选其一）：
- A. 给 `executeCommand()` 加一个 `agentId` 参数，默认 nil 时读 UserDefaults
- B. 新增一个 `executeCommandForAgent(_ agentId: String, prompt: String)` 方法

---

## 6. PointerState — 新增状态

### 文件：`AIPointer/State/PointerState.swift`

新增：

```swift
case suggestion(observation: String, suggestion: String?)
// observation: AI 的观察（高/中置信度都有）
// suggestion: AI 的建议（仅高置信度有值）
```

`isFixed` 处理：`suggestion` 应为 `false`（指针跟随鼠标，不固定面板）。

---

## 7. PointerViewModel — 处理 suggestion

### 文件：`AIPointer/ViewModels/PointerViewModel.swift`

**新增方法**：

```swift
/// 由 BehaviorSensingService 调用
func updateBehaviorSuggestion(_ analysis: BehaviorAnalysis) {
    // 只在 idle 或 monitoring 状态下显示 suggestion
    switch state {
    case .idle, .monitoring:
        if analysis.confidence == .high || analysis.confidence == .medium {
            state = .suggestion(
                observation: analysis.observation,
                suggestion: analysis.suggestion
            )
            onStateChanged?(state)

            // 4 秒后自动消失
            suggestionDismissTimer?.invalidate()
            suggestionDismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    if case .suggestion = self?.state {
                        self?.state = .idle
                        self?.onStateChanged?(.idle)
                    }
                }
            }
        }
    default:
        break  // 不打断活跃的聊天状态
    }
}
```

需要新增属性：
```swift
private var suggestionDismissTimer: Timer?
private var pendingBehaviorContext: String?  // 暂存行为上下文，Fn 触发时预填
```

**修改 `onFnPress()`**：

```swift
func onFnPress() {
    switch state {
    case .suggestion(let observation, let suggestion):
        // 用户在 suggestion 状态下按 Fn → 打开对话面板，预填内容
        suggestionDismissTimer?.invalidate()
        state = .input
        if let suggestion {
            // 高置信度：预填 AI 的建议作为系统消息的上下文
            pendingBehaviorContext = "[行为感知] \(observation)\n建议：\(suggestion)"
        } else {
            // 中置信度：预填观察，等用户输入
            pendingBehaviorContext = "[行为感知] \(observation)"
        }
        inputText = ""
        onStateChanged?(state)

    case .idle, .monitoring, .codeReady:
        pendingBehaviorContext = nil
        state = .input
        inputText = ""
        attachedImages = []
        onStateChanged?(state)

    default:
        dismiss()
    }
}
```

**修改 `send()`**：

如果 `pendingBehaviorContext` 有值，在发送消息时把它作为上下文前缀拼到消息里：

```swift
var messageText = text.isEmpty && hasImages ? "请帮我看看这些截图" : text

if let behaviorContext = pendingBehaviorContext {
    messageText = "\(behaviorContext)\n\n用户补充：\(messageText)"
    pendingBehaviorContext = nil
}
```

如果是高置信度场景，用户可能不输入任何文本直接发送（表示确认）。此时 messageText 应为行为上下文本身：

```swift
if text.isEmpty && !hasImages {
    if let behaviorContext = pendingBehaviorContext {
        messageText = behaviorContext
        pendingBehaviorContext = nil
    } else {
        return  // 没文本没图片也没上下文，不发送
    }
}
```

---

## 8. UI 变更

### 8.1 指针视觉 — suggestion 状态

suggestion 状态显示一个 `sparkles.2` SF Symbol 图标，带渐变色和弹跳动画。

**SuggestionIndicator.swift**（新建）：

```swift
import SwiftUI

struct SuggestionIndicator: View {
    @State private var animate = false
    
    var body: some View {
        Image(systemName: "sparkles.2")
            .font(.system(size: 14, weight: .black))
            .rotationEffect(.degrees(90))
            .foregroundStyle(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 1.0, green: 0.75, blue: 0.0),  // #FFBC00
                        .white
                    ]),
                    startPoint: UnitPoint(x: 0.18, y: 0.82),      // 226deg, 18.58%
                    endPoint: UnitPoint(x: 0.69, y: 0.31)          // 226deg, 69.05%
                )
            )
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: animate)
            .onAppear {
                animate = true
            }
    }
}
```

- 4 秒后自动消失（由 PointerViewModel 的 `suggestionDismissTimer` 控制）
- 弹跳动画在出现时触发一次（`.nonRepeating`）

### 8.2 对话面板 — 预填内容

当从 suggestion 状态按 Fn 进入 input 状态时，对话面板应显示预填的行为上下文。

实现方式：
- 在 `InputBar` 或 `PointerRootView` 中检测 `pendingBehaviorContext` 是否有值
- 如果有值，在输入框上方显示一个上下文条（类似引用回复的样式），展示 observation 和 suggestion
- 用户可以直接发送（确认建议）或输入补充文字

### 8.3 SettingsView — 灵敏度滑块

```swift
Section("Behavior Sensing") {
    Toggle("Enable behavior sensing", isOn: $behaviorSensingEnabled)

    if behaviorSensingEnabled {
        HStack {
            Text("Sensitivity")
            Slider(value: $behaviorSensitivity, in: 0.5...2.0, step: 0.1)
            Text(String(format: "%.1f", behaviorSensitivity))
                .monospacedDigit()
        }
        Text("Higher = more frequent suggestions. Default: 1.0")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
```

新增 AppStorage 键：
- `@AppStorage("behaviorSensingEnabled") var behaviorSensingEnabled = true`
- `@AppStorage("behaviorSensitivity") var behaviorSensitivity = 1.0`

---

## 9. AppDelegate 接线

在 `startPointerSystem()` 中：

```swift
// Behavior sensing service
behaviorSensingService = BehaviorSensingService()
behaviorSensingService.openClawService = openClawService
behaviorSensingService.onAnalysisResult = { [weak self] analysis in
    self?.viewModel.updateBehaviorSuggestion(analysis)
}

// Connect EventTapManager callbacks for behavior monitoring
eventTapManager.onMouseDown = { [weak self] point in
    self?.behaviorSensingService.monitor.recordClick(at: point)
}
eventTapManager.onCmdC = { [weak self] in
    self?.behaviorSensingService.monitor.recordCopy()
}

// Apply settings
if UserDefaults.standard.bool(forKey: "behaviorSensingEnabled") {
    behaviorSensingService.sensitivity = UserDefaults.standard.double(forKey: "behaviorSensitivity")
    behaviorSensingService.start()
}
```

在 `applySettings()` 中响应设置变化：

```swift
let sensingEnabled = UserDefaults.standard.object(forKey: "behaviorSensingEnabled") as? Bool ?? true
if sensingEnabled {
    behaviorSensingService.sensitivity = UserDefaults.standard.double(forKey: "behaviorSensitivity")
    if !behaviorSensingService.isRunning { behaviorSensingService.start() }
} else {
    behaviorSensingService.stop()
}
```

---

## 10. 分工

### Claude Code 负责：
- [ ] 创建 `BehaviorBuffer.swift`
- [ ] 创建 `BehaviorScorer.swift`（含剪贴板结构相似判断）
- [ ] 创建 `BehaviorMonitor.swift`（含 AX 采样）
- [ ] 创建 `BehaviorSensingService.swift`（含 prompt 构建和响应解析）
- [ ] 修改 `PointerState.swift`（新增 `.suggestion`）
- [ ] 修改 `PointerViewModel.swift`（suggestion 处理、Fn 交互、预填逻辑）
- [ ] 修改 `SettingsView.swift`（灵敏度设置）
- [ ] 修改 `AIPointerApp.swift` AppDelegate（接线）
- [ ] 修改 `EventTapManager.swift`（新增 onMouseDown / onCmdC 回调）
- [ ] 创建 suggestion 状态的指针视觉组件
- [ ] 验证 `swift build` 编译通过

### Friday（OpenClaw）负责：
- [x] aipointer agent 已创建并配置
- [x] SOUL.md 已写好（调皮简短风格）
- [ ] 验证 aipointer agent 响应 `[BEHAVIOR-ASSIST]` prompt 格式正确
- [ ] 验证 JSON 响应格式符合规格

### Han（手动测试）：
- [ ] 运行 App，在 Excel 和 Chrome 之间反复复制粘贴
- [ ] 验证指针出现 suggestion 提示
- [ ] 按 Fn 验证对话面板预填内容
- [ ] 测试灵敏度调节是否生效

---

## 11. 边界情况

| 场景 | 行为 |
|------|------|
| OpenClaw 未运行 | executeCommand 连接被拒 → 静默失败，isAnalyzing 重置 |
| OpenClaw 返回非 JSON | fallback 到 confidence: low，不显示提示 |
| 正在聊天时分数达标 | isAnalyzing 检查仍触发分析，但 updateBehaviorSuggestion 检查当前 state 不是 idle → 不显示 |
| 提示显示中用户切换了应用 | 提示 4 秒后自动消失 |
| 灵敏度设为最低 | 阈值变为 10，只有非常明显的重复模式才触发 |
| 密码类剪贴板内容 | 记录为 [REDACTED]，不暴露给 OpenClaw |

---

_End of specification._
