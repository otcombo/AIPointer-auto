import SwiftUI

/// Expanded teardrop cursor displaying a verification code.
/// Padding matches InputBar (.horizontal 10, .vertical 8) so the two states feel consistent.
struct CodeReadyCursor: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

#Preview {
    VStack(spacing: 20) {
        CodeReadyCursor(code: "345679")
        CodeReadyCursor(code: "1234")
        CodeReadyCursor(code: "38472918")
    }
    .padding(40)
    .background(Color.gray)
}
