import Foundation

/// A small, lossy description for message generation only. Never use this for
/// change detection: the local commit fingerprint must retain the full diffs.
public enum CommitDiffSummary {
    private struct FileDiff {
        let stage: String
        let lines: [Substring]
        var header: String { String(lines.first ?? "") }
        var isNew: Bool { lines.contains { $0.hasPrefix("new file mode ") } }
        var isDeleted: Bool { lines.contains { $0.hasPrefix("deleted file mode ") } }
        var changes: [Substring] {
            lines.filter {
                ($0.hasPrefix("+") && !$0.hasPrefix("+++")) ||
                ($0.hasPrefix("-") && !$0.hasPrefix("---"))
            }
        }
    }

    public static func limited(_ value: String, to limit: Int) -> String {
        let note = "\n[Further content omitted locally.]"
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - note.count))) + String(note.prefix(limit))
    }

    public static func context(status: String, staged: String, unstaged: String) -> String {
        let files = parse(staged, stage: "staged") + parse(unstaged, stage: "unstaged")
        // An added file can also have unstaged edits; neither side should send its contents.
        let newFiles = Set(files.filter(\.isNew).map(\.header))
        let occurrences = Dictionary(grouping: files, by: \.header).mapValues(\.count)
        var summaries: [String] = []
        var excerpts: [String] = []
        var remainingExcerptCharacters = 6_000
        for file in files {
            let changes = file.changes
            let added = changes.filter { $0.hasPrefix("+") }.count
            let removed = changes.count - added
            let summaryOnly = newFiles.contains(file.header) || file.isDeleted
            let note = summaryOnly ? " (contents omitted)" : ""
            summaries.append("\(file.stage): \(file.header) (+\(added)/-\(removed))\(note)")
            guard !summaryOnly, remainingExcerptCharacters > 100 else { continue }
            // Retain rename/mode/binary metadata and hunk locations, but discard context lines.
            let detail = file.lines.dropFirst().filter {
                !$0.hasPrefix("index ") && !$0.hasPrefix("--- ") &&
                !$0.hasPrefix("+++ ") && !$0.hasPrefix(" ")
            }.joined(separator: "\n")
            // Share each file's allowance across staged and unstaged edits.
            let perOccurrenceLimit = 1_200 / (occurrences[file.header] ?? 1)
            let separatorCount = excerpts.isEmpty ? 0 : 2
            let excerpt = bookendedExcerpt("\(file.stage): \(file.header)\n\(detail)", limit: min(perOccurrenceLimit, remainingExcerptCharacters - separatorCount))
            excerpts.append(excerpt)
            remainingExcerptCharacters -= excerpt.count + separatorCount
        }
        return """
        GIT STATUS (paths only; may be shortened)
        \(limited(status, to: 2_500))

        FILE SUMMARY (line counts; may be shortened)
        \(limited(summaries.joined(separator: "\n"), to: 2_500))

        SELECTED DIFF EXCERPTS (up to 1,200 characters per file; other content omitted)
        \(excerpts.joined(separator: "\n\n"))
        """
    }

    private static func bookendedExcerpt(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let note = "\n[Middle of diff omitted locally.]\n"
        let half = max(0, (limit - note.count) / 2)
        return String(value.prefix(half)) + note + String(value.suffix(half))
    }

    private static func parse(_ diff: String, stage: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var lines: [Substring] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                if !lines.isEmpty { files.append(FileDiff(stage: stage, lines: lines)) }
                lines = [line]
            } else if !lines.isEmpty {
                lines.append(line)
            }
        }
        if !lines.isEmpty { files.append(FileDiff(stage: stage, lines: lines)) }
        return files
    }
}
