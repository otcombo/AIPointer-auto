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
    var onScreenshot: (() -> Void)? = nil

    @State private var isHovering = false

    private var barWidth: CGFloat {
        if text.isEmpty { return 100 }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        // text width + horizontal padding (10*2) + some breathing room (20)
        return min(max(textWidth + 40, 60), 440)
    }

    var body: some View {
        HStack(spacing: 4) {
            AppKitTextField(
                text: $text,
                onSubmit: onSubmit,
                onCancel: onCancel
            )

            // Screenshot button — visible on hover only
            if let onScreenshot = onScreenshot, isHovering {
                Button(action: onScreenshot) {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(14)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        InputBar(text: .constant(""), onSubmit: {}, onCancel: {})
        InputBar(text: .constant("show me today's todo"), onSubmit: {}, onCancel: {}, onScreenshot: {})
    }
    .padding(40)
    .background(Color.gray)
}
