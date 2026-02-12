import SwiftUI

/// Breathing dot overlay on the teardrop cursor when monitoring for a verification code.
struct MonitoringIndicator: View {
    @State private var opacity: Double = 0.3

    var body: some View {
        ZStack {
            PointerShape(radius: 12)
                .fill(Color.black.opacity(0.95))
                .overlay(
                    PointerShape(radius: 12)
                        .stroke(Color.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)

            // Breathing dot: centered slightly toward bottom-right (like StatusIndicator)
            Circle()
                .fill(Color.green)
                .frame(width: 4, height: 4)
                .offset(x: 2, y: 2)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        opacity = 1.0
                    }
                }
        }
        .frame(width: 16, height: 16)
    }
}

#Preview {
    MonitoringIndicator()
        .padding(40)
        .background(Color.gray)
}
