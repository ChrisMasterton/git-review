import Foundation

public struct GitFileChange: Equatable, Sendable {
    public let path: String
    public let indexStatus: Character?
    public let workTreeStatus: Character?
    public let isUntracked: Bool
    public let isConflicted: Bool

    public init(
        path: String,
        indexStatus: Character?,
        workTreeStatus: Character?,
        isUntracked: Bool = false,
        isConflicted: Bool = false
    ) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
    }

    public var isStaged: Bool {
        guard let indexStatus else { return false }
        return indexStatus != "." && indexStatus != " " && indexStatus != "?"
    }

    public var isModified: Bool {
        guard let workTreeStatus else { return false }
        return workTreeStatus != "." && workTreeStatus != " " && workTreeStatus != "?"
    }
}

public struct ParsedGitStatus: Equatable, Sendable {
    public var branch = "HEAD"
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [GitFileChange] = []

    public init() {}

    public var stagedCount: Int { changes.filter(\.isStaged).count }
    public var modifiedCount: Int { changes.filter(\.isModified).count }
    public var untrackedCount: Int { changes.filter(\.isUntracked).count }
    public var conflictCount: Int { changes.filter(\.isConflicted).count }
}

public enum GitStatusParser {
    public static func parse(_ output: String) -> ParsedGitStatus {
        var result = ParsedGitStatus()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                result.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                result.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let values = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for value in values {
                    if value.hasPrefix("+") { result.ahead = Int(value.dropFirst()) ?? 0 }
                    if value.hasPrefix("-") { result.behind = Int(value.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("? ") {
                result.changes.append(GitFileChange(
                    path: String(line.dropFirst(2)),
                    indexStatus: nil,
                    workTreeStatus: nil,
                    isUntracked: true
                ))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                let xy = fields.count > 1 ? String(fields[1]) : "UU"
                result.changes.append(GitFileChange(
                    path: fields.count > 10 ? String(fields[10]) : "Unknown path",
                    indexStatus: xy.first,
                    workTreeStatus: xy.dropFirst().first,
                    isConflicted: true
                ))
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let maxSplits = line.hasPrefix("2 ") ? 9 : 8
                let fields = line.split(separator: " ", maxSplits: maxSplits, omittingEmptySubsequences: true)
                guard fields.count > maxSplits else { continue }
                let xy = String(fields[1])
                var path = String(fields[maxSplits])
                if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
                let conflictCodes = Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"])
                result.changes.append(GitFileChange(
                    path: path,
                    indexStatus: xy.first,
                    workTreeStatus: xy.dropFirst().first,
                    isConflicted: conflictCodes.contains(xy)
                ))
            }
        }

        return result
    }
}

public struct BranchTrackingStatus: Equatable, Sendable {
    public let name: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let isPublishedWithoutUpstream: Bool
    public let upstreamGone: Bool
    public let lastCommitDate: Date?
    public let lastCheckoutDate: Date?
    public let approximateCreatedDate: Date?

    public init(
        name: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        isPublishedWithoutUpstream: Bool = false,
        upstreamGone: Bool = false,
        lastCommitDate: Date? = nil,
        lastCheckoutDate: Date? = nil,
        approximateCreatedDate: Date? = nil
    ) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isPublishedWithoutUpstream = isPublishedWithoutUpstream
        self.upstreamGone = upstreamGone
        self.lastCommitDate = lastCommitDate
        self.lastCheckoutDate = lastCheckoutDate
        self.approximateCreatedDate = approximateCreatedDate
    }

    public var needsPush: Bool { upstreamGone || (upstream == nil && !isPublishedWithoutUpstream) || ahead > 0 }
}

public enum BranchTrackingParser {
    public static func parse(_ output: String) -> [BranchTrackingStatus] {
        output.split(separator: "\n").compactMap { rawLine in
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let upstream = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
            let track = fields.count > 2 ? fields[2] : ""
            let lastCommitDate = fields.count > 3
                ? TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:))
                : nil
            return BranchTrackingStatus(
                name: name,
                upstream: upstream,
                ahead: trackingCount(named: "ahead", in: track),
                behind: trackingCount(named: "behind", in: track),
                upstreamGone: track.localizedCaseInsensitiveContains("gone"),
                lastCommitDate: lastCommitDate
            )
        }
    }

    private static func trackingCount(named label: String, in value: String) -> Int {
        guard let range = value.range(of: "\(label) ") else { return 0 }
        let suffix = value[range.upperBound...]
        return Int(suffix.prefix { $0.isNumber }) ?? 0
    }
}

public enum BranchActivityParser {
    public static func lastCheckoutDates(
        _ output: String,
        branchNames: Set<String>
    ) -> [String: Date] {
        var dates: [String: Date] = [:]
        let prefix = "checkout: moving from "

        for rawLine in output.split(separator: "\n") {
            let fields = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let date = reflogDate(from: String(fields[0])) else { continue }
            let subject = String(fields[1])
            guard subject.hasPrefix(prefix) else { continue }
            let movement = String(subject.dropFirst(prefix.count))
            guard let separator = movement.range(of: " to ", options: .backwards) else { continue }
            let from = String(movement[..<separator.lowerBound])
            let to = String(movement[separator.upperBound...])
            for branch in [from, to] where branchNames.contains(branch) && dates[branch] == nil {
                dates[branch] = date
            }
        }

        return dates
    }

    public static func approximateCreationDate(_ output: String) -> Date? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let oldest = lines.last else { return nil }
        let fields = oldest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              String(fields[1]).localizedCaseInsensitiveContains("created from") else { return nil }
        return reflogDate(from: String(fields[0]))
    }

    private static func reflogDate(from selector: String) -> Date? {
        guard let opening = selector.range(of: "@{")?.upperBound,
              let closing = selector[opening...].firstIndex(of: "}") else { return nil }
        let value = selector[opening..<closing]
        guard let seconds = TimeInterval(value.prefix { $0.isNumber || $0 == "." }) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
