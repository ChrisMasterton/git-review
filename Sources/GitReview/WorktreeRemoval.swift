import Foundation
import GitReviewCore

enum WorktreeRemoval {
    static func disabledReason(for checkout: RepositorySnapshot) -> String? {
        if checkout.path == checkout.repositoryPath { return "The main checkout cannot be removed." }
        if checkout.worktree.lockReason != nil { return "Unlock this worktree in Git before removing it." }
        if checkout.worktreeDiscoveryError != nil { return "Refresh to resolve incomplete worktree discovery first." }
        if !checkout.canAccessCheckout && !checkout.isUnavailable { return "Resolve the checkout's Git error first." }
        return nil
    }

    /// Git prune removes administrative registrations only; unlike worktree
    /// remove it cannot delete a checkout restored while cleanup is running.
    static func clearMissingRegistrations(_ checkouts: [RepositorySnapshot]) throws -> [String] {
        guard let checkout = checkouts.first,
              checkouts.allSatisfy({ $0.commonDirectory == checkout.commonDirectory && $0.worktreeDiscoveryError == nil }) else {
            throw CommitFlowError.command("Refresh before clearing registrations from this repository.")
        }
        let prefix = ["--git-dir", checkout.commonDirectory.path]
        func registrations() throws -> [GitWorktree] {
            let result = GitCommand.run(prefix + ["worktree", "list", "--porcelain", "-z"])
            guard result.exitCode == 0 else { throw CommitFlowError.command(result.error) }
            return try GitWorktreeParser.parse(result.output)
        }
        let before = try registrations()
        let requested = Set(checkouts.map(\.id))
        let lockReason = "Git Review cleanup " + UUID().uuidString
        var temporaryLocks: [String] = []
        var removed: [String] = []
        var failures: [String] = []
        do {
            // Prune can mistake inaccessible .git files for missing ones. Protect
            // every other registration using Git's own lock mechanism first.
            for worktree in before.dropFirst() where worktree.lockReason == nil {
                let path = GitPath.canonical(worktree.path)
                if requested.contains(path.path) && CheckoutFolder.isMissing(path) { continue }
                // Git's registered spelling remains usable even when permission
                // errors prevent resolving /var versus /private/var aliases.
                let registeredPath = worktree.path.path
                let lock = GitCommand.run(prefix + ["worktree", "lock", "--reason", lockReason, registeredPath])
                guard lock.exitCode == 0 else {
                    throw CommitFlowError.command("Could not protect \(registeredPath) during cleanup. " + lock.error)
                }
                temporaryLocks.append(registeredPath)
            }
            let result = GitCommand.run(prefix + ["worktree", "prune", "--expire", "now"])
            guard result.exitCode == 0 else { throw CommitFlowError.command(result.error) }
            let after = Set(try registrations().map { GitPath.canonical($0.path).path })
            removed = Array(Set(before.map { GitPath.canonical($0.path).path }).subtracting(after))
        } catch { failures.append(error.localizedDescription) }
        do {
            let current = try registrations()
            for path in temporaryLocks where current.contains(where: { $0.path.path == path && $0.lockReason == lockReason }) {
                let result = GitCommand.run(prefix + ["worktree", "unlock", path])
                if result.exitCode != 0 {
                    failures.append("Could not release the temporary lock at \(path). Use git worktree unlock for this path. " + result.error)
                }
            }
        } catch {
            failures.append("Could not verify temporary locks after cleanup: " + temporaryLocks.joined(separator: ", ") + ". " + error.localizedDescription)
        }
        guard failures.isEmpty else { throw CommitFlowError.command(failures.joined(separator: "\n")) }
        return removed
    }

    static func remove(_ checkout: RepositorySnapshot, discardChanges: Bool = false) throws -> String {
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
        // A confirmed individual removal may discard checkout files. One force
        // flag permits dirty removal; locked worktrees remain protected.
        let result = GitCommand.run(prefix + ["worktree", "remove"]
            + (discardChanges ? ["--force"] : []) + ["--", checkout.path.path])
        guard result.exitCode == 0 else {
            throw CommitFlowError.command(result.error.isEmpty ? "Git could not safely remove this worktree." : result.error)
        }
        return "Removed worktree at \(checkout.path.path)"
    }
}
