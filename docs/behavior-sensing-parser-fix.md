# BehaviorSensingService 响应解析修复

> **问题**：OpenClaw agent 返回的 JSON 被 markdown 代码块包裹（````json ... ````），导致原规格中的简单正则无法提取。
>
> **测试日期**：2026-02-14
> **测试人**：Friday (OpenClaw)

---

## 问题描述

### 实际响应格式

```
```json
{
  "confidence": "high",
  "observation": "你在 Excel 和飞书文档之间反复切换，手动复制分公司名称（上海、深圳）到飞书表格里",
  "suggestion": "把 Excel 文件路径给我，我直接帮你批量提取数据填到飞书里，省得你一个个复制"
}
```
```

### 原规格中的解析逻辑

```swift
// 原设计：正则提取 JSON
let regex = try? NSRegularExpression(pattern: "\\{[^{}]*\"confidence\"[^{}]*\\}")
```

**问题**：这个正则无法处理：
- 换行符
- 嵌套的引号
- markdown 代码块标记

---

## 修复方案

### 文件：`AIPointer/Services/BehaviorSensingService.swift`

在 `executeCommand()` 的响应处理部分，修改 JSON 解析逻辑：

```swift
// 1. 收集完整响应（已有）
var fullResponse = ""
for try await line in bytes.lines {
    // ... SSE 解析逻辑 ...
    fullResponse += content
}

// 2. 剥离 markdown 代码块标记（新增）
var cleaned = fullResponse
    .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
    .replacingOccurrences(of: "```", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

// 3. 尝试直接解析 JSON（新增）
guard let data = cleaned.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let confidenceStr = json["confidence"] as? String else {
    // 解析失败 → fallback
    return BehaviorAnalysis(
        confidence: .low,
        observation: "",
        suggestion: nil
    )
}

// 4. 提取字段（新增）
let confidence: BehaviorConfidence
switch confidenceStr.lowercased() {
case "high": confidence = .high
case "medium": confidence = .medium
default: confidence = .low
}

let observation = json["observation"] as? String ?? ""
let suggestion = json["suggestion"] as? String  // null → nil 自动处理

return BehaviorAnalysis(
    confidence: confidence,
    observation: observation,
    suggestion: suggestion
)
```

---

## 测试用例

### 用例 1：标准 markdown 包裹

**输入**：
```
```json
{"confidence":"high","observation":"测试","suggestion":"帮忙"}
```
```

**期望输出**：
```swift
BehaviorAnalysis(
    confidence: .high,
    observation: "测试",
    suggestion: "帮忙"
)
```

### 用例 2：纯 JSON（无包裹）

**输入**：
```
{"confidence":"medium","observation":"不确定","suggestion":null}
```

**期望输出**：
```swift
BehaviorAnalysis(
    confidence: .medium,
    observation: "不确定",
    suggestion: nil
)
```

### 用例 3：格式错误

**输入**：
```
这是一段文字，不是 JSON
```

**期望输出**：
```swift
BehaviorAnalysis(
    confidence: .low,
    observation: "",
    suggestion: nil
)
```

### 用例 4：低置信度

**输入**：
```json
{"confidence":"low","observation":"","suggestion":null}
```

**期望输出**：
```swift
BehaviorAnalysis(
    confidence: .low,
    observation: "",
    suggestion: nil
)
```

---

## 实现清单

- [ ] 修改 `BehaviorSensingService.swift` 的 JSON 解析逻辑
- [ ] 移除原规格中的正则提取代码
- [ ] 添加 markdown 剥离步骤
- [ ] 使用 `JSONSerialization` 直接解析
- [ ] 测试上述 4 个用例
- [ ] 验证 `swift build` 编译通过

---

## 为什么不改 agent 提示

1. **LLM 普遍行为**：几乎所有模型都会用 markdown 包裹代码/JSON，这是训练数据导致的
2. **鲁棒性**：解析层应该容错，而不是依赖上游"必须返回纯 JSON"
3. **可维护性**：以后换模型/agent 不需要重新调试提示
4. **规格已预留降级**：设计上就考虑了"解析失败 → confidence: low"的 fallback

---

_文档创建时间：2026-02-14 06:25_
_作者：Friday (OpenClaw)_
