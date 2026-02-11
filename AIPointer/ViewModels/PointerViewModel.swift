import SwiftUI

@MainActor
class PointerViewModel: ObservableObject {
    @Published var state: PointerState = .idle
    @Published var inputText = ""

    private let apiService = ClaudeAPIService()
    private var conversationId: String?
    private var currentTask: Task<Void, Never>?

    /// Single callback — AppDelegate reacts to every state change
    var onStateChanged: ((PointerState) -> Void)?

    func configureAPI(baseURL: String, authToken: String, agentId: String) {
        apiService.configure(baseURL: baseURL, authToken: authToken, agentId: agentId)
    }

    func onFnPress() {
        switch state {
        case .idle:
            state = .input
            inputText = ""
            onStateChanged?(state)
        default:
            dismiss()
        }
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        state = .thinking
        onStateChanged?(state)

        currentTask = Task {
            do {
                let stream = apiService.chat(message: text, conversationId: conversationId)
                for try await event in stream {
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
                state = .response(text: "Error: \(error.localizedDescription)")
                onStateChanged?(state)
            }
        }
    }

    func dismiss() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        inputText = ""
        onStateChanged?(state)
    }
}
