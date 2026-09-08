import Foundation
import GitReviewCore

enum RepositoryScanner {
    /// Generated dependency folders that never contain user projects. These are
    /// skipped everywhere without looking inside. Dot-prefixed folders need no
    /// entry here because enumeration skips hidden files already.
    private static let alwaysSkippedDirectoryNames: Set<String> = [
        ".build", ".cache", ".gradle", ".idea", ".next", ".nuxt",
        ".swiftpm", ".terraform", ".venv", "DerivedData", "Pods", "coverage",
        "node_modules"
    ]

    /// Generic names that sometimes hold real projects. Skipped only when
    /// neither the folder itself nor its direct children contain a repository,
    /// so a checkout named `vendor` or a project at `vendor/service` is found.
    private static let conditionallySkippedDirectoryNames: Set<String> = [
        "Build", "Library", "Temp", "bin", "dist", "obj", "vendor"
    ]

    private struct Location: Sendable {
        let commonDirectory: URL
        let root: URL
        var paths: [URL]
        let error: String?
    }

    static func scan(
        roots: [URL], fetchRemotes: Bool, command: GitCommandRunner = .live
    ) async -> [RepositorySnapshot] {
        // Resolve identity before scheduling inspections: linked checkouts share
        // refs and must not fetch or enumerate branches concurrently with peers.
        var locations: [String: Location] = [:]
        for repository in discoverRepositories(in: roots) {
            let path = canonical(repository.path)
            let common = command.run(["-C", path.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let directory = common.exitCode == 0 && !common.output.isEmpty
                ? canonical(URL(fileURLWithPath: common.output))
                : path.appendingPathComponent(".git")
            if locations[directory.path] != nil {
                if !locations[directory.path]!.paths.contains(path) {
                    locations[directory.path]!.paths.append(path)
                }
            } else {
                locations[directory.path] = Location(
                    commonDirectory: directory, root: repository.root, paths: [path],
                    error: common.exitCode == 0 ? nil : "Unable to identify the shared Git directory. \(common.error)"
                )
            }
        }

        return await withTaskGroup(of: [RepositorySnapshot].self) { group in
            var iterator = locations.values.sorted { $0.commonDirectory.path < $1.commonDirectory.path }.makeIterator()
            for _ in 0..<min(6, locations.count) {
                if let location = iterator.next() {
                    group.addTask { inspect(location, fetchRemotes: fetchRemotes, command: command) }
                }
            }
            var results: [RepositorySnapshot] = []
            while let snapshots = await group.next() {
                results.append(contentsOf: snapshots)
                if let location = iterator.next() {
                    group.addTask { inspect(location, fetchRemotes: fetchRemotes, command: command) }
                }
            }
            return results.sorted { $0.path.path < $1.path.path }
        }
    }

    static func cleanupGoneBranches(in repositories: [RepositorySnapshot]) async -> BranchCleanupResult {
        await withTaskGroup(of: BranchCleanupResult.self) { group in
            for repository in RepositoryGroup.grouping(repositories).map(\.actionCheckout) where repository.branches.contains(where: \.upstreamGone) {
                group.addTask {
                    var deletedCount = 0
                    var failures: [BranchCleanupFailure] = []
                    for branch in repository.branches.filter(\.upstreamGone) {
                        do {
                            _ = try BranchActionService.deleteSafely(repository: repository, branch: branch)
                            deletedCount += 1
                        } catch {
                            let detail = error.localizedDescription
                                .split(separator: "\n", omittingEmptySubsequences: true)
                                .first
                                .map(String.init) ?? "Branch is checked out or has unmerged commits"
                            failures.append(BranchCleanupFailure(
                                repositoryName: repository.name,
                                branchName: branch.name,
                                reason: detail
                            ))
                        }
                    }
                    return BranchCleanupResult(deletedCount: deletedCount, failures: failures)
                }
            }

            var deletedCount = 0
            var failures: [BranchCleanupFailure] = []
            for await result in group {
                deletedCount += result.deletedCount
                failures.append(contentsOf: result.failures)
            }
            return BranchCleanupResult(deletedCount: deletedCount, failures: failures)
        }
    }

    private static func discoverRepositories(in roots: [URL]) -> [(path: URL, root: URL)] {
        var found: [String: (URL, URL)] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        for root in roots.map(\.standardizedFileURL) {
            if isGitRepository(root) { found[root.path] = (root, root) }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { continue }
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                if alwaysSkippedDirectoryNames.contains(name)
                    || (conditionallySkippedDirectoryNames.contains(name) && !containsNearbyRepository(url)) {
                    enumerator.skipDescendants()
                    continue
                }
                if isGitRepository(url) { found[url.standardizedFileURL.path] = (url.standardizedFileURL, root) }
            }
        }

        return found.values
            .map { (path: $0.0, root: $0.1) }
            .sorted { $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending }
    }

    private static func isGitRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// One cheap directory level decides whether a generically named folder
    /// might contain projects. Only a direct-child `.git` triggers a full
    /// descent; everything else is skipped without walking the tree.
    private static func containsNearbyRepository(_ directory: URL) -> Bool {
        if isGitRepository(directory) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { isGitRepository($0) }
    }

    private static func canonical(_ url: URL) -> URL {
        GitPath.canonical(url)
    }

    private struct CheckoutInspection {
        let worktree: GitWorktree
        let status: ParsedGitStatus
        let isUnavailable: Bool
        let error: String?
        let commitFields: [String]
        let checkoutDates: [String: Date]
    }

    private static func inspect(
        _ location: Location, fetchRemotes: Bool, command: GitCommandRunner
    ) -> [RepositorySnapshot] {
        let source = location.paths[0]
        let prefix = ["-C", source.path, "-c", "core.quotePath=false"]
        let listed = command.run(prefix + ["worktree", "list", "--porcelain", "-z"])
        var discoveryError = location.error
        var registered: [GitWorktree]
        if listed.exitCode == 0, let parsed = try? GitWorktreeParser.parse(listed.output) {
            registered = parsed
        } else {
            registered = []
            discoveryError = listed.error.isEmpty ? "Unable to list linked worktrees. Checkout coverage is incomplete." : listed.error
        }
        let repositoryPath = registered.first.map { canonical($0.path) } ?? source
        // Keep discovered checkouts visible if Git's worktree metadata was
        // incomplete or changed during the scan, and mark coverage unknown.
        for path in location.paths where !registered.contains(where: { canonical($0.path) == path }) {
            registered.append(GitWorktree(path: path))
            discoveryError = discoveryError ?? "A discovered checkout was absent from Git's worktree list. Refresh to check again."
        }
        var seen: Set<String> = []
        let worktrees = registered.filter { !$0.isBare && seen.insert(canonical($0.path).path).inserted }

        let remotes = command.run(prefix + ["remote"])
        var fetchError: String?
        if fetchRemotes, remotes.exitCode == 0, !remotes.output.isEmpty {
            let fetch = command.run(prefix + ["fetch", "--all", "--prune", "--quiet"], timeout: 600)
            if fetch.exitCode != 0 { fetchError = fetch.error.isEmpty ? "Fetch failed" : fetch.error }
        }
        let rawBranches = command.run(prefix + [
            "for-each-ref",
            "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)",
            "refs/heads"
        ])
        let parsedBranches = rawBranches.exitCode == 0 ? BranchTrackingParser.parse(rawBranches.output) : []
        if rawBranches.exitCode != 0 {
            discoveryError = discoveryError ?? "Unable to read shared branch status. \(rawBranches.error)"
        }
        let branchNames = Set(parsedBranches.map(\.name))
        let checkouts = worktrees.map {
            inspectCheckout($0, commonDirectory: location.commonDirectory, branchNames: branchNames, command: command)
        }
        var checkoutDates: [String: Date] = [:]
        for checkout in checkouts {
            checkoutDates.merge(checkout.checkoutDates, uniquingKeysWith: { max($0, $1) })
        }
        let branches = parsedBranches.map { branch in
            let isPublishedWithoutUpstream: Bool
            if branch.upstream == nil {
                let containingRemotes = command.run(prefix + ["branch", "--remotes", "--contains", branch.name])
                isPublishedWithoutUpstream = containingRemotes.exitCode == 0 && !containingRemotes.output.isEmpty
            } else {
                isPublishedWithoutUpstream = branch.isPublishedWithoutUpstream
            }
            let creationDate: Date?
            if branch.upstreamGone {
                let branchReflog = command.run(prefix + [
                    "reflog", "show", "--date=unix", "--format=%gD%x09%gs", branch.name
                ])
                creationDate = branchReflog.exitCode == 0
                    ? BranchActivityParser.approximateCreationDate(branchReflog.output) : nil
            } else {
                creationDate = nil
            }
            return BranchTrackingStatus(
                name: branch.name, upstream: branch.upstream, ahead: branch.ahead, behind: branch.behind,
                isPublishedWithoutUpstream: isPublishedWithoutUpstream, upstreamGone: branch.upstreamGone,
                lastCommitDate: branch.lastCommitDate, lastCheckoutDate: checkoutDates[branch.name],
                approximateCreatedDate: creationDate
            )
        }
        let remote = command.run(prefix + ["remote", "get-url", "origin"])
        return checkouts.map { checkout in
            let status = checkout.status
            let commit = checkout.commitFields
            return RepositorySnapshot(
                path: canonical(checkout.worktree.path), workspaceRoot: location.root,
                commonDirectory: location.commonDirectory, repositoryPath: repositoryPath,
                worktree: checkout.worktree, isUnavailable: checkout.isUnavailable,
                worktreeDiscoveryError: discoveryError,
                branch: status.branch, upstream: status.upstream, ahead: status.ahead, behind: status.behind,
                changes: status.changes, branches: branches,
                remoteURL: remote.exitCode == 0 && !remote.output.isEmpty ? remote.output : nil,
                lastCommitHash: commit.indices.contains(0) && !commit[0].isEmpty ? commit[0] : nil,
                lastCommitAge: commit.indices.contains(1) ? commit[1] : nil,
                lastCommitSubject: commit.indices.contains(2) ? commit[2] : nil,
                fetchError: fetchError, statusError: checkout.error
            )
        }
    }

    private static func inspectCheckout(
        _ worktree: GitWorktree, commonDirectory: URL, branchNames: Set<String>, command: GitCommandRunner
    ) -> CheckoutInspection {
        let path = canonical(worktree.path)
        let prefix = ["-C", path.path, "-c", "core.quotePath=false"]
        // Git walks up to a parent repository if .git disappears. Verify both
        // the checkout root and shared directory before reading its status.
        let top = command.run(prefix + ["rev-parse", "--show-toplevel"])
        let common = command.run(prefix + ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard top.exitCode == 0, common.exitCode == 0,
              canonical(URL(fileURLWithPath: top.output)) == path,
              canonical(URL(fileURLWithPath: common.output)) == commonDirectory else {
            var status = ParsedGitStatus()
            status.branch = worktree.branch ?? (worktree.isDetached ? "(detached)" : "Unknown")
            let reason = worktree.pruneReason.flatMap { $0.isEmpty ? nil : $0 }
                ?? "This registered checkout is missing, inaccessible, or no longer belongs to this repository."
            return CheckoutInspection(worktree: worktree, status: status, isUnavailable: true,
                                      error: reason, commitFields: [], checkoutDates: [:])
        }
        let rawStatus = command.run(prefix + ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"])
        let parsed = GitStatusParser.parse(rawStatus.output)
        let commit = command.run(prefix + ["log", "-1", "--format=%h%x09%ar%x09%s"])
        let reflog = command.run(prefix + ["reflog", "show", "--date=unix", "--format=%gD%x09%gs", "HEAD"])
        return CheckoutInspection(
            worktree: worktree, status: parsed, isUnavailable: false,
            error: rawStatus.exitCode == 0 ? nil : (rawStatus.error.isEmpty ? "Unable to read Git status" : rawStatus.error),
            commitFields: commit.output.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init),
            checkoutDates: reflog.exitCode == 0
                ? BranchActivityParser.lastCheckoutDates(reflog.output, branchNames: branchNames) : [:]
        )
    }
}

/// Injectable at the scanner boundary for real-repository integration tests
/// that also check fetch counts and command failures.
struct GitCommandRunner: Sendable {
    let execute: @Sendable ([String], TimeInterval) -> CommandResult

    func run(_ arguments: [String], timeout: TimeInterval = 120) -> CommandResult {
        execute(arguments, timeout)
    }

    static let live = GitCommandRunner { GitCommand.run($0, timeout: $1) }
}
