# AIPointer — 行为感知 Skill 搜索增强

> **补充规格**：为 behavior-sensing 功能增加 Skill 推荐能力
>
> **基于文档**：`docs/behavior-sensing-spec.md`
>
> **项目路径**：`/Users/otcombo/Documents/Playgrounds/AIPointer`
>
> **日期**：2026-02-15

---

## 1. 功能目标

在行为感知分析时，自动搜索 ClawHub 上的相关 skills，并在 prompt 中提供给 OpenClaw，使其能够：
1. 推荐已有的专门 skills
2. 或基于自身能力给出建议

---

## 2. 架构变更

### 修改文件
- `Services/BehaviorSensingService.swift` — 新增关键词提取和 skill 搜索逻辑

### 不修改
- 其他文件保持 `behavior-sensing-spec.md` 的实现不变

---

## 3. 关键词提取逻辑

### 新增方法：`extractKeywords(from:)`

**位置**：`BehaviorSensingService.swift` private 方法

**输入**：`[BehaviorEvent]`

**输出**：`[String]`（最多 3 个关键词）

**提取规则**：

| 事件类型 | 提取逻辑 | 示例关键词 |
|---------|---------|-----------|
| `appSwitch` | 提取应用名（从白名单匹配） | excel, chrome, safari, finder, mail, slack |
| `windowTitle` | 同上（从 detail 中提取应用相关词） | — |
| `clipboard` | 检测内容特征 | http → "web"<br>包含 `\t` 或 `,` → "table"<br>长度 8-64 无空格 → "password" |
| `tabSwitch` | 固定关键词 | browser |
| `fileOp` | 固定关键词 | file |
| `copy`, `click`, `dwell` | 从 detail 提取应用名 | — |

**应用名白名单**：
```swift
let appKeywords = ["excel", "chrome", "safari", "finder", "mail", "slack", 
                   "keynote", "pages", "numbers", "vscode", "xcode"]
```

**实现示例**：

```swift
private func extractKeywords(from events: [BehaviorEvent]) -> [String] {
    var keywords = Set<String>()
    let appKeywords = ["excel", "chrome", "safari", "finder", "mail", "slack",
                       "keynote", "pages", "numbers", "vscode", "xcode"]
    
    for event in events {
        switch event.kind {
        case .appSwitch, .windowTitle, .copy, .click, .dwell:
            // 从 detail 提取应用名
            let detail = event.detail.lowercased()
            for app in appKeywords {
                if detail.contains(app) {
                    keywords.insert(app)
                }
            }
            
        case .clipboard:
            let content = event.detail
            if content.contains("http") || content.contains("https") {
                keywords.insert("web")
            }
            if content.contains("\t") || content.contains(",") {
                keywords.insert("table")
            }
            // 密码特征不加关键词（隐私）
            
        case .tabSwitch:
            keywords.insert("browser")
            
        case .fileOp:
            keywords.insert("file")
        }
    }
    
    return Array(keywords.prefix(3))  // 最多 3 个
}
```

---

## 4. Skill 搜索逻辑

### 新增方法：`searchSkills(keywords:)`

**位置**：`BehaviorSensingService.swift` private async 方法

**输入**：`[String]`（关键词数组）

**输出**：`[(name: String, description: String)]`（最多 5 个结果）

**实现**：调用 `clawhub search`

```swift
private func searchSkills(keywords: [String]) async -> [(name: String, description: String)] {
    guard !keywords.isEmpty else { return [] }
    
    let query = keywords.joined(separator: " ")
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["clawhub", "search", "--limit", "5", query]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()  // 忽略 stderr
    
    do {
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return [] }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        return parseClawHubOutput(output)
    } catch {
        print("[BehaviorSensing] Skill search failed: \(error)")
        return []
    }
}

private func parseClawHubOutput(_ output: String) -> [(name: String, description: String)] {
    // clawhub search 输出格式：
    // skill-name v1.0.0  Description text here  (score)
    
    var results: [(String, String)] = []
    
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
        
        // 分割：skill-name v1.0.0  Description  (score)
        let components = trimmed.components(separatedBy: "  ")
        guard components.count >= 2 else { continue }
        
        let namePart = components[0].components(separatedBy: " ").first ?? ""
        let descPart = components[1].components(separatedBy: "(").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        
        guard !namePart.isEmpty else { continue }
        
        results.append((namePart, descPart))
    }
    
    return results
}
```

**错误处理**：
- clawhub 未安装 → 返回空数组，静默失败
- 搜索超时（>2s）→ 返回空数组
- 解析失败 → 返回空数组

---

## 5. Prompt 增强

### 修改点：`analyzeRecentBehavior()` 中的 prompt 构建

**原逻辑**：
```swift
let prompt = """
[BEHAVIOR-ASSIST] ...

--- 操作记录 ---
\(compressedEvents)

--- 你的能力 ---
...
"""
```

**新逻辑**：
```swift
func analyzeRecentBehavior() async {
    guard !isAnalyzing else { return }
    isAnalyzing = true
    defer { isAnalyzing = false }
    
    // 1. 获取事件
    let events = buffer.snapshot(lastSeconds: 180)
    guard events.count >= 5 else { return }
    
    // 2. 提取关键词
    let keywords = extractKeywords(from: events)
    
    // 3. 搜索 Skills（如果有关键词）
    var skillsSection = ""
    if !keywords.isEmpty {
        let skills = await searchSkills(keywords: keywords)
        if !skills.isEmpty {
            let skillList = skills.prefix(5)
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            skillsSection = """
            
            --- 相关 Skills ---
            \(skillList)
            """
        }
    }
    
    // 4. 压缩事件
    let compressedEvents = compressEvents(events)
    
    // 5. 构建 Prompt
    let prompt = """
    [BEHAVIOR-ASSIST] 以下是用户最近的操作记录。请分析用户在做什么，判断你是否能帮上忙。
    
    --- 操作记录 ---
    \(compressedEvents)\(skillsSection)
    
    --- 你的能力 ---
    你可以：
    - 读写文件、运行脚本（Python/Node/Shell）
    - 操作浏览器（Chromium系）、读邮件、发消息
    - 提取网页内容、搜索网页
    - **搜索和推荐专门的 skills**（clawhub）
    
    **如果上面列出的 Skills 里有适合的，或者你认为需要其他 skill，请在 suggestion 里推荐安装。如果没有合适的 skill，基于你自己的能力给出建议。**
    
    --- 响应格式（严格 JSON，不要任何其他文字）---
    高置信度：{"confidence":"high","observation":"你观察到了什么","suggestion":"你能怎么帮忙（可含 skill 推荐）"}
    中置信度：{"confidence":"medium","observation":"你观察到了什么","suggestion":null}
    低置信度：{"confidence":"low","observation":"","suggestion":null}
    """
    
    // 6. 调用 OpenClaw
    let response = await openClawService.executeCommand(prompt, agentId: "aipointer")
    
    // 7. 解析响应...
    // (原有逻辑不变)
}
```

---

## 6. 示例效果

### 场景 A：Excel ↔ Chrome 频繁复制

**关键词提取**：`["excel", "chrome", "table"]`

**clawhub search 结果**：
```
web-table-extractor v2.1.0  Extract tables from web pages
excel-automation v1.0.0  Automate Excel operations
```

**Prompt 包含**：
```
--- 相关 Skills ---
- web-table-extractor: Extract tables from web pages
- excel-automation: Automate Excel operations
```

**OpenClaw 可能回复**：
```json
{
  "confidence": "high",
  "observation": "你在 Excel 和 Chrome 间频繁复制表格数据",
  "suggestion": "我可以帮你自动提取网页表格。要不试试 'web-table-extractor' skill？"
}
```

### 场景 B：Finder 文件操作（无相关 skill）

**关键词提取**：`["finder", "file"]`

**clawhub search 结果**：
```
file-organizer v1.3.0  Organize files by rules
```

**Prompt 包含**：
```
--- 相关 Skills ---
- file-organizer: Organize files by rules
```

**OpenClaw 可能回复**：
```json
{
  "confidence": "medium",
  "observation": "你在 Finder 里连续操作文件",
  "suggestion": null
}
```

（因为不确定具体要做什么，即使有 skill 也是 medium）

### 场景 C：无匹配 skill

**关键词提取**：`["slack", "mail"]`

**clawhub search 结果**：（空，或不相关）

**Prompt 不含** `--- 相关 Skills ---` 部分

**OpenClaw 回复**：
```json
{
  "confidence": "medium",
  "observation": "你在 Slack 和邮件间切换",
  "suggestion": null
}
```

---

## 7. 性能约束

- **关键词提取**：O(n)，n = 事件数量（≤30），<1ms
- **skill 搜索**：异步调用，超时 2s
- **总延迟增加**：≤2s（可接受，分析本身就是后台任务）

---

## 8. 错误处理

| 错误情况 | 行为 |
|---------|------|
| clawhub 未安装 | 静默失败，返回空结果，prompt 不含 skills 部分 |
| 搜索超时 | 返回空结果 |
| 搜索无结果 | prompt 不含 skills 部分，OpenClaw 基于自身能力回复 |
| 解析 clawhub 输出失败 | 返回空结果 |

所有错误情况下，行为感知主流程不受影响。

---

## 9. 实现清单

### Claude Code 需要做的：

- [ ] 在 `BehaviorSensingService.swift` 新增 `extractKeywords(from:)` 方法
- [ ] 在 `BehaviorSensingService.swift` 新增 `searchSkills(keywords:)` 方法
- [ ] 在 `BehaviorSensingService.swift` 新增 `parseClawHubOutput(_:)` 方法
- [ ] 修改 `analyzeRecentBehavior()` 方法：
  - 调用关键词提取
  - 调用 skill 搜索
  - 构建增强 prompt（含 skills 部分）
- [ ] 修改 prompt 模板中的"你的能力"部分
- [ ] 验证编译通过

### Friday（OpenClaw）需要做的：

- [x] aipointer agent 已配置
- [ ] 验证 aipointer agent 能正确解析增强 prompt
- [ ] 验证当有/无 skill 时，回复格式正确

---

## 10. 测试场景

### 测试 1：有匹配 skill
1. 在 Excel 和 Chrome 间复制表格数据 5 次
2. 等待 2-4 秒
3. 验证指针显示 suggestion 提示
4. 验证提示中提到了 skill 名称

### 测试 2：无匹配 skill
1. 在任意应用间随机切换
2. 等待触发
3. 验证提示基于 OpenClaw 自身能力

### 测试 3：clawhub 未安装
1. 临时重命名 clawhub 可执行文件
2. 触发行为感知
3. 验证不崩溃，正常显示 suggestion（无 skill 推荐）

---

_End of addon specification._
