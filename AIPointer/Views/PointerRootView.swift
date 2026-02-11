import SwiftUI

struct PointerRootView: View {
    @ObservedObject var viewModel: PointerViewModel

    private var inputBarWidth: CGFloat {
        if viewModel.inputText.isEmpty { return 70 }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let textWidth = (viewModel.inputText as NSString).size(withAttributes: [.font: font]).width
        return min(max(textWidth + 44, 70), 440)
    }

    private var shapeWidth: CGFloat {
        switch viewModel.state {
        case .idle: return 16
        case .input: return inputBarWidth
        case .thinking, .responding, .response: return 440
        }
    }

    private var shapeHeight: CGFloat {
        switch viewModel.state {
        case .idle: return 16
        case .input: return 38
        case .thinking: return 80
        case .responding, .response: return 280
        }
    }

    var body: some View {
        // Color.clear fills the panel; overlay anchors shape to top-left.
        // This guarantees expansion goes right+down from the hotspot.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    switch viewModel.state {
                    case .idle:
                        Color.clear.frame(width: 16, height: 16)
                    case .input:
                        InputBar(
                            text: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onCancel: { viewModel.dismiss() }
                        )
                    case .thinking:
                        ChatPanel(
                            responseText: "",
                            isThinking: true,
                            isStreaming: false,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() }
                        )
                    case .responding(let text):
                        ChatPanel(
                            responseText: text,
                            isThinking: false,
                            isStreaming: true,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() }
                        )
                    case .response(let text):
                        ChatPanel(
                            responseText: text,
                            isThinking: false,
                            isStreaming: false,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() }
                        )
                    }
                }
                .frame(width: shapeWidth, height: shapeHeight, alignment: .topLeading)
                .clipShape(PointerShape(radius: 12))
                .background(PointerShape(radius: 12).fill(Color.black.opacity(0.95)))
                .overlay(PointerShape(radius: 12).stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)
                .padding(14) // Offset from panel edge = shadow padding
            }
            .animation(
                viewModel.state == .idle
                    ? .easeOut(duration: 0.25)                          // collapse: bezier, no bounce
                    : .spring(response: 0.293, dampingFraction: 0.793), // expand: mass=1, damping=34, stiffness=460
                value: viewModel.state
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: inputBarWidth)
    }
}
