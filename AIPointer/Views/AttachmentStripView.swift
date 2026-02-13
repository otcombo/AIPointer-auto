import SwiftUI

/// Horizontal strip of screenshot thumbnails with delete buttons on hover.
struct AttachmentStripView: View {
    let images: [SelectedRegion]
    var onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, region in
                    ThumbnailView(region: region, index: index, onRemove: onRemove)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }
}

/// Individual thumbnail with hover-triggered delete button.
private struct ThumbnailView: View {
    let region: SelectedRegion
    let index: Int
    var onRemove: (Int) -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = region.snapshot {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 48, height: 36)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.3))
                    )
            }

            if isHovered {
                Button(action: { onRemove(index) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .background(Color.black.opacity(0.6).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
