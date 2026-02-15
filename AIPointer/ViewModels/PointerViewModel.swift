import SwiftUI

@MainActor
class PointerViewModel: ObservableObject {
    @Published var state: PointerState = .idle
    @Published var inputText = ""
    @Published var attachedImages: [SelectedRegion] = []
    /// Expansion direction — computed dynamically by SwiftUI based on current content size.
    @Published var expandsRight: Bool = true
    @Published var expandsDown: Bool = true

    /// Behavior sensing: pending context from a suggestion the user accepted with fn press
    @Published private(set) var pendingBehaviorContext: String?
    private var suggestionDismissTimer: Timer?

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
    }

    func onFnPress() {
        switch state {
        case .idle, .monitoring, .codeReady:
            state = .input
            inputText = ""
            attachedImages = []
            pendingBehaviorContext = nil
            onStateChanged?(state)
        case .suggestion:
            // Accept suggestion: transition to input with context pre-loaded
            // pendingBehaviorContext was already set by updateBehaviorSuggestion (display-filtered)
            suggestionDismissTimer?.invalidate()
            suggestionDismissTimer = nil
            state = .input
            inputText = ""
            attachedImages = []
            onStateChanged?(state)
        default:
            dismiss()
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
                            state = .response(text: fullText)
                            onStateChanged?(state)
                        }
                    case .error(let err):
                        state = .response(text: "Error: \(err)")
                        onStateChanged?(state)
                    case .status:
                        break
                    }
                }
                if case .thinking = state {
                    state = .response(text: "No response received.")
                    onStateChanged?(state)
                }
            } catch {
                if !Task.isCancelled {
                    state = .response(text: "Error: \(error.localizedDescription)")
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
