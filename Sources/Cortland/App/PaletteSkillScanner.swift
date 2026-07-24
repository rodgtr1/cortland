import Foundation

/// One agent skill tagged for the ⇧⌘P command palette.
///
/// Skills live in the agents' own directories (`~/.claude/skills`, a
/// workspace's `.claude/skills`) and run entirely inside the agent CLI; the
/// palette is only a launcher that types the slash command into the focused
/// pane. Which skills appear is declared in the skill itself — a
/// `cortland-palette: true` line in its SKILL.md frontmatter — so installing
/// or untagging a skill needs no app change, and the many skills that have
/// nothing to do with Cortland stay out of the list.
nonisolated struct PaletteSkill: Equatable {
    /// The slash-command name, e.g. "stage-and-commit" → `/stage-and-commit`.
    let name: String
    /// Palette row title. `cortland-palette-label` when given, otherwise the
    /// name with hyphens spaced and words capitalized.
    let title: String
    /// True for argument-less skills (`cortland-palette-submit: true`): the
    /// palette sends Enter after the command instead of leaving the cursor in
    /// the pane for arguments.
    let submit: Bool
}

nonisolated enum PaletteSkillScanner {
    /// Frontmatter keys. Flat custom keys rather than a nested table because
    /// agent CLIs ignore unknown SKILL.md keys, and flat lines keep the
    /// parser a line scanner instead of a YAML dependency.
    private static let paletteKey = "cortland-palette"
    private static let submitKey = "cortland-palette-submit"
    private static let labelKey = "cortland-palette-label"

    /// The same keys under the app's former name. These live in files the user
    /// wrote — their own skills, in their own directories — so the rename can't
    /// reach them, and dropping support would empty the palette for everyone who
    /// had tagged anything, with no error to explain it. Both spellings are
    /// read; the current one wins where a file carries both.
    private static let legacyPrefix = "sidekick-palette"

    /// Collects tagged skills from `<root>/<skill>/SKILL.md` across the given
    /// roots, sorted by title. On a name collision the later root wins, so
    /// callers pass roots in precedence order (user first, workspace last) —
    /// the same shadowing rule the agents apply.
    static func scan(roots: [URL], fileManager: FileManager = .default) -> [PaletteSkill] {
        var byName: [String: PaletteSkill] = [:]
        for root in roots {
            let subdirectories = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for directory in subdirectories {
                let skillFile = directory.appendingPathComponent("SKILL.md")
                guard let contents = try? String(contentsOf: skillFile, encoding: .utf8),
                      let skill = parse(contents, fallbackName: directory.lastPathComponent) else {
                    continue
                }
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.title < $1.title }
    }

    /// Reads a SKILL.md's frontmatter and returns the skill if it carries the
    /// palette tag. Nil for untagged skills, files without frontmatter, and
    /// anything else — a skill that can't be parsed just doesn't appear.
    static func parse(_ contents: String, fallbackName: String) -> PaletteSkill? {
        var fields: [String: String] = [:]
        var insideFrontmatter = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "---" {
                if insideFrontmatter { break }
                insideFrontmatter = true
                continue
            }
            // Anything before the opening fence means no frontmatter at all.
            guard insideFrontmatter else { return nil }
            // Only top-level `key: value` lines; indented lines belong to
            // nested YAML we don't traffic in.
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        /// The current key's value, falling back to the pre-rename spelling.
        func value(_ key: String) -> String? {
            fields[key] ?? fields[key.replacingOccurrences(of: "cortland-palette", with: legacyPrefix)]
        }

        guard value(paletteKey) == "true" else { return nil }
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return PaletteSkill(
            name: name,
            title: value(labelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle(for: name),
            submit: value(submitKey) == "true"
        )
    }

    /// "stage-and-commit" → "Stage And Commit".
    private static func defaultTitle(for name: String) -> String {
        name.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
