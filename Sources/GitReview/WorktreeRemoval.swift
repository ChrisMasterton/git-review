import Foundation
import GitReviewCore

enum WorktreeRemoval {
    static func disabledReason(for checkout: RepositorySnapshot) -> String? {
        if checkout.path == checkout.repositoryPath { return "The main checkout cannot be removed." }
        if checkout.worktree.lockReason != nil { return "Unlock this worktree in Git before removing it." }
        if checkout.worktreeDiscoveryError != nil { return "Refresh to resolve incomplete worktree discovery first." }
        if !checkout.changes.isEmpty { return "Commit or save the uncommitted files before removing this worktree." }
        if !checkout.canAccessCheckout && !checkout.isUnavailable { return "Resolve the checkout's Git error first." }
        return nil
    }

    static func remove(_ checkout: RepositorySnapshot) throws -> String {
        if let reason = disabledReason(for: checkout) { throw CommitFlowError.command(reason) }
        let prefix = ["--git-dir", checkout.commonDirectory.path]
        let listed = GitCommand.run(prefix + ["worktree", "list", "--porcelain", "-z"])
        guard listed.exitCode == 0,
              let registered = try? GitWorktreeParser.parse(listed.output),
              let target = registered.first(where: { GitPath.canonical($0.path) == checkout.path }),
              let main = registered.first,
              GitPath.canonical(main.path) != checkout.path, !target.isBare else {
            throw CommitFlowError.command("This linked worktree is no longer registered as expected. Refresh before removing it.")
        }
        guard target.lockReason == nil else {
            throw CommitFlowError.command("The worktree is locked. Nothing was removed.")
        }
        guard target.head == checkout.worktree.head,
              target.branch == checkout.worktree.branch,
              target.isDetached == checkout.worktree.isDetached else {
            throw CommitFlowError.command("The checkout changed since it was reviewed. Refresh before removing it.")
        }
        if FileManager.default.fileExists(atPath: checkout.path.path) {
            // Reject a replaced directory or a checkout falling back to its parent.
            try CommitService.requireCheckout(checkout)
        }
        if target.isDetached {
            guard let head = target.head else {
                throw CommitFlowError.command("Unable to verify the detached commit. Nothing was removed.")
            }
            let retained = GitCommand.run(prefix + [
                "for-each-ref", "--contains=\(head)", "--format=%(refname)",
                "refs/heads", "refs/remotes", "refs/tags"
            ])
            guard retained.exitCode == 0, !retained.output.isEmpty else {
                throw CommitFlowError.command("Create a branch at this detached HEAD before removing the worktree, so its commits remain reachable.")
            }
        }
        // Never force removal or prune other registrations. Git performs a fresh
        // dirty/submodule/lock check immediately before removing this one path.
        let result = GitCommand.run(prefix + ["worktree", "remove", "--", checkout.path.path])
        guard result.exitCode == 0 else {
            throw CommitFlowError.command(result.error.isEmpty ? "Git could not safely remove this worktree." : result.error)
        }
        return "Removed worktree at \(checkout.path.path)"
    }
}
