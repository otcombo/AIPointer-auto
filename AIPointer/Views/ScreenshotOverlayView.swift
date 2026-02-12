import SwiftUI

/// SwiftUI rendering layer for screenshot selection overlays.
/// Uses `allowsHitTesting(false)` so mouse events pass through to the NSView below.
struct ScreenshotOverlayView: View {
    @ObservedObject var viewModel: ScreenshotViewModel
    let screenFrame: NSRect

    /// Height of the main screen (for Quartz coordinate conversion).
    private var mainScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? screenFrame.height
    }

    var body: some View {
        ZStack {
            // Semi-transparent dark overlay
            Color.black.opacity(0.3)

            // Render completed regions
            ForEach(Array(viewModel.regions.enumerated()), id: \.element.id) { index, region in
                regionOverlay(region.rect, index: index + 1)
            }

            // Render current drag rectangle
            if let dragRect = viewModel.currentDragRect {
                let local = quartzToLocal(dragRect)
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.blue.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Color.blue, lineWidth: 2)
                    )
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)
            }

            // Bottom instruction bar
            VStack {
                Spacer()
                instructionBar
                    .padding(.bottom, 40)
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
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.blue.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(Color.blue, lineWidth: 2)
                )
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

    private var instructionBar: some View {
        HStack(spacing: 16) {
            shortcutHint(key: "Drag", label: "Select area")
            shortcutHint(key: "⌫", label: "Undo last")
            shortcutHint(key: "⏎", label: "Confirm")
            shortcutHint(key: "Esc", label: "Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var regionCounter: some View {
        Text("\(viewModel.regions.count)/\(ScreenshotViewModel.maxRegions) regions")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
