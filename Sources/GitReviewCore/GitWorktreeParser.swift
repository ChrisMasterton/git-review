import Foundation

public struct GitWorktree: Equatable, Sendable {
    public let path: URL
    public let branch: String?
    public let head: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let lockReason: String?
    public let pruneReason: String?

    public init(
        path: URL, branch: String? = nil, head: String? = nil,
        isBare: Bool = false, isDetached: Bool = false,
        lockReason: String? = nil, pruneReason: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isBare = isBare
        self.isDetached = isDetached
        self.lockReason = lockReason
        self.pruneReason = pruneReason
    }
}

public enum GitWorktreeParser {
    public enum ParseError: Error { case invalidOutput }

    /// Parses `git worktree list --porcelain -z`. NUL delimiters preserve spaces,
    /// newlines, and Unicode in paths and lock reasons without Git unquoting.
    public static func parse(_ output: String) throws -> [GitWorktree] {
        guard output.contains("\0") else { throw ParseError.invalidOutput }
        var result: [GitWorktree] = []
        var fields: [String: String] = [:]

        func finishRecord() throws {
            guard !fields.isEmpty else { return }
            guard let path = fields["worktree"], path.hasPrefix("/"),
                  fields["bare"] != nil || fields["HEAD"] != nil else {
                throw ParseError.invalidOutput
            }
            let ref = fields["branch"]
            result.append(GitWorktree(
                path: URL(fileURLWithPath: path),
                branch: ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 },
                head: fields["HEAD"],
                isBare: fields["bare"] != nil,
                isDetached: fields["detached"] != nil,
                lockReason: fields["locked"],
                pruneReason: fields["prunable"]
            ))
            fields = [:]
        }

        for attribute in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if attribute.isEmpty {
                try finishRecord()
                continue
            }
            let parts = attribute.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            if fields.isEmpty && key != "worktree" { throw ParseError.invalidOutput }
            if fields[key] != nil { throw ParseError.invalidOutput }
            fields[key] = parts.count == 2 ? String(parts[1]) : ""
        }
        try finishRecord()
        guard !result.isEmpty else { throw ParseError.invalidOutput }
        return result
    }
}
