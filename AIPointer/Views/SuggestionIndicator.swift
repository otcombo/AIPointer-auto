import SwiftUI

/// Teardrop cursor with a lightbulb icon when a behavior suggestion is active.
/// Size: 24x24, icon is lightbulb.fill with breathe animation.
struct SuggestionIndicator: View {
    var body: some View {
        Image(systemName: "lightbulb.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .symbolEffect(.breathe)
            .frame(width: 24, height: 24)
    }
}

#Preview {
    SuggestionIndicator()
        .padding(40)
        .background(Color.gray)
}
