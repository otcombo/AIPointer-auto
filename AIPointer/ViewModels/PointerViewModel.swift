import SwiftUI

@MainActor
class PointerViewModel: ObservableObject {
    @Published var state: PointerState = .idle
    @Published var inputText = ""
    @Published var attachedImages: [SelectedRegion] = []
    @Published var chatHistory: [ChatMessage] = []

    // Skill completion
    @Published var showSkillCompletion = false
    @Published var filteredSkills: [InstalledSkillsProvider.Skill] = []
    @Published var skillCompletionIndex: Int = 0
    private var installedSkills: [InstalledSkillsProvider.Skill] = []
    /// The selected skill to inject as context on send.
    @Published var selectedSkill: InstalledSkillsProvider.Skill?
    /// Expansion direction — computed dynamically by SwiftUI based on current content size.
    @Published var expandsRight: Bool = true
    @Published var expandsDown: Bool = true

    /// Behavior sensing: pending context from a suggestion the user accepted with fn press
    @Published private(set) var pendingBehaviorContext: String?
    private var suggestionDismissTimer: Timer?

    /// Selection context captured on Fn press (selected text / Finder files)
    @Published private(set) var pendingSelectionContext: SelectionContextCapture.CapturedContext?

    /// Mouse position and screen bounds captured at expansion time.
    var expansionMouseX: CGFloat = 0
    var expansionMouseY: CGFloat = 0
    var expansionScreenMinX: CGFloat = 0
    var expansionScreenMaxX: CGFloat = 0
    var expansionScreenMinY: CGFloat = 0
    var expansionScreenMaxY: CGFloat = 0

    /// Called by SwiftUI when expansion direction changes — repositions the panel.
    var onExpansionDirectionChanged: (() -> Void)?

    private let apiService = OpenClawService()
    private var conversationId: String?
    private var currentTask: Task<Void, Never>?

    /// Single callback — AppDelegate reacts to every state change
    var onStateChanged: ((PointerState) -> Void)?

    /// Callback to request entering screenshot mode
    var onScreenshotRequested: (() -> Void)?

    func configureAPI(baseURL: String) {
        apiService.configure(baseURL: baseURL)
        installedSkills = InstalledSkillsProvider.load()
    }

    // MARK: - Skill Completion

    func updateSkillCompletion() {
        let text = inputText
        // Check if text starts with "/" and we're in input state
        guard case .input = state, text.hasPrefix("/") else {
            showSkillCompletion = false
            filteredSkills = []
            skillCompletionIndex = 0
            return
        }

        // Clear selectedSkill if user edited text away from the expected prefix
        if let skill = selectedSkill {
            let expectedPrefix = "/\(skill.name) "
            if !text.hasPrefix(expectedPrefix) && text != "/\(skill.name)" {
                selectedSkill = nil
            } else {
                showSkillCompletion = false
                return
            }
        }

        let query = String(text.dropFirst()) // remove "/"
        // If query contains a space, user has typed past the skill name — hide
        if query.contains(" ") {
            showSkillCompletion = false
            return
        }

        filteredSkills = InstalledSkillsProvider.filter(installedSkills, query: query)
        showSkillCompletion = !filteredSkills.isEmpty
        skillCompletionIndex = max(0, min(skillCompletionIndex, filteredSkills.count - 1))
    }

    func selectSkill(_ skill: InstalledSkillsProvider.Skill) {
        selectedSkill = skill
        inputText = "/\(skill.name) "
        showSkillCompletion = false
        filteredSkills = []
        skillCompletionIndex = 0
    }

    func skillCompletionMoveUp() {
        guard showSkillCompletion, !filteredSkills.isEmpty else { return }
        skillCompletionIndex = (skillCompletionIndex - 1 + filteredSkills.count) % filteredSkills.count
    }

    func skillCompletionMoveDown() {
        guard showSkillCompletion, !filteredSkills.isEmpty else { return }
        skillCompletionIndex = (skillCompletionIndex + 1) % filteredSkills.count
    }

    func skillCompletionConfirm() -> Bool {
        guard showSkillCompletion, !filteredSkills.isEmpty else { return false }
        selectSkill(filteredSkills[skillCompletionIndex])
        return true
    }

    func onFnPress() {
        // Snapshot frontmost app BEFORE any state change / panel activation
        let frontApp = NSWorkspace.shared.frontmostApplication

        switch state {
        case .idle, .monitoring, .codeReady:
            state = .input
            inputText = ""
            attachedImages = []
            pendingBehaviorContext = nil
            captureSelectionContext(frontApp: frontApp)
            onStateChanged?(state)
        case .suggestion:
            // Accept suggestion: transition to input with context pre-loaded
            // pendingBehaviorContext was already set by updateBehaviorSuggestion (display-filtered)
            suggestionDismissTimer?.invalidate()
            suggestionDismissTimer = nil
            state = .input
            inputText = ""
            attachedImages = []
            captureSelectionContext(frontApp: frontApp)
            onStateChanged?(state)
        default:
            dismiss()
        }
    }

    private func captureSelectionContext(frontApp: NSRunningApplication?) {
        SelectionContextCapture.capture(frontApp: frontApp) { [weak self] context in
            guard let self, case .input = self.state else { return }
            if !context.isEmpty {
                self.pendingSelectionContext = context
            }
        }
    }

    /// Called by VerificationService when verification state changes.
    func updateVerificationState(_ newState: PointerState) {
        // Only allow verification states to override idle/monitoring/codeReady.
        // Don't interrupt active chat states (input/thinking/responding/response).
        switch state {
        case .idle, .monitoring, .codeReady:
            state = newState
            onStateChanged?(state)
        default:
            break
        }
    }

    /// Prepare input state for direct screenshot entry (from idle).
    /// Sets state to .input without triggering onStateChanged, so the panel doesn't pop up.
    func prepareForScreenshot() {
        state = .input
        inputText = ""
        attachedImages = []
        // Intentionally no onStateChanged — panel stays hidden, goes straight to screenshot
    }

    func requestScreenshot() {
        onScreenshotRequested?()
    }

    func attachScreenshots(_ regions: [SelectedRegion]) {
        attachedImages.append(contentsOf: regions)
    }

    func removeAttachment(at index: Int) {
        guard index >= 0 && index < attachedImages.count else { return }
        attachedImages.remove(at: index)
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !attachedImages.isEmpty
        let hasContext = pendingBehaviorContext != nil

        // Need either text, images, or behavior context to send
        guard !text.isEmpty || hasImages || hasContext else { return }

        // Build message text
        var messageText: String
        if text.isEmpty && hasImages {
            messageText = "请帮我看看这些截图"
        } else if text.isEmpty && hasContext {
            messageText = "Please help me with this."
        } else {
            messageText = text
        }

        // Strip /skill prefix and inject skill context
        if let skill = selectedSkill {
            let prefix = "/\(skill.name) "
            if messageText.hasPrefix(prefix) {
                messageText = String(messageText.dropFirst(prefix.count))
            } else if messageText.hasPrefix("/\(skill.name)") {
                messageText = String(messageText.dropFirst("/\(skill.name)".count))
            }
            messageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if messageText.isEmpty {
                messageText = "Help me with this skill."
            }
            messageText = "[使用 skill: \(skill.name)] \(messageText)"
            selectedSkill = nil
        }

        // Prepend selection context if present
        if let sel = pendingSelectionContext, !sel.isEmpty {
            var parts: [String] = []
            if let text = sel.selectedText {
                parts.append("[Selected Text]\n\(text)")
            }
            if !sel.filePaths.isEmpty {
                let fileList = sel.filePaths.joined(separator: "\n")
                parts.append("[Selected Files]\n\(fileList)")
            }
            messageText = parts.joined(separator: "\n\n") + "\n\n\(messageText)"
            pendingSelectionContext = nil
        }

        // Prepend behavior context if present
        if let context = pendingBehaviorContext {
            messageText = "\(context)\n\nUser: \(messageText)"
            pendingBehaviorContext = nil
        }

        // Build images array with labels
        var images: [(NSImage, String)] = []
        for (index, region) in attachedImages.enumerated() {
            if let snapshot = region.snapshot {
                images.append((snapshot, "[Screenshot \(index + 1)]"))
            }
        }

        chatHistory.append(ChatMessage(role: .user, text: messageText))

        inputText = ""
        attachedImages = []
        state = .thinking
        onStateChanged?(state)

        currentTask = Task {
            do {
                let stream = apiService.chat(message: messageText, conversationId: conversationId, images: images)
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .delta(let chunk):
                        if case .responding(let existing) = state {
                            state = .responding(text: existing + chunk)
                        } else {
                            state = .responding(text: chunk)
                        }
                        onStateChanged?(state)
                    case .done(let convId):
                        conversationId = convId
                        if case .responding(let fullText) = state {
                            chatHistory.append(ChatMessage(role: .assistant, text: fullText))
                            state = .response(text: fullText)
                            onStateChanged?(state)
                        }
                    case .error(let err):
                        let errorText = "Error: \(err)"
                        chatHistory.append(ChatMessage(role: .assistant, text: errorText))
                        state = .response(text: errorText)
                        onStateChanged?(state)
                    case .status:
                        break
                    }
                }
                if case .thinking = state {
                    let noResponse = "No response received."
                    chatHistory.append(ChatMessage(role: .assistant, text: noResponse))
                    state = .response(text: noResponse)
                    onStateChanged?(state)
                }
            } catch {
                if !Task.isCancelled {
                    let errorText = "Error: \(error.localizedDescription)"
                    chatHistory.append(ChatMessage(role: .assistant, text: errorText))
                    state = .response(text: errorText)
                    onStateChanged?(state)
                }
            }
        }
    }

    func updateBehaviorSuggestion(_ analysis: BehaviorAnalysis) {
        // Only show suggestion when in non-interactive states
        switch state {
        case .idle, .monitoring, .codeReady:
            // suggestion field carries the pre-filtered display text from BehaviorSensingService
            state = .suggestion(observation: analysis.observation, suggestion: analysis.suggestion)
            pendingBehaviorContext = analysis.suggestion  // Store filtered text for Fn press
            onStateChanged?(state)

            // Auto-dismiss after configured duration (default 10s)
            let duration = {
                let val = UserDefaults.standard.double(forKey: "suggestionDisplaySeconds")
                return val > 0 ? val : 10.0
            }()
            suggestionDismissTimer?.invalidate()
            suggestionDismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if case .suggestion = self.state {
                        self.pendingBehaviorContext = nil
                        self.state = .idle
                        self.onStateChanged?(self.state)
                    }
                }
            }
        default:
            break
        }
    }

    func dismiss() {
        apiService.cancel()
        currentTask?.cancel()
        currentTask = nil
        suggestionDismissTimer?.invalidate()
        suggestionDismissTimer = nil
        pendingBehaviorContext = nil
        pendingSelectionContext = nil
        selectedSkill = nil
        showSkillCompletion = false
        filteredSkills = []
        skillCompletionIndex = 0
        state = .idle
        inputText = ""
        attachedImages = []
        onStateChanged?(state)
    }

    // MARK: - Debug: cycle through idle → monitoring → codeReady

    private var debugCycleTask: Task<Void, Never>?
    private let debugStates: [PointerState] = [
        .idle,
        .monitoring,
        .codeReady(code: "583 214"),
        .suggestion(observation: "You're switching between Chrome and Excel repeatedly, copying data each time.", suggestion: "I can help you extract and organize that data automatically.")
    ]
    private var debugIndex = 0

    func startDebugCycle() {
        stopDebugCycle()
        debugIndex = 0
        state = debugStates[0]
        onStateChanged?(state)

        debugCycleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                debugIndex = (debugIndex + 1) % debugStates.count
                state = debugStates[debugIndex]
                onStateChanged?(state)
            }
        }
    }

    func stopDebugCycle() {
        debugCycleTask?.cancel()
        debugCycleTask = nil
    }
}
