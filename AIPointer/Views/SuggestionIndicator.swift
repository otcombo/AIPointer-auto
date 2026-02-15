import SwiftUI

/// Teardrop cursor with a sparkles icon when a behavior suggestion is active.
/// Size: 24x24, sparkles.2 with gold-white gradient + bounce animation.
struct SuggestionIndicator: View {
    @State private var animate = false

    var body: some View {
        Image(systemName: "sparkles.2")
            .font(.system(size: 12, weight: .black))
            .rotationEffect(.degrees(90))
            .foregroundStyle(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .white,
                        Color(red: 1.0, green: 0.75, blue: 0.0)  // #FFBC00
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: animate)
            .frame(width: 24, height: 24)
            .onAppear {
                animate = true
            }
    }
}

#Preview {
    SuggestionIndicator()
        .padding(40)
        .background(Color.gray)
}
