import SwiftUI

/// Combined panel showing response text + input field.
/// Used for thinking, responding, and response states.
struct ChatPanel: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Response area
            if !responseText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(responseText)
                            .font(.custom("SF Compact Text", size: 12).weight(.medium))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .onChange(of: responseText) { _, _ in
                        if isStreaming {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(maxHeight: 200)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }

            // Thinking indicator
            if isThinking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Thinking...")
                        .font(.custom("SF Compact Text", size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            // Attachment preview strip
            if !attachedImages.isEmpty {
                AttachmentStripView(
                    images: attachedImages,
                    onRemove: { index in onRemoveAttachment?(index) }
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }

            // Input field with screenshot button (visible on hover)
            HStack(spacing: 4) {
                AppKitTextField(
                    text: $inputText,
                    placeholder: "Ask anything...",
                    onSubmit: onSubmit,
                    onCancel: onDismiss,
                    isDisabled: isThinking || isStreaming,
                    autoFocus: !(isThinking || isStreaming)
                )

                if let onScreenshot = onScreenshot, !(isThinking || isStreaming), isHoveringInput {
                    Button(action: onScreenshot) {
                        Image(systemName: "plus.viewfinder")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringInput = hovering
                }
            }
        }
        .frame(minWidth: 200, maxWidth: 440)
    }
}
