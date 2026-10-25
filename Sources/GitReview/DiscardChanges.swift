import Foundation
import GitReviewCore

struct DiscardRequest: Identifiable {
    let id = UUID()
    let repository: RepositorySnapshot
    let change: GitFileChange

    var explanation: String {
        if change.isUntracked {
            return "Move this untracked item to Trash, including its contents if it is a directory. You can recover it from Finder’s Trash."
        }
        if change.indexStatus == "R", let original = change.originalPath {
            return "Undo this rename and restore both \(change.path) and \(original) to the last commit, discarding staged and unstaged changes to both paths. This cannot be undone in Git Review."
        }
        return "Restore this item to the last commit, discarding its staged and unstaged changes. Newly added files will be removed. This cannot be undone in Git Review."
    }
}

enum DiscardChanges {
    @discardableResult
    static func discard(repository: RepositorySnapshot, change: GitFileChange) throws -> URL? {
        guard !change.isSubmodule else {
            throw CommitFlowError.command("Open this submodule as a repository to discard its individual files.")
        }
        try CommitService.requireCheckout(repository)
        _ = try CommitService.currentBranch(for: repository, allowDetached: true)
        let prefix = ["--literal-pathspecs", "-C", repository.path.path]
        let status = GitCommand.run(prefix + ["status", "--porcelain=v2", "-z", "--untracked-files=normal"])
        guard status.exitCode == 0 else { throw CommitFlowError.command(status.error) }
        guard GitStatusParser.parse(status.output).changes.contains(change) else {
            throw CommitFlowError.command("This item's Git status changed. Refresh and review it again before discarding.")
        }
        func validate(_ path: String) throws -> URL {
            guard !path.isEmpty, !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" || $0 == "." }) else {
                throw CommitFlowError.command("This path cannot be discarded safely.")
            }
            let target = repository.path.appendingPathComponent(path)
            let parent = GitPath.canonical(target.deletingLastPathComponent()).path
            guard parent == repository.path.path || parent.hasPrefix(repository.path.path + "/") else {
                throw CommitFlowError.command("The item's parent is outside this checkout.")
            }
            return target
        }
        let target = try validate(change.path)
        if change.isUntracked {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
            return trashed as URL?
        }
        var paths = [change.path]
        if change.indexStatus == "R", let original = change.originalPath {
            _ = try validate(original)
            paths.append(original)
        }
        let head = GitCommand.run(prefix + ["rev-parse", "--verify", "HEAD"])
        let arguments: [String]
        if head.exitCode == 0 {
            arguments = ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths
        } else {
            guard change.indexStatus == "A" else { throw CommitFlowError.command("There is no committed version to restore.") }
            arguments = ["rm", "--force", "--"] + paths
        }
        let result = GitCommand.run(prefix + arguments)
        guard result.exitCode == 0 else { throw CommitFlowError.command(result.error) }
        return nil
    }
}
