import SwiftUI

/// Teardrop cursor with a radio waves icon when monitoring for a verification code.
/// Size: 24x24, icon is dot.radiowaves.up.forward rotated 90° CW.
/// Breathe animation: opacity pulses between 0.4 and 1.0.
struct MonitoringIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .opacity(opacity)
            .rotationEffect(.degrees(90))
            .frame(width: 24, height: 24)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}

#Preview {
    MonitoringIndicator()
        .padding(40)
        .background(Color.gray)
}
