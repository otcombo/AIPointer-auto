import SwiftUI

/// Floating completion list for `/skill` selection in the input bar.
struct SkillCompletionView: View {
    let skills: [InstalledSkillsProvider.Skill]
    let selectedIndex: Int
    let onSelect: (InstalledSkillsProvider.Skill) -> Void

    /// Show at most 3 skills at a time, centered around the selected index.
    private var visibleRange: Range<Int> {
        let total = skills.count
        guard total > 3 else { return 0..<total }
        let start = max(0, min(selectedIndex - 1, total - 3))
        return start..<(start + 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills[visibleRange].enumerated()), id: \.element.id) { offset, skill in
                let index = visibleRange.lowerBound + offset
                HStack(spacing: 8) {
                    Text("/\(skill.name)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index == selectedIndex ? Color.white.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(skill)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
