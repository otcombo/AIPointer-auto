import SwiftUI

/// Horizontal strip of screenshot thumbnails with delete buttons.
struct AttachmentStripView: View {
    let images: [SelectedRegion]
    var onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, region in
                    thumbnailView(region: region, index: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func thumbnailView(region: SelectedRegion, index: Int) -> some View {
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

            // Delete button
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
}
