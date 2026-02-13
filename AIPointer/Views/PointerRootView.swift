import SwiftUI

struct PointerRootView: View {
    @ObservedObject var viewModel: PointerViewModel

    private var inputBarWidth: CGFloat {
        if viewModel.inputText.isEmpty { return 110 }
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let textWidth = (viewModel.inputText as NSString).size(withAttributes: [.font: font]).width
        return min(max(textWidth + 44, 110), 440)
    }

    private var hasAttachments: Bool {
        !viewModel.attachedImages.isEmpty
    }

    /// Width needed to show all thumbnails: each 48px wide + 6px spacing + 10px padding each side.
    private var thumbnailStripWidth: CGFloat {
        let count = CGFloat(viewModel.attachedImages.count)
        guard count > 0 else { return 0 }
        return count * 48 + (count - 1) * 6 + 20
    }

    private var codeReadyWidth: CGFloat {
        if case .codeReady(let code) = viewModel.state {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            let textWidth = (code as NSString).size(withAttributes: [.font: font]).width
            return textWidth + 20 // horizontal padding 10*2
        }
        return 16
    }

    private var shapeWidth: CGFloat {
        switch viewModel.state {
        case .idle: return 16
        case .monitoring: return 24
        case .codeReady: return codeReadyWidth
        case .input:
            let contentWidth = max(inputBarWidth, thumbnailStripWidth)
            return min(contentWidth, 440)
        case .thinking, .responding, .response: return 440
        }
    }

    // MARK: - Dynamic expansion direction

    /// Whether content should expand right, based on current width and screen space.
    private var shouldExpandRight: Bool {
        let mouseX = viewModel.expansionMouseX
        let maxX = viewModel.expansionScreenMaxX
        let padding: CGFloat = 14
        return (mouseX + shapeWidth + padding) <= maxX
    }

    /// Whether content should expand down, based on screen space (checked once, using max height).
    private var shouldExpandDown: Bool {
        viewModel.expandsDown
    }

    /// The overlay alignment based on current expansion direction.
    private var overlayAlignment: Alignment {
        switch (shouldExpandRight, shouldExpandDown) {
        case (true, true):   return .topLeading
        case (false, true):  return .topTrailing
        case (true, false):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: overlayAlignment) {
                ZStack(alignment: .topLeading) {
                    switch viewModel.state {
                    case .idle:
                        Color.clear.frame(width: 16, height: 16)
                    case .monitoring:
                        MonitoringIndicator()
                    case .codeReady(let code):
                        CodeReadyCursor(code: code)
                    case .input:
                        VStack(alignment: .leading, spacing: 0) {
                            // Attachment preview in input mode
                            if !viewModel.attachedImages.isEmpty {
                                AttachmentStripView(
                                    images: viewModel.attachedImages,
                                    onRemove: { index in viewModel.removeAttachment(at: index) }
                                )
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                            }
                            InputBar(
                                text: $viewModel.inputText,
                                onSubmit: { viewModel.send() },
                                onCancel: { viewModel.dismiss() },
                                onScreenshot: { viewModel.requestScreenshot() }
                            )
                        }
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
                            onDismiss: { viewModel.dismiss() },
                            attachedImages: viewModel.attachedImages,
                            onRemoveAttachment: { index in viewModel.removeAttachment(at: index) },
                            onScreenshot: { viewModel.requestScreenshot() }
                        )
                    }
                }
                .frame(width: shapeWidth, alignment: .topLeading)
                .clipShape(PointerShape(radius: 12))
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(PointerShape(radius: 12))
                        PointerShape(radius: 12)
                            .fill(Color.black.opacity(viewModel.state.isExpanded ? 0.3 : 0.1))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)
                )
                .overlay(PointerShape(radius: 12).stroke(Color.white, lineWidth: 2))
                .padding(14) // Offset from panel edge = shadow padding
            }
            .onChange(of: shouldExpandRight) { _, newValue in
                viewModel.expandsRight = newValue
                viewModel.onExpansionDirectionChanged?()
            }
            .animation(
                viewModel.state == .idle
                    ? .easeOut(duration: 0.25)                          // collapse: bezier, no bounce
                    : .spring(response: 0.293, dampingFraction: 0.793), // expand: mass=1, damping=34, stiffness=460
                value: viewModel.state
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: inputBarWidth)
            .animation(.spring(response: 0.293, dampingFraction: 0.793), value: viewModel.attachedImages.count)
    }
}
