import SwiftUI

struct OrangeIndicator: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(red: 0xEC / 255, green: 0x68 / 255, blue: 0x2C / 255)) // #EC682C
            .frame(width: 2, height: 14)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

struct InputBar: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var attachmentCount: Int = 0
    var onScreenshot: (() -> Void)? = nil

    private var barWidth: CGFloat {
        if text.isEmpty { return 60 }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        // text width + horizontal padding (10*2) + some breathing room (20)
        return min(max(textWidth + 40, 60), 440)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Attachment count badge
            if attachmentCount > 0 {
                Text("\(attachmentCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            AppKitTextField(
                text: $text,
                onSubmit: onSubmit,
                onCancel: onCancel
            )

            // Camera button
            if let onScreenshot = onScreenshot {
                Button(action: onScreenshot) {
                    Image(systemName: "camera")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        InputBar(text: .constant(""), onSubmit: {}, onCancel: {})
        InputBar(text: .constant("show me today's todo"), onSubmit: {}, onCancel: {}, attachmentCount: 2, onScreenshot: {})
    }
    .padding(40)
    .background(Color.gray)
}
