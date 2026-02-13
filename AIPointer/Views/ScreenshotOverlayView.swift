import SwiftUI

struct DarkOverlayWithCutouts: Shape {
    let cutouts: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for cutout in cutouts {
            path.addRect(cutout)
        }
        return path
    }
}

/// SwiftUI rendering layer for screenshot selection overlays.
/// Uses `allowsHitTesting(false)` so mouse events pass through to the NSView below.
struct ScreenshotOverlayView: View {
    @ObservedObject var viewModel: ScreenshotViewModel
    let screenFrame: NSRect

    /// Height of the main screen (for Quartz coordinate conversion).
    private var mainScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? screenFrame.height
    }

    private var allCutouts: [CGRect] {
        var rects = viewModel.regions.map { quartzToLocal($0.rect) }
        if let dragRect = viewModel.currentDragRect {
            rects.append(quartzToLocal(dragRect))
        }
        return rects
    }

    var body: some View {
        ZStack {
            // Dark overlay with cutouts for selected regions
            DarkOverlayWithCutouts(cutouts: allCutouts)
                .fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))

            // Render completed regions
            ForEach(Array(viewModel.regions.enumerated()), id: \.element.id) { index, region in
                regionOverlay(region.rect, index: viewModel.existingCount + index + 1)
            }

            // Render current drag rectangle
            if let dragRect = viewModel.currentDragRect {
                let local = quartzToLocal(dragRect)
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: local.width, height: local.height)

                    // Size label
                    Text("\(Int(dragRect.width)) × \(Int(dragRect.height))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(x: 0, y: -24)
                }
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
            }

            // Top-right region counter
            VStack {
                HStack {
                    Spacer()
                    regionCounter
                        .padding(.top, 20)
                        .padding(.trailing, 20)
                }
                Spacer()
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    // MARK: - Region rendering

    @ViewBuilder
    private func regionOverlay(_ rect: CGRect, index: Int) -> some View {
        let local = quartzToLocal(rect)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.blue, lineWidth: 2)
                .frame(width: local.width, height: local.height)

            // Number badge
            Text("\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(x: 4, y: 4)
        }
        .frame(width: local.width, height: local.height)
        .position(x: local.midX, y: local.midY)
    }

    // MARK: - Quartz → local view coordinate conversion

    /// Convert a Quartz rect (origin top-left of primary display) to local view coordinates.
    private func quartzToLocal(_ rect: CGRect) -> CGRect {
        // screenFrame is in AppKit coordinates (origin bottom-left of primary display)
        // Quartz origin is top-left of primary display
        let screenTopInQuartz = mainScreenHeight - screenFrame.maxY

        let localX = rect.origin.x - screenFrame.origin.x
        let localY = rect.origin.y - screenTopInQuartz

        return CGRect(x: localX, y: localY, width: rect.width, height: rect.height)
    }

    // MARK: - UI components

    private var regionCounter: some View {
        Text("\(viewModel.existingCount + viewModel.regions.count)/\(ScreenshotViewModel.maxRegions) regions")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
