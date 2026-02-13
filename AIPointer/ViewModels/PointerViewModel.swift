import SwiftUI

@MainActor
class PointerViewModel: ObservableObject {
    @Published var state: PointerState = .idle
    @Published var inputText = ""
    @Published var attachedImages: [SelectedRegion] = []

    private let apiService = OpenClawService()
    private var conversationId: String?
    private var currentTask: Task<Void, Never>?

    /// Single callback — AppDelegate reacts to every state change
    var onStateChanged: ((PointerState) -> Void)?

    /// Callback to request entering screenshot mode
    var onScreenshotRequested: (() -> Void)?

    func configureAPI(baseURL: String, authToken: String, agentId: String, modelName: String = "", apiFormat: APIFormat = .anthropic) {
        apiService.configure(baseURL: baseURL, authToken: authToken, agentId: agentId, modelName: modelName, apiFormat: apiFormat)
    }

    func onFnPress() {
        switch state {
        case .idle:
            state = .input
            inputText = ""
            attachedImages = []
            onStateChanged?(state)
        default:
            dismiss()
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

        // Need either text or images to send
        guard !text.isEmpty || hasImages else { return }

        // Build message text: default to asking about screenshots if no text
        let messageText = text.isEmpty && hasImages ? "请帮我看看这些截图" : text

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

    func dismiss() {
        apiService.cancel()
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        inputText = ""
        attachedImages = []
        onStateChanged?(state)
    }
}
