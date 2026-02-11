import SwiftUI

struct StatusIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Reuse the same pointer shape as default cursor
            PointerShape(radius: 12)
                .fill(Color.black.opacity(0.95))
                .overlay(
                    PointerShape(radius: 12)
                        .stroke(Color.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)

            // Spinning dots inside the cursor area
            TimelineView(.animation(minimumInterval: 0.08)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 4
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2 + 2, y: size.height / 2 + 2)
                    let dotCount = 4
                    let orbitRadius: CGFloat = 3.5

                    for i in 0..<dotCount {
                        let angle = phase + Double(i) * (.pi * 2 / Double(dotCount))
                        let x = center.x + orbitRadius * cos(angle)
                        let y = center.y + orbitRadius * sin(angle)
                        let opacity = 1.0 - (Double(i) * 0.2)
                        let dotSize: CGFloat = 2

                        let rect = CGRect(
                            x: x - dotSize / 2,
                            y: y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.white.opacity(opacity))
                        )
                    }
                }
            }
        }
        .frame(width: 16, height: 16)
    }
}

#Preview {
    StatusIndicator()
        .padding(40)
        .background(Color.gray)
}
