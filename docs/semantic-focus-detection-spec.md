# AIPointer — 语义聚焦检测技术规格

> **目的**：技术实现规格，供 Claude Code 按此实现代码。
>
> **前置文档**：`docs/behavior-sensing-spec.md`（高频操作检测，已实现）、`docs/behavior-sensing-skill-search-addon.md`（Skill 搜索增强）
>
> **项目路径**：`/Users/otcombo/Documents/Playgrounds/AIPointer`
>
> **日期**：2026-02-15

---

## 1. 功能定位

与现有的**高频操作检测**（Scorer 评分，2 秒周期）**并行运行**，互不冲突。

| | 高频操作检测（已有） | 语义聚焦检测（本文档） |
|--|-------------------|---------------------|
| **适用场景** | 重复性劳动（跨应用复制粘贴） | 研究/浏览/信息收集 |
| **检测窗口** | 2 分钟 | 可配置，默认 5 分钟 |
| **检测频率** | 每 2 秒 | 每 30 秒 |
| **谁做判断** | 本地 Scorer（规则打分） | OpenClaw（LLM 语义理解） |
| **Prompt 前缀** | `[BEHAVIOR-ASSIST]` | `[FOCUS-DETECT]` |

---

## 2. 架构总览

```
┌── AIPointer App ──────────────────────────────────────────────────┐
│                                                                    │
│  TabSnapshotCache (NEW)          ← 缓存各应用的 Tab 快照          │
│  FocusDetectionService (NEW)     ← 粗筛 + 快照采集 + 指标计算     │
│                                                                    │
│  BehaviorBuffer (EXIST)          ← 已有，复用事件数据              │
│  BehaviorMonitor (MODIFY)        ← 新增 Tab 快照采集              │
│  BehaviorSensingService (MODIFY) ← 集成语义聚焦检测               │
│  OpenClawService (EXIST)         ← 已有 executeCommand()          │
│  PointerViewModel (EXIST)        ← 复用 updateBehaviorSuggestion()│
│  SettingsView (MODIFY)           ← 新增语义聚焦设置项              │
└────────────────────────────────────────────────────────────────────┘
```

### 改动清单

| 文件 | 动作 | 说明 |
|------|------|------|
| `Services/TabSnapshotCache.swift` | **NEW** | Tab 快照缓存 |
| `Services/FocusDetectionService.swift` | **NEW** | 三层检测逻辑（粗筛 + 快照 + 指标） |
| `Services/BehaviorMonitor.swift` | **MODIFY** | 新增 Tab 快照采集 |
| `Services/BehaviorSensingService.swift` | **MODIFY** | 集成 FocusDetectionService 的 30 秒检测循环 |
| `Views/SettingsView.swift` | **MODIFY** | 新增语义聚焦配置项 |
| `AIPointerApp.swift` (AppDelegate) | **MODIFY** | 接线 FocusDetectionService |

### 不需要改动的

| 文件 | 原因 |
|------|------|
| `State/PointerState.swift` | 复用已有的 `.suggestion` 状态 |
| `ViewModels/PointerViewModel.swift` | 复用已有的 `updateBehaviorSuggestion()` |
| `Services/BehaviorBuffer.swift` | 复用已有缓冲区，新增事件类型即可 |
| `Services/BehaviorScorer.swift` | 语义聚焦不使用 Scorer |

**注**：suggestion 状态的指针视觉（`SuggestionIndicator.swift`）已在 `behavior-sensing-spec.md` 中定义，使用 `sparkles.2` SF Symbol + 金白渐变 + 弹跳动画。语义聚焦检测复用同一个组件，不需要额外 UI 工作。

---

## 3. 数据采集：Tab 快照

### 3.1 新增事件类型

在 `BehaviorEventKind` 中新增：

```swift
case tabSnapshot    // Tab 快照，detail = 应用名，context = JSON 格式的 tab 列表
```

### 3.2 Tab 快照采集逻辑

**文件**：`Services/BehaviorMonitor.swift`，新增方法

**触发时机**：`NSWorkspace.didActivateApplicationNotification` 触发后（即用户切换到某应用时）

**采集范围**：

| 应用类型 | Bundle ID | 采集方式 |
|---------|-----------|---------|
| Chrome / Chromium | `com.google.Chrome`, `com.google.Chrome.canary`, `org.chromium.Chromium`, `com.brave.Browser`, `com.microsoft.edgemac` | AX 树遍历 |
| 飞书 / Lark | `com.electron.lark`, `com.bytedance.lark`, `com.larksuite.Feishu` | AX 树遍历 |
| 其他 | — | 不采集 Tab 快照 |

**采集方法**：

```swift
/// 采集 Chrome 系浏览器的 tab 标题列表
private func captureChromeTabs(pid: pid_t) -> [TabInfo]? {
    let appEl = AXUIElementCreateApplication(pid)
    
    // 必须启用 AXEnhancedUserInterface 才能获取 Chrome tab 信息
    AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    
    // 获取 focused window
    var focusedRef: AnyObject?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else {
        return nil
    }
    
    var tabs: [TabInfo] = []
    
    // 递归查找 AXRadioButton（subrole == AXTabButton）
    func findTabs(_ el: AXUIElement, depth: Int = 0) {
        guard depth < 10 else { return }
        
        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return }
        
        if role == "AXRadioButton" {
            var subroleRef: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String, subrole == "AXTabButton" {
                
                var descRef: AnyObject?
                if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
                   let desc = descRef as? String, !desc.isEmpty {
                    
                    var selectedRef: AnyObject?
                    let isSelected = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &selectedRef) == .success
                        && (selectedRef as? NSNumber)?.boolValue == true
                    
                    tabs.append(TabInfo(title: desc, isActive: isSelected))
                }
            }
        }
        
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            findTabs(child, depth: depth + 1)
        }
    }
    
    findTabs(focusedRef as! AXUIElement)
    return tabs.isEmpty ? nil : tabs
}

/// 采集飞书的 tab 标题列表
/// 路径：Window → TabBarView → TabScrollContentsView → AXRadioButton.AXDescription
private func captureFeishuTabs(pid: pid_t) -> [TabInfo]? {
    let appEl = AXUIElementCreateApplication(pid)
    
    var focusedRef: AnyObject?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success else {
        return nil
    }
    
    var tabs: [TabInfo] = []
    
    // 递归查找 desc 包含 "TabScrollContents" 的 ScrollArea，
    // 然后遍历其子元素中的 AXRadioButton
    func findTabScrollArea(_ el: AXUIElement, depth: Int = 0) {
        guard depth < 20 else { return }
        
        var descRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String, desc.contains("TabScrollContents") {
            
            // 找到了，遍历子元素
            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            
            for child in children {
                var roleRef: AnyObject?
                guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                      let role = roleRef as? String, role == "AXRadioButton" else { continue }
                
                var tabDescRef: AnyObject?
                if AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &tabDescRef) == .success,
                   let tabDesc = tabDescRef as? String, !tabDesc.isEmpty {
                    
                    var selectedRef: AnyObject?
                    let isSelected = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &selectedRef) == .success
                        && (selectedRef as? NSNumber)?.boolValue == true
                    
                    tabs.append(TabInfo(title: tabDesc, isActive: isSelected))
                }
            }
            return
        }
        
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            findTabScrollArea(child, depth: depth + 1)
        }
    }
    
    findTabScrollArea(focusedRef as! AXUIElement)
    return tabs.isEmpty ? nil : tabs
}
```

**数据结构**：

```swift
struct TabInfo {
    let title: String
    let isActive: Bool    // 当前选中的 tab
}
```

### 3.3 性能参考

实测数据（Apple M 系列芯片）：

| 应用 | Tab 数量 | 耗时 |
|------|---------|------|
| Chrome | 3 个 tab | ~4ms |
| 飞书 | 19 个 tab | ~30ms |
| 推算 50 个 tab | - | <100ms |

**限制**：Tab 快照只能在应用处于前台时获取。非前台应用的 `AXFocusedWindow` 返回 error -25212。

---

## 4. TabSnapshotCache — Tab 快照缓存

### 文件：`AIPointer/Services/TabSnapshotCache.swift`

**职责**：为每个应用保存最近一次的 Tab 快照，供后续分析使用。

```swift
class TabSnapshotCache {
    struct Snapshot {
        let appName: String
        let bundleId: String
        let tabs: [TabInfo]
        let capturedAt: Date
    }
    
    /// 按 bundleId 存储最近一次快照
    private var cache: [String: Snapshot] = [:]
    
    /// 存入快照
    func store(appName: String, bundleId: String, tabs: [TabInfo]) {
        cache[bundleId] = Snapshot(
            appName: appName,
            bundleId: bundleId,
            tabs: tabs,
            capturedAt: Date()
        )
    }
    
    /// 获取某应用的最近快照（5 分钟内有效）
    func get(bundleId: String, maxAge: TimeInterval = 300) -> Snapshot? {
        guard let snapshot = cache[bundleId],
              Date().timeIntervalSince(snapshot.capturedAt) <= maxAge else {
            return nil
        }
        return snapshot
    }
    
    /// 获取所有有效快照
    func allValid(maxAge: TimeInterval = 300) -> [Snapshot] {
        let now = Date()
        return cache.values.filter { now.timeIntervalSince($0.capturedAt) <= maxAge }
    }
}
```

### BehaviorMonitor 中的调用

在 `appDidActivate` 处理中：

```swift
func appDidActivate(_ app: NSRunningApplication) {
    let appName = app.localizedName ?? "Unknown"
    let bundleId = app.bundleIdentifier ?? ""
    let pid = app.processIdentifier
    
    // 已有：记录 appSwitch 和 windowTitle 事件
    // ...
    
    // 新增：对支持的应用采集 Tab 快照
    if let tabs = captureTabs(bundleId: bundleId, pid: pid) {
        tabSnapshotCache.store(appName: appName, bundleId: bundleId, tabs: tabs)
        
        // 同时写入 BehaviorBuffer（可选，用于粗筛统计）
        let tabTitles = tabs.map { $0.title }
        let json = (try? JSONEncoder().encode(tabTitles)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        buffer.append(BehaviorEvent(
            timestamp: Date(),
            kind: .tabSnapshot,
            detail: appName,
            context: json
        ))
    }
}

private func captureTabs(bundleId: String, pid: pid_t) -> [TabInfo]? {
    let chromeIds = ["com.google.Chrome", "com.google.Chrome.canary",
                     "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac"]
    let feishuIds = ["com.electron.lark", "com.bytedance.lark", "com.larksuite.Feishu"]
    
    if chromeIds.contains(bundleId) {
        return captureChromeTabs(pid: pid)
    } else if feishuIds.contains(bundleId) {
        return captureFeishuTabs(pid: pid)
    }
    return nil
}
```

---

## 5. 三层检测架构

### 5.1 第一层：粗筛（本地，每 30 秒）

**目的**：过滤掉明显无意义的分散浏览，避免无效 API 调用。

**文件**：`Services/FocusDetectionService.swift`

```swift
struct PreScreenResult {
    let triggered: Bool
    let triggerApp: String        // 触发分析的应用名
    let triggerBundleId: String   // 触发应用的 bundleId
}

func preScreen(events: [BehaviorEvent], tabCache: TabSnapshotCache, cooldownPassed: Bool) -> PreScreenResult {
    guard cooldownPassed else {
        return PreScreenResult(triggered: false, triggerApp: "", triggerBundleId: "")
    }
    
    let window = UserDefaults.standard.double(forKey: "focusDetectionWindow")  // 默认 5 分钟
    let windowSeconds = window > 0 ? window * 60 : 300
    let cutoff = Date().addingTimeInterval(-windowSeconds)
    
    // 取时间窗口内的标题事件
    let titleEvents = events.filter {
        ($0.kind == .windowTitle || $0.kind == .tabSwitch) && $0.timestamp >= cutoff
    }
    
    // 按应用分组（context 存储应用名）
    let byApp = Dictionary(grouping: titleEvents, by: { $0.context ?? "" })
    
    for (app, appEvents) in byApp {
        guard !app.isEmpty else { continue }
        
        let uniqueTitles = Set(appEvents.map { $0.detail })
        
        // 查找该应用的 Tab 快照
        let bundleId = findBundleId(forAppName: app)
        let hasTabSnapshot = tabCache.get(bundleId: bundleId ?? "") != nil
        let tabCount = tabCache.get(bundleId: bundleId ?? "")?.tabs.count ?? 0
        
        if hasTabSnapshot {
            // 有 Tab 快照的应用：标题事件 ≥ 3 + 不同标题 ≥ 2 + Tab 数 ≥ 4
            if appEvents.count >= 3 && uniqueTitles.count >= 2 && tabCount >= 4 {
                return PreScreenResult(triggered: true, triggerApp: app, triggerBundleId: bundleId ?? "")
            }
        } else {
            // 无 Tab 快照的应用：标题事件 ≥ 4 + 不同标题 ≥ 2
            if appEvents.count >= 4 && uniqueTitles.count >= 2 {
                return PreScreenResult(triggered: true, triggerApp: app, triggerBundleId: bundleId ?? "")
            }
        }
    }
    
    return PreScreenResult(triggered: false, triggerApp: "", triggerBundleId: "")
}
```

### 5.2 第二层：全量快照采集 + 客观指标计算

**目的**：构建以时间线为主干的多维度快照，同时计算客观指标供 LLM 参考。

**文件**：`Services/FocusDetectionService.swift`

#### 5.2.1 时间线构建

```swift
struct TimelineEntry {
    let timestamp: Date
    let app: String
    let title: String
    var axContext: String?        // 绑定的 AX 元素上下文（来自该窗口的 dwell/click 事件）
    var clipboardContent: String? // 绑定的剪贴板内容（在该窗口期间发生的复制）
    var isRevisit: Bool = false   // 标记为回访
}

func buildTimeline(events: [BehaviorEvent], windowSeconds: TimeInterval) -> [TimelineEntry] {
    let cutoff = Date().addingTimeInterval(-windowSeconds)
    let recentEvents = events.filter { $0.timestamp >= cutoff }
    
    var timeline: [TimelineEntry] = []
    var seenTitles = Set<String>()
    var currentApp = ""
    var currentTitle = ""
    
    for event in recentEvents.sorted(by: { $0.timestamp < $1.timestamp }) {
        switch event.kind {
        case .windowTitle, .tabSwitch:
            let title = event.detail
            let app = event.context ?? ""
            
            // 连续相同标题只保留第一条（去重压缩）
            guard title != currentTitle else { continue }
            
            var entry = TimelineEntry(
                timestamp: event.timestamp,
                app: app,
                title: title
            )
            entry.isRevisit = seenTitles.contains(title)
            seenTitles.insert(title)
            
            timeline.append(entry)
            currentApp = app
            currentTitle = title
            
        case .dwell, .click:
            // 绑定到最近的时间线条目
            if let context = event.context, !context.isEmpty,
               let last = timeline.indices.last {
                if timeline[last].axContext == nil {
                    timeline[last].axContext = context
                }
            }
            
        case .clipboard:
            // 绑定到最近的时间线条目
            if let last = timeline.indices.last {
                if timeline[last].clipboardContent == nil {
                    timeline[last].clipboardContent = event.detail
                }
            }
            
        default:
            break
        }
    }
    
    // 最多保留 15 条
    if timeline.count > 15 {
        return Array(timeline.suffix(15))
    }
    return timeline
}
```

#### 5.2.2 客观指标计算

```swift
struct ObjectiveMetrics {
    let revisitCount: Int         // 回访次数（同一标题出现 ≥2 次的标题数）
    let browsedTabRatio: Double   // 已浏览 Tab 占比（时间线中出现的 tab / Tab 快照总数）
    let clipboardRelevance: Int   // 剪贴板关联度（剪贴板内容出现在标题中的次数）
    let triggerAppFocus: Double   // 触发应用专注度（触发应用标题事件数 / 全部标题事件数）
}

func computeMetrics(
    timeline: [TimelineEntry],
    triggerApp: String,
    tabSnapshot: TabSnapshotCache.Snapshot?,
    allTitleEvents: [BehaviorEvent]
) -> ObjectiveMetrics {
    
    // 1. 回访次数
    let titleCounts = Dictionary(grouping: timeline, by: { $0.title }).mapValues { $0.count }
    let revisitCount = titleCounts.values.filter { $0 >= 2 }.count
    
    // 2. 已浏览 Tab 占比
    let browsedTabRatio: Double
    if let snapshot = tabSnapshot {
        let timelineTitles = Set(timeline.map { $0.title })
        let browsedCount = snapshot.tabs.filter { timelineTitles.contains($0.title) }.count
        browsedTabRatio = snapshot.tabs.isEmpty ? 0 : Double(browsedCount) / Double(snapshot.tabs.count)
    } else {
        browsedTabRatio = 0
    }
    
    // 3. 剪贴板关联度
    let clipboards = timeline.compactMap { $0.clipboardContent }
    let titles = timeline.map { $0.title }
    var clipboardRelevance = 0
    for clip in clipboards {
        for title in titles {
            if title.localizedCaseInsensitiveContains(clip) || clip.localizedCaseInsensitiveContains(title) {
                clipboardRelevance += 1
                break
            }
        }
    }
    
    // 4. 触发应用专注度
    let triggerAppEvents = allTitleEvents.filter { ($0.context ?? "") == triggerApp }
    let triggerAppFocus = allTitleEvents.isEmpty ? 0 : Double(triggerAppEvents.count) / Double(allTitleEvents.count)
    
    return ObjectiveMetrics(
        revisitCount: revisitCount,
        browsedTabRatio: browsedTabRatio,
        clipboardRelevance: clipboardRelevance,
        triggerAppFocus: triggerAppFocus
    )
}
```

### 5.3 第三层：LLM 语义判断

#### 5.3.1 Prompt 构建

```swift
func buildFocusDetectPrompt(
    timeline: [TimelineEntry],
    tabSnapshot: TabSnapshotCache.Snapshot?,
    metrics: ObjectiveMetrics,
    installedSkills: [(name: String, description: String)],
    strictness: Int    // 0=宽松, 1=正常, 2=严格
) -> String {
    
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"
    
    // --- 浏览时间线 ---
    var timelineText = ""
    for entry in timeline {
        let time = timeFormatter.string(from: entry.timestamp)
        let revisitMark = entry.isRevisit ? "  ← 回访" : ""
        timelineText += "\(time) [\(entry.app)] \(entry.title)\(revisitMark)\n"
        if let ax = entry.axContext {
            timelineText += "      → AX: \(ax)\n"
        }
        if let clip = entry.clipboardContent {
            timelineText += "      → 复制: \"\(clip)\"\n"
        }
    }
    
    // --- Tab 快照 ---
    var tabText = ""
    if let snapshot = tabSnapshot {
        let timelineTitles = Set(timeline.map { $0.title })
        tabText = "--- \(snapshot.appName) 全部 Tab（共 \(snapshot.tabs.count) 个）---\n"
        for (i, tab) in snapshot.tabs.enumerated() {
            let browsed = timelineTitles.contains(tab.title) ? "  [已浏览]" : ""
            let active = tab.isActive ? "  [当前]" : ""
            tabText += "\(i + 1). \(tab.title)\(browsed)\(active)\n"
        }
    }
    
    // --- 已安装 skills ---
    var skillsText = ""
    if !installedSkills.isEmpty {
        skillsText = "--- 已安装的 skills ---\n"
        for skill in installedSkills {
            skillsText += "- \(skill.name): \(skill.description)\n"
        }
    }
    
    // --- 客观指标 ---
    let metricsText = """
    --- 客观指标 ---
    - 回访次数: \(metrics.revisitCount)（同一标题重复出现的标题数）
    - 已浏览 Tab 占比: \(String(format: "%.0f%%", metrics.browsedTabRatio * 100))
    - 剪贴板关联度: \(metrics.clipboardRelevance)（剪贴板内容与标题匹配次数）
    - 触发应用专注度: \(String(format: "%.0f%%", metrics.triggerAppFocus * 100))
    """
    
    // --- 置信度标准（根据严格度调整）---
    let highRequirement: String
    switch strictness {
    case 0:  // 宽松
        highRequirement = "客观指标满足以下至少一项"
    case 2:  // 严格
        highRequirement = "客观指标满足以下至少三项"
    default: // 正常
        highRequirement = "客观指标满足以下至少两项"
    }
    
    return """
    [FOCUS-DETECT] 以下是用户最近的注意力快照。
    请判断用户是否在某个主题上持续关注，以及你是否能帮上忙。
    
    --- 浏览时间线 ---
    \(timelineText)
    \(tabText.isEmpty ? "" : "\(tabText)\n")\(metricsText)
    
    \(skillsText.isEmpty ? "" : "\(skillsText)\n")--- 你的能力 ---
    你可以：读写文件、运行脚本（Python/Node/Shell）、操作浏览器（Chromium系）、
    读邮件、发消息、提取网页内容、搜索网页。
    以上已安装的 skills 是你现在就能用的工具。
    
    --- 置信度判断标准 ---
    
    回复 high（必须同时满足）：
    1. 能明确识别用户的具体研究对象（如"贵州茅台"，不是泛泛的"股票"）
    2. 能给出具体可执行的建议
    3. \(highRequirement)：
       - 回访次数 ≥ 1
       - 已浏览 Tab 占比 ≥ 40%
       - 剪贴板关联度 ≥ 1
       - 触发应用专注度 ≥ 60%
    
    回复 medium（满足任一）：
    1. 能识别主题方向但不够具体（如"在看股票"但不确定目的）
    2. 能帮忙但需要用户补充信息
    
    回复 detected:false：
    1. 内容分散无主题
    2. 或有主题但帮不上忙
    3. 或客观指标全部不满足
    
    --- Skill 推荐 ---
    1. 优先检查已安装 skills 中有没有能**直接解决用户当前主题**的 → 在 installedSkill 中指明
       注意：通用工具型 skill（如 github、weather）不算"直接解决"，必须是专门针对该主题的 skill
    2. 如果已安装 skills 中没有专门针对该主题的 → 必须提供 searchKeywords，用于搜索社区是否有专门的 skill
    3. searchKeywords 应描述用户需要的**专门能力**（如 "stock portfolio tracker"），不是通用操作（如 "web scraping"）
    4. installedSkill 和 searchKeywords 可以同时存在（已安装的能部分帮忙 + 搜索更专业的）
    
    --- 响应格式（严格 JSON，不要任何其他文字）---
    每个文本字段必须精简，用户需要一眼看懂，不要写长句。
    字符数限制：theme ≤ 30 字符，observation ≤ 200 字符，insight ≤ 120 字符，offer ≤ 200 字符。
    
    所有字段严禁心理分析、情绪判断、动机推测。你是工具，不是心理医生。
    只描述"用户在做什么"，不要描述"用户为什么这样做"或"用户感觉怎样"。
    
    theme: 只写主题关键词，不要加修饰语。
    ❌ "Compulsive portfolio monitoring crisis"  ❌ "强迫性股票检查焦虑"
    ✅ "美股行情"  ✅ "Stock prices"
    
    observation: 只写客观行为事实（打开了什么、切换了几次、复制了什么）。
    ❌ "User maintained compulsive checking cycle across multiple platforms"
    ✅ "1分钟内在Yahoo和Robinhood间切换7次，浏览NFLX/TSLA/BTC/AAPL"
    
    insight: 用大白话说用户在做什么，不要加主观判断。
    ❌ "用户正在进行多维度的行业横向对比研究"  ❌ "强迫检查完全复发"
    ✅ "在对比茅台和五粮液的股价"
    ❌ "User is exploring cross-platform investment opportunities"
    ✅ "Comparing Moutai vs Wuliangye stock prices"
    
    offer: 只说你能做什么，不要评价用户行为。
    ❌ "You've been in this exhausting cycle for hours"
    ✅ "可以帮你自动监控这6只股票的价格变动"
    
    每个字段只关注一件事。如果用户在做两件不相关的事，只报告当前窗口时间内最明显的那个主题。
    
    已安装 skill 可帮忙：
    {"detected":true,"confidence":"high/medium","theme":"≤20字符","observation":"≤100字符","insight":"≤60字符","offer":"≤80字符","installedSkill":"skill名"}
    
    需要搜索社区 skill：
    {"detected":true,"confidence":"high/medium","theme":"≤20字符","observation":"≤100字符","insight":"≤60字符","offer":"≤80字符","searchKeywords":["kw1","kw2"]}
    
    同时推荐已安装 + 搜索社区：
    {"detected":true,"confidence":"high/medium","theme":"≤20字符","observation":"≤100字符","insight":"≤60字符","offer":"≤80字符","installedSkill":"skill名","searchKeywords":["kw1","kw2"]}
    
    无主题或帮不上忙：
    {"detected":false}
    
    示例（中文）：
    {"detected":true,"confidence":"high","theme":"白酒股票研究","observation":"5分钟内浏览4个白酒股票页面，复制了600519","insight":"在对比茅台和五粮液的股价","offer":"可以帮你抓取实时数据做对比表格","searchKeywords":["stock analysis","portfolio tracker"]}
    
    示例（英文）：
    {"detected":true,"confidence":"high","theme":"Stock research","observation":"Browsed 4 liquor stock pages in 5 min, copied ticker 600519","insight":"Comparing Moutai vs Wuliangye stock prices","offer":"I can pull real-time data and build a comparison table","searchKeywords":["stock analysis","portfolio tracker"]}
    """
}
```

#### 5.3.2 响应解析

```swift
struct FocusDetectResult {
    let detected: Bool
    let confidence: Confidence?     // high / medium
    let theme: String?
    let observation: String?        // 客观行为事实
    let insight: String?            // 对用户意图的理解和判断
    let offer: String?              // 能提供的帮助（含 skill 推荐）
    let installedSkill: String?
    let searchKeywords: [String]?
    
    enum Confidence: String { case high, medium }
    
    /// 根据展示设置，组合最终展示给用户的文本
    func displayText(
        showObservation: Bool,
        showInsight: Bool,
        showOffer: Bool
    ) -> String? {
        var parts: [String] = []
        if showObservation, let obs = observation, !obs.isEmpty {
            parts.append(obs)
        }
        if showInsight, let ins = insight, !ins.isEmpty {
            parts.append(ins)
        }
        if showOffer, let ofr = offer, !ofr.isEmpty {
            parts.append(ofr)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

func parseFocusDetectResponse(_ raw: String) -> FocusDetectResult {
    // 正则提取 JSON
    guard let match = raw.range(of: #"\{[^{}]*"detected"[^{}]*\}"#, options: .regularExpression),
          let data = raw[match].data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return FocusDetectResult(detected: false, confidence: nil, theme: nil,
                                 observation: nil, insight: nil, offer: nil,
                                 installedSkill: nil, searchKeywords: nil)
    }
    
    let detected = json["detected"] as? Bool ?? false
    guard detected else {
        return FocusDetectResult(detected: false, confidence: nil, theme: nil,
                                 observation: nil, insight: nil, offer: nil,
                                 installedSkill: nil, searchKeywords: nil)
    }
    
    return FocusDetectResult(
        detected: true,
        confidence: Confidence(rawValue: json["confidence"] as? String ?? ""),
        theme: json["theme"] as? String,
        observation: json["observation"] as? String,
        insight: json["insight"] as? String,
        offer: json["offer"] as? String,
        installedSkill: json["installedSkill"] as? String,
        searchKeywords: json["searchKeywords"] as? [String]
    )
}
```

#### 5.3.3 ClawHub 搜索（LLM 返回 searchKeywords 时触发）

```swift
/// 调用 clawhub search，返回 skill 名称和描述
private func searchClawHub(keywords: [String]) async -> [(name: String, description: String)] {
    guard !keywords.isEmpty else { return [] }
    
    let query = keywords.joined(separator: " ")
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["clawhub", "search", "--limit", "5", query]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    
    do {
        try process.run()
        
        // 超时 3 秒
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        return parseClawHubOutput(output)
    } catch {
        return []
    }
}

private func parseClawHubOutput(_ output: String) -> [(name: String, description: String)] {
    // 格式：skill-name v1.0.0  Description text  (score)
    var results: [(String, String)] = []
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
        let components = trimmed.components(separatedBy: "  ").filter { !$0.isEmpty }
        guard components.count >= 2 else { continue }
        let namePart = components[0].components(separatedBy: " ").first ?? ""
        let descPart = components[1].components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !namePart.isEmpty else { continue }
        results.append((namePart, descPart))
    }
    return results
}
```

#### 5.3.4 已安装 Skills 列表获取

```swift
/// 扫描已安装的 skills 目录，提取 name + description
func getInstalledSkills() -> [(name: String, description: String)] {
    // OpenClaw 的 skills 目录
    let skillsDir = "/opt/homebrew/lib/node_modules/openclaw/skills"
    
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) else {
        return []
    }
    
    var skills: [(String, String)] = []
    
    for entry in entries {
        let skillMdPath = "\(skillsDir)/\(entry)/SKILL.md"
        guard FileManager.default.fileExists(atPath: skillMdPath),
              let content = try? String(contentsOfFile: skillMdPath, encoding: .utf8) else { continue }
        
        // 从 SKILL.md 提取 name 和 description
        // 通常格式：第一行 # Name，前几行有 description
        let lines = content.components(separatedBy: "\n")
        let name = entry  // 用目录名作为 skill 名
        var description = ""
        
        for line in lines.prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(">") && !trimmed.hasPrefix("---") {
                description = trimmed
                break
            }
        }
        
        skills.append((name, description))
    }
    
    return skills
}
```

**注意**：已安装 skills 列表是相对静态的，可以在 `FocusDetectionService.init()` 时加载一次并缓存，不需要每次分析都重新扫描。

---

## 6. 完整编排流程

### 文件：`Services/FocusDetectionService.swift`

```swift
class FocusDetectionService {
    let buffer: BehaviorBuffer
    let tabCache: TabSnapshotCache
    let openClawService: OpenClawService
    
    private var lastDetectTime: Date = .distantPast
    private var isAnalyzing = false
    private var installedSkillsCache: [(name: String, description: String)] = []
    
    // 设置项（从 UserDefaults 读取）
    var detectionWindowMinutes: Double = 5.0
    var cooldownDetectedMinutes: Double = 10.0
    var cooldownMissedMinutes: Double = 2.0
    var strictness: Int = 1  // 0=宽松, 1=正常, 2=严格
    
    init(buffer: BehaviorBuffer, tabCache: TabSnapshotCache, openClawService: OpenClawService) {
        self.buffer = buffer
        self.tabCache = tabCache
        self.openClawService = openClawService
        self.installedSkillsCache = getInstalledSkills()
    }
    
    /// 每 30 秒由 BehaviorSensingService 调用
    func tick() async -> FocusDetectResult? {
        guard !isAnalyzing else { return nil }
        
        // ========== 第一层：粗筛 ==========
        let windowSeconds = detectionWindowMinutes * 60
        let events = buffer.snapshot(lastSeconds: windowSeconds)
        
        let cooldownPassed: Bool
        let timeSinceLastDetect = Date().timeIntervalSince(lastDetectTime)
        cooldownPassed = timeSinceLastDetect > cooldownMissedMinutes * 60
        // （冷却期根据上次结果动态调整，见下方）
        
        let preResult = preScreen(events: events, tabCache: tabCache, cooldownPassed: cooldownPassed)
        guard preResult.triggered else { return nil }
        
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        // ========== 第二层：全量快照 + 客观指标 ==========
        let timeline = buildTimeline(events: events, windowSeconds: windowSeconds)
        guard !timeline.isEmpty else { return nil }
        
        let tabSnapshot = tabCache.get(bundleId: preResult.triggerBundleId)
        
        let titleEvents = events.filter { $0.kind == .windowTitle || $0.kind == .tabSwitch }
        let metrics = computeMetrics(
            timeline: timeline,
            triggerApp: preResult.triggerApp,
            tabSnapshot: tabSnapshot,
            allTitleEvents: titleEvents
        )
        
        // ========== 第三层：LLM 判断 ==========
        let prompt = buildFocusDetectPrompt(
            timeline: timeline,
            tabSnapshot: tabSnapshot,
            metrics: metrics,
            installedSkills: installedSkillsCache,
            strictness: strictness
        )
        
        guard let response = await openClawService.executeCommand(prompt, agentId: "aipointer") else {
            return nil
        }
        
        var result = parseFocusDetectResponse(response)
        
        // 处理 ClawHub 搜索 + 二次 LLM 整合
        if result.detected, let keywords = result.searchKeywords, !keywords.isEmpty {
            let communitySkills = await searchClawHub(keywords: keywords)
            if !communitySkills.isEmpty {
                let skillNames = communitySkills.prefix(3).map { "\($0.name): \($0.description)" }.joined(separator: "\n")
                // 二次 LLM 调用：将 offer + 搜索结果整合成一段自然的话
                let mergePrompt = """
                将以下"帮助建议"和"推荐工具"合并为一段自然流畅的话（≤ 150 字符）。
                像朋友推荐一样说话，不要用列表格式。必须提到工具名。
                
                帮助建议：\(result.offer ?? "")
                推荐工具：\(skillNames)
                
                直接输出合并后的文本，不要任何其他内容。
                """
                let mergedOffer = await callOpenClaw(prompt: mergePrompt)
                let finalOffer = mergedOffer ?? (result.offer ?? "") + " 推荐: " + communitySkills.prefix(3).map { $0.name }.joined(separator: ", ")
                result = FocusDetectResult(
                    detected: result.detected,
                    confidence: result.confidence,
                    theme: result.theme,
                    observation: result.observation,
                    insight: result.insight,
                    offer: finalOffer,
                    installedSkill: result.installedSkill,
                    searchKeywords: result.searchKeywords
                )
            }
        }
        
        // 更新冷却期
        lastDetectTime = Date()
        if result.detected {
            // 有效触发 → 使用较长冷却期
            // cooldownMissedMinutes 在下次 tick 中不会生效，因为
            // 我们用一个单独的属性记录应使用的冷却时间
            lastCooldownSeconds = cooldownDetectedMinutes * 60
        } else {
            lastCooldownSeconds = cooldownMissedMinutes * 60
        }
        
        return result.detected ? result : nil
    }
    
    private var lastCooldownSeconds: TimeInterval = 120  // 默认 2 分钟
}
```

**注意**：冷却期的实际检查应使用 `lastCooldownSeconds` 而不是固定值：

```swift
let cooldownPassed = Date().timeIntervalSince(lastDetectTime) > lastCooldownSeconds
```

---

## 7. BehaviorSensingService 集成

### 文件：`Services/BehaviorSensingService.swift`

在现有的 2 秒高频检测循环之外，新增 30 秒的语义聚焦检测：

```swift
class BehaviorSensingService {
    // 已有
    let buffer: BehaviorBuffer
    let scorer: BehaviorScorer
    let monitor: BehaviorMonitor
    var openClawService: OpenClawService?
    var onAnalysisResult: ((BehaviorAnalysis) -> Void)?
    
    // 新增
    var focusDetectionService: FocusDetectionService?
    private var focusDetectionTimer: Timer?
    
    func start() {
        // 已有：启动 2 秒高频检测
        startHighFrequencyDetection()
        
        // 新增：启动 30 秒语义聚焦检测
        if UserDefaults.standard.object(forKey: "focusDetectionEnabled") as? Bool ?? true {
            startFocusDetection()
        }
    }
    
    private func startFocusDetection() {
        guard let openClaw = openClawService else { return }
        
        focusDetectionService = FocusDetectionService(
            buffer: buffer,
            tabCache: monitor.tabSnapshotCache,
            openClawService: openClaw
        )
        applyFocusDetectionSettings()
        
        focusDetectionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let result = await self?.focusDetectionService?.tick() else { return }
                
                // 根据展示设置过滤内容
                let defaults = UserDefaults.standard
                let showObservation = defaults.object(forKey: "focusShowObservation") as? Bool ?? true
                let showInsight = defaults.object(forKey: "focusShowInsight") as? Bool ?? true
                let showOffer = defaults.object(forKey: "focusShowOffer") as? Bool ?? true
                
                guard let displayText = result.displayText(
                    showObservation: showObservation,
                    showInsight: showInsight,
                    showOffer: showOffer
                ) else { return }  // 所有展示项都关闭 → 不显示
                
                // 复用已有的 suggestion 展示逻辑
                // observation 传完整结果（供 Fn 交互预填），suggestion 传过滤后的展示文本
                let analysis = BehaviorAnalysis(
                    confidence: result.confidence == .high ? .high : .medium,
                    observation: result.observation ?? "",
                    suggestion: displayText
                )
                await MainActor.run {
                    self?.onAnalysisResult?(analysis)
                }
            }
        }
    }
    
    func applyFocusDetectionSettings() {
        let defaults = UserDefaults.standard
        focusDetectionService?.detectionWindowMinutes = defaults.double(forKey: "focusDetectionWindow").clamped(to: 3...10, default: 5)
        focusDetectionService?.cooldownDetectedMinutes = defaults.double(forKey: "focusCooldownDetected").clamped(to: 5...30, default: 10)
        focusDetectionService?.cooldownMissedMinutes = defaults.double(forKey: "focusCooldownMissed").clamped(to: 1...5, default: 2)
        focusDetectionService?.strictness = defaults.integer(forKey: "focusStrictness")  // 0,1,2
    }
    
    func stop() {
        // 已有：停止高频检测
        stopHighFrequencyDetection()
        
        // 新增：停止语义聚焦检测
        focusDetectionTimer?.invalidate()
        focusDetectionTimer = nil
    }
}
```

---

## 8. SettingsView 新增配置项

### 文件：`Views/SettingsView.swift`

```swift
Section("Behavior Sensing") {
    Toggle("Enable behavior sensing", isOn: $behaviorSensingEnabled)
    
    if behaviorSensingEnabled {
        // 已有：灵敏度（高频操作检测）
        HStack {
            Text("Sensitivity")
            Slider(value: $behaviorSensitivity, in: 0.5...2.0, step: 0.1)
            Text(String(format: "%.1f", behaviorSensitivity))
                .monospacedDigit()
        }
        Text("Higher = more frequent suggestions for repetitive tasks")
            .font(.caption)
            .foregroundColor(.secondary)
        
        Divider()
        
        // 新增：语义聚焦检测
        Toggle("Enable focus detection", isOn: $focusDetectionEnabled)
        
        if focusDetectionEnabled {
            HStack {
                Text("Detection window")
                Slider(value: $focusDetectionWindow, in: 3...10, step: 1)
                Text("\(Int(focusDetectionWindow)) min")
                    .monospacedDigit()
            }
            
            HStack {
                Text("Cooldown (detected)")
                Slider(value: $focusCooldownDetected, in: 5...30, step: 1)
                Text("\(Int(focusCooldownDetected)) min")
                    .monospacedDigit()
            }
            
            HStack {
                Text("Cooldown (not detected)")
                Slider(value: $focusCooldownMissed, in: 1...5, step: 0.5)
                Text(String(format: "%.1f", focusCooldownMissed) + " min")
                    .monospacedDigit()
            }
            
            Picker("Strictness", selection: $focusStrictness) {
                Text("Relaxed").tag(0)
                Text("Normal").tag(1)
                Text("Strict").tag(2)
            }
            .pickerStyle(.segmented)
            
            Text("Relaxed = more suggestions, Strict = fewer but more precise")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            // 展示项开关
            Text("Display Options")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Toggle("Show observation", isOn: $focusShowObservation)
            Text("Detected behavior facts (e.g. \"Browsing 4 stock pages in Chrome\")")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Show insight", isOn: $focusShowInsight)
            Text("AI's interpretation of your intent (e.g. \"Comparing Moutai and Wuliangye\")")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Show offer", isOn: $focusShowOffer)
            Text("What AI can help with, including skill recommendations")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

### 新增 AppStorage 键

```swift
@AppStorage("focusDetectionEnabled") var focusDetectionEnabled = true
@AppStorage("focusDetectionWindow") var focusDetectionWindow = 5.0
@AppStorage("focusCooldownDetected") var focusCooldownDetected = 10.0
@AppStorage("focusCooldownMissed") var focusCooldownMissed = 2.0
@AppStorage("focusStrictness") var focusStrictness = 1
@AppStorage("focusShowObservation") var focusShowObservation = true
@AppStorage("focusShowInsight") var focusShowInsight = true
@AppStorage("focusShowOffer") var focusShowOffer = true
```

---

## 9. AppDelegate 接线

在 `startPointerSystem()` 中新增：

```swift
// Tab snapshot cache（共享实例）
let tabSnapshotCache = TabSnapshotCache()
behaviorMonitor.tabSnapshotCache = tabSnapshotCache

// 设置变化时重新应用
// 在 applySettings() 中添加：
behaviorSensingService.applyFocusDetectionSettings()

let focusEnabled = UserDefaults.standard.object(forKey: "focusDetectionEnabled") as? Bool ?? true
if focusEnabled && !behaviorSensingService.isFocusDetectionRunning {
    behaviorSensingService.startFocusDetection()
} else if !focusEnabled {
    behaviorSensingService.stopFocusDetection()
}
```

---

## 10. 分工

### Claude Code 负责（全部代码实现）：
- [ ] 创建 `Services/TabSnapshotCache.swift`
- [ ] 创建 `Services/FocusDetectionService.swift`（含三层检测全部逻辑）
- [ ] 修改 `Services/BehaviorMonitor.swift`（新增 Tab 快照采集 + tabSnapshotCache 属性）
- [ ] 修改 `Services/BehaviorBuffer.swift`（新增 `.tabSnapshot` 事件类型）
- [ ] 修改 `Services/BehaviorSensingService.swift`（集成 30 秒检测循环 + 展示过滤）
- [ ] 修改 `Views/SettingsView.swift`（新增语义聚焦配置项 + Display Options）
- [ ] 修改 `AIPointerApp.swift` AppDelegate（接线 TabSnapshotCache）
- [ ] 验证 `swift build` 编译通过

**注**：Friday（OpenClaw）无需提前做额外配置。`aipointer` agent 已就绪，`[FOCUS-DETECT]` prompt 的格式要求写在代码内的 prompt 模板里，LLM 天然支持。如果集成测试中发现 LLM 回复格式有问题，再由 Friday 调整 agent 的 system prompt。

### Han（手动测试）：
- [ ] 场景 1：在 Chrome 内浏览多个同主题 tab → 验证触发 suggestion
- [ ] 场景 2：在飞书内翻阅多个文档 → 验证触发 suggestion
- [ ] 场景 3：正常分散使用 → 验证不触发
- [ ] 场景 4：调整严格度 → 验证判断尺度变化
- [ ] 场景 5：调整冷却期 → 验证触发间隔变化
- [ ] 场景 6：关闭 Show observation → 验证提示中不显示观察内容
- [ ] 场景 7：只开 Show observation，关闭其他 → 验证只显示观察（调试模式）
- [ ] 场景 8：三个展示项全关 → 验证不显示提示（但后台分析仍运行）

---

## 11. 边界情况

| 场景 | 行为 |
|------|------|
| OpenClaw 未运行 | executeCommand 连接被拒 → 静默失败，isAnalyzing 重置 |
| OpenClaw 返回非 JSON | parseFocusDetectResponse 返回 detected:false |
| 正在聊天时粗筛通过 | 分析照常进行，但 updateBehaviorSuggestion 检查 state 不是 idle → 不显示 |
| 浏览器最小化 | Tab 快照采集失败 → 返回 nil → 不缓存，使用上次缓存（如果未过期） |
| clawhub 未安装 | searchClawHub 返回空 → 不追加 skill 推荐，主功能不受影响 |
| Tab 数量为 0（新窗口/空浏览器） | 粗筛条件不满足（Tab ≥ 4）→ 走无 Tab 快照的规则 |
| 灵敏度设为严格 + 冷却期最长 | 最多每 30 分钟触发一次，只在非常明确时给 high |

---

_End of specification._
