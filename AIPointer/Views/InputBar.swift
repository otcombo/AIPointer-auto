import SwiftUI

struct OrangeIndicator: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(red: 0xEC / 255, green: 0x68 / 255, blue: 0x2C / 255)) // #EC682C
            .frame(width: 2, height: 17)
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

    private var barWidth: CGFloat {
        if text.isEmpty { return 70 }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        // text width + horizontal padding (12*2) + some breathing room (20)
        return min(max(textWidth + 44, 70), 440)
    }

    var body: some View {
        AppKitTextField(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        InputBar(text: .constant(""), onSubmit: {}, onCancel: {})
        InputBar(text: .constant("show me today's todo"), onSubmit: {}, onCancel: {})
    }
    .padding(40)
    .background(Color.gray)
}
