import SwiftUI

/// Expanded teardrop cursor displaying a verification code.
/// The cursor widens horizontally to fit the code digits (like the input bar expansion).
struct CodeReadyCursor: View {
    let code: String

    private var cursorWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textWidth = (code as NSString).size(withAttributes: [.font: font]).width
        return max(textWidth + 20, 16)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PointerShape(radius: 12)
                .fill(Color.black.opacity(0.95))
                .overlay(
                    PointerShape(radius: 12)
                        .stroke(Color.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)

            Text(code)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 6)
                .padding(.top, 3)
        }
        .frame(width: cursorWidth, height: 16)
    }
}

#Preview {
    VStack(spacing: 20) {
        CodeReadyCursor(code: "384729")
        CodeReadyCursor(code: "1234")
    }
    .padding(40)
    .background(Color.gray)
}
