import SwiftUI

struct PointerRootView: View {
    @ObservedObject var viewModel: PointerViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch viewModel.state {
            case .idle:
                TeardropCursor()
                    .transition(.opacity)

            case .input:
                InputBar(
                    text: $viewModel.inputText,
                    onSubmit: { viewModel.send() },
                    onCancel: { viewModel.dismiss() }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .topLeading)
                        .combined(with: .opacity),
                    removal: .opacity
                ))

            case .thinking:
                ChatPanel(
                    responseText: "",
                    isThinking: true,
                    isStreaming: false,
                    inputText: $viewModel.inputText,
                    onSubmit: { viewModel.send() },
                    onDismiss: { viewModel.dismiss() }
                )
                .transition(.opacity)

            case .responding(let text):
                ChatPanel(
                    responseText: text,
                    isThinking: false,
                    isStreaming: true,
                    inputText: $viewModel.inputText,
                    onSubmit: { viewModel.send() },
                    onDismiss: { viewModel.dismiss() }
                )
                .transition(.opacity)

            case .response(let text):
                ChatPanel(
                    responseText: text,
                    isThinking: false,
                    isStreaming: false,
                    inputText: $viewModel.inputText,
                    onSubmit: { viewModel.send() },
                    onDismiss: { viewModel.dismiss() }
                )
                .transition(.opacity)
            }
        }
        .padding(14) // Match OverlayPanel.shadowPadding
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
    }
}
