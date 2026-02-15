import Foundation

/// Shared provider for installed OpenClaw skills.
/// Reads skill names and descriptions from the skills directory.
struct InstalledSkillsProvider {
    struct Skill: Identifiable {
        let id: String  // same as name
        let name: String
        let description: String
    }

    static let skillsDir = "/opt/homebrew/lib/node_modules/openclaw/skills"

    static func load() -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) else {
            return []
        }

        var skills: [Skill] = []

        for entry in entries.sorted() {
            let skillMdPath = "\(skillsDir)/\(entry)/SKILL.md"
            guard FileManager.default.fileExists(atPath: skillMdPath),
                  let content = try? String(contentsOfFile: skillMdPath, encoding: .utf8) else { continue }

            var description = ""
            for line in content.components(separatedBy: "\n").prefix(10) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix(">") && !trimmed.hasPrefix("---") {
                    description = trimmed
                    break
                }
            }
            skills.append(Skill(id: entry, name: entry, description: description))
        }

        return skills
    }

    /// Filter skills by query (fuzzy match on name).
    static func filter(_ skills: [Skill], query: String) -> [Skill] {
        guard !query.isEmpty else { return skills }
        let q = query.lowercased()
        return skills.filter { $0.name.lowercased().contains(q) }
    }
}
