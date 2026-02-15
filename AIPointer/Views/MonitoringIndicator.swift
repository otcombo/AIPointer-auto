import SwiftUI

/// Teardrop cursor with a radio waves icon when monitoring for a verification code.
/// Size: 24x24, icon is dot.radiowaves.up.forward rotated 90° CW.
/// Breathe animation: opacity pulses between 0.4 and 1.0.
struct MonitoringIndicator: View {
    var body: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: 14.5, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .white,
                        Color(red: 1.0, green: 0.75, blue: 0.0)  // #FFBC00
                    ]),
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
            .symbolEffect(.breathe)
            .rotationEffect(.degrees(90))
            .offset(x: -2.5, y: -2.5)
            .frame(width: 24, height: 24)
    }
}

#Preview {
    MonitoringIndicator()
        .padding(40)
        .background(Color.gray)
}
