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

    var body: some View {
        AppKitTextField(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 60, minHeight: 30, maxHeight: 30)
        .background(
            PointerShape(radius: 12)
                .fill(Color.black.opacity(0.95))
        )
        .overlay(
            PointerShape(radius: 12)
                .stroke(Color.white, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)
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
