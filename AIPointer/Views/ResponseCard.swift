import SwiftUI

/// Combined panel showing response text + input field.
/// Used for thinking, responding, and response states.
struct ChatPanel: View {
    let chatHistory: [ChatMessage]
    let responseText: String
    let isThinking: Bool
    let isStreaming: Bool
    @Binding var inputText: String
    var onSubmit: () -> Void
    var onDismiss: () -> Void
    var attachedImages: [SelectedRegion] = []
    var onRemoveAttachment: ((Int) -> Void)? = nil
    var onScreenshot: (() -> Void)? = nil

    @State private var isHoveringInput = false
    @State private var isHoveringIcon = false

    /// History excluding the last assistant message if it duplicates the current responseText.
    private var displayHistory: [ChatMessage] {
        if let last = chatHistory.last,
           last.role == .assistant,
           last.text == responseText {
            return Array(chatHistory.dropLast())
        }
        return chatHistory
    }

    private var hasHistory: Bool {
        !displayHistory.isEmpty
    }

    private var hasContent: Bool {
        hasHistory || !responseText.isEmpty || isThinking
    }

    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Combined history + current response area
            if hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Past messages
                            ForEach(Array(displayHistory.enumerated()), id: \.element.id) { index, message in
                                let prevRole = index > 0 ? displayHistory[index - 1].role : nil
                                let spacing: CGFloat = prevRole == nil ? 0 : (prevRole != message.role ? 24 : 12)

                                markdownText(message.text)
                                    .font(.custom("SF Compact Text", size: 14).weight(.regular))
                                    .lineSpacing(4)
                                    .foregroundColor(.white.opacity(message.role == .user ? 0.5 : 0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, spacing)
                            }

                            // Current live response
                            if !responseText.isEmpty {
                                let lastRole = displayHistory.last?.role
                                let spacing: CGFloat = lastRole == nil ? 0 : (lastRole == .user ? 24 : 12)

                                markdownText(responseText)
                                    .font(.custom("SF Compact Text", size: 14).weight(.regular))
                                    .lineSpacing(4)
                                    .foregroundColor(.white)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, spacing)
                            }

                            // Thinking indicator
                            if isThinking {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .symbolEffect(.breathe)
                                    .padding(.top, displayHistory.isEmpty ? 0 : 24)
                            }

                            Color.clear.frame(height: 0).id("bottom")
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: responseText) { _, _ in
                        if isStreaming {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: displayHistory.count) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .frame(maxHeight: 200)
            }

            // Attachment preview strip
            if !attachedImages.isEmpty {
                AttachmentStripView(
                    images: attachedImages,
                    onRemove: { index in onRemoveAttachment?(index) }
                )
            }

            // Separator above input field (only when there's content above)
            if hasContent || !attachedImages.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
            }

            // Input field with screenshot button (visible on hover)
            AppKitTextField(
                text: $inputText,
                placeholder: "Ask anything...",
                onSubmit: onSubmit,
                onCancel: onDismiss,
                isDisabled: isThinking || isStreaming,
                autoFocus: !(isThinking || isStreaming)
            )
            .overlay(alignment: .trailing) {
                if let onScreenshot = onScreenshot, !(isThinking || isStreaming), isHoveringInput {
                    Button(action: onScreenshot) {
                        Image(systemName: "plus.viewfinder")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                            .symbolEffect(.scale.up.byLayer, isActive: isHoveringIcon)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .onHover { isHoveringIcon = $0 }
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringInput = hovering
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(minWidth: 200, maxWidth: 440)
    }
}
