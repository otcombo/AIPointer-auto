import SwiftUI

/// Asymmetric rounded rectangle: top-left corner is sharp (0 radius), other 3 corners are rounded.
/// This creates a pointer/tooltip shape where top-left is the hotspot.
struct PointerShape: Shape {
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var path = Path()

        // Start at top-left (sharp corner — the pointer tip)
        path.move(to: CGPoint(x: 0, y: 0))

        // Top edge → top-right rounded corner
        path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: r),
            radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )

        // Right edge → bottom-right rounded corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )

        // Bottom edge → bottom-left rounded corner
        path.addLine(to: CGPoint(x: r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )

        // Left edge → back to top-left (sharp)
        path.addLine(to: CGPoint(x: 0, y: 0))

        path.closeSubpath()
        return path
    }
}

struct TeardropCursor: View {
    var body: some View {
        PointerShape(radius: 12)
            .fill(Color.black.opacity(0.95))
            .overlay(
                PointerShape(radius: 12)
                    .stroke(Color.white, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)
            .frame(width: 16, height: 16)
    }
}

struct TeardropIcon: View {
    var body: some View {
        PointerShape(radius: 6)
            .fill(Color.black.opacity(0.95))
            .overlay(
                PointerShape(radius: 6)
                    .stroke(Color.white, lineWidth: 1)
            )
            .frame(width: 10, height: 10)
    }
}

#Preview {
    VStack(spacing: 20) {
        TeardropCursor()
        TeardropIcon()
    }
    .padding(40)
    .background(Color.gray)
}
