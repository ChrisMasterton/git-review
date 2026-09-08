import Foundation
import Testing
@testable import GitReview

private final class GitFixture {
    let directory: URL
    let watched: URL
    let main: URL
    let remote: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-review-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        watched = directory.appendingPathComponent("watched")
        main = watched.appendingPathComponent("example")
        remote = directory.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try git(["init", "--bare", remote.path])
        try git(["init", "--initial-branch=main", main.path])
        try git(["-C", main.path, "config", "user.name", "Fixture"])
        try git(["-C", main.path, "config", "user.email", "fixture@example.invalid"])
        try git(["-C", main.path, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        try git(["-C", main.path, "remote", "add", "origin", remote.path])
        try git(["-C", main.path, "push", "--set-upstream", "origin", "main"])
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = GitCommand.run(arguments)
        guard result.exitCode == 0 else { throw FixtureError.git(result.error) }
        return result.output
    }

    func addWorktree(_ relativePath: String, branch: String? = nil) throws -> URL {
        let path = directory.appendingPathComponent(relativePath)
        var args = ["-C", main.path, "worktree", "add"]
        if let branch { args += ["-b", branch] } else { args += ["--detach"] }
        try git(args + [path.path, "HEAD"])
        return path
    }

    func dirty(_ checkout: URL) throws {
        try "unfinished work\n".write(to: checkout.appendingPathComponent("unfinished.txt"), atomically: true, encoding: .utf8)
    }

    enum FixtureError: Error { case git(String) }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let failWorktreeList: Bool

    init(failWorktreeList: Bool = false) { self.failWorktreeList = failWorktreeList }

    var runner: GitCommandRunner {
        GitCommandRunner { [self] arguments, timeout in
            lock.lock()
            calls.append(arguments)
            lock.unlock()
            if failWorktreeList && arguments.contains("worktree") && arguments.contains("list") {
                return CommandResult(output: "", error: "Simulated worktree listing failure", exitCode: 1)
            }
            return GitCommand.run(arguments, timeout: timeout)
        }
    }

    func count(_ command: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.filter { $0.contains(command) }.count
    }
}

@Test func discoversHiddenAndExternalDirtyWorktreesAsOneRepository() async throws {
    let fixture = try GitFixture()
    let hidden = try fixture.addWorktree("watched/.hidden/外部 checkout")
    let external = try fixture.addWorktree("external/example", branch: "feature/external")
    try fixture.dirty(hidden)
    try fixture.dirty(external)
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let groups = RepositoryGroup.grouping(snapshots)
    let group = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(group.worktrees.count == 3)
    #expect(group.name == "example")
    #expect(group.workingTreeChangeCount == 2)
    #expect(group.needsAttention)
    #expect(group.matches("feature/external"))
    #expect(group.matches(hidden.path))
    let detached = try #require(snapshots.first { $0.path.path == hidden.path })
    #expect(detached.worktree.isDetached)
    #expect(detached.branch == "(detached)")
    #expect(detached.changes.map(\.path) == ["unfinished.txt"])
    try CommitService.requireCheckout(detached)
    #expect(snapshots.first { $0.path.path == fixture.main.path }?.changes.isEmpty == true)
    #expect(snapshots.allSatisfy { $0.worktreeDiscoveryError == nil && $0.canAccessCheckout })
}

@Test @MainActor func groupSelectionAndMetricsKeepCheckoutActionsScoped() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("external/linked", branch: "feature/selected")
    try fixture.dirty(linked)
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let store = RepositoryStore()
    store.repositories = snapshots
    let group = try #require(store.visibleRepositories.first)
    #expect(store.attentionCount == 1)
    #expect(store.uncommittedCount == 1)
    #expect(store.cleanCount == 0)
    store.selectGroup(group.id)
    #expect(store.selectedRepository?.path.path == linked.path)
    store.select(group.primary.id)
    #expect(store.selectedRepository?.path.path == fixture.main.path)
    #expect(store.selectedGroup?.id == group.id)
    store.query = "feature/selected"
    #expect(store.visibleRepositories.count == 1)
    // Opening the group again preserves the explicitly selected checkout.
    store.selectGroup(group.id)
    #expect(store.selectedRepository?.path.path == fixture.main.path)
}

@Test func lockedWorktreeStillReportsItsWorkingTreeChanges() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("external/locked")
    try fixture.git(["-C", fixture.main.path, "worktree", "lock", "--reason", "Portable drive", linked.path])
    try fixture.dirty(linked)
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == linked.path })
    #expect(checkout.worktree.lockReason == "Portable drive")
    #expect(checkout.canAccessCheckout)
    #expect(checkout.workingTreeChangeCount == 1)
}

@Test func deduplicatesOverlappingRootsAndFetchesSharedRefsOnlyOnce() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("watched/linked", branch: "feature/ahead")
    try fixture.git(["-C", linked.path, "push", "--set-upstream", "origin", "feature/ahead"])
    try fixture.git(["-C", linked.path, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Unpublished"])
    let recorder = CommandRecorder()
    let snapshots = await RepositoryScanner.scan(
        roots: [fixture.watched, fixture.main, linked, fixture.watched], fetchRemotes: true, command: recorder.runner
    )
    let groups = RepositoryGroup.grouping(snapshots)
    #expect(snapshots.count == 2)
    #expect(groups.count == 1)
    #expect(groups.first?.unpublishedCommitCount == 1)
    #expect(groups.first?.unpublishedBranches.count == 1)
    #expect(recorder.count("fetch") == 1)
    #expect(recorder.count("for-each-ref") == 1)
    #expect(recorder.count("list") == 1)
}

@Test func missingWorktreeRemainsVisibleAndPreventsCleanStatus() async throws {
    let fixture = try GitFixture()
    let missing = try fixture.addWorktree("external/missing")
    try FileManager.default.removeItem(at: missing)
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let group = try #require(RepositoryGroup.grouping(snapshots).first)
    let checkout = try #require(snapshots.first { $0.path.lastPathComponent == "missing" })
    #expect(checkout.path.path == missing.path)
    #expect(group.worktrees.count == 2)
    #expect(group.unavailableCount == 1)
    #expect(group.needsAttention)
    #expect(!group.isClean)
    #expect(checkout.isUnavailable)
    #expect(!checkout.canAccessCheckout)
    #expect(checkout.checkoutStatusLabel == "Unavailable")
    #expect(checkout.statusError != nil)
}

@Test func failedWorktreeDiscoveryKeepsKnownCheckoutButReportsIncompleteCoverage() async throws {
    let fixture = try GitFixture()
    let snapshots = await RepositoryScanner.scan(
        roots: [fixture.watched], fetchRemotes: false, command: CommandRecorder(failWorktreeList: true).runner
    )
    let group = try #require(RepositoryGroup.grouping(snapshots).first)
    #expect(group.worktrees.count == 1)
    #expect(group.primary.worktreeDiscoveryError == "Simulated worktree listing failure")
    #expect(group.primary.canAccessCheckout)
    #expect(!group.isClean)
}

@Test func discoversMainAndSiblingCheckoutsWhenOnlyLinkedCheckoutIsWatched() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("external/linked")
    let sibling = try fixture.addWorktree("external/sibling")
    try fixture.dirty(sibling)
    let snapshots = await RepositoryScanner.scan(roots: [linked], fetchRemotes: false)
    let group = try #require(RepositoryGroup.grouping(snapshots).first)
    #expect(group.worktrees.count == 3)
    #expect(group.primary.path.path == fixture.main.path)
    #expect(group.name == "example")
    #expect(group.preferredCheckout.path.path == sibling.path)
}

@Test func checkoutWhoseGitFileDisappearsCannotFallBackToParentRepository() async throws {
    let fixture = try GitFixture()
    let nested = try fixture.addWorktree("watched/example/nested")
    let before = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let snapshot = try #require(before.first { $0.path.path == nested.path })
    try FileManager.default.removeItem(at: nested.appendingPathComponent(".git"))
    try fixture.dirty(nested)
    let after = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    #expect(after.first { $0.path.path == nested.path }?.isUnavailable == true)
    #expect(throws: CommitFlowError.self) { try CommitService.requireCheckout(snapshot) }
}

@Test func separateClonesWithTheSameRemoteRemainSeparateRepositories() async throws {
    let fixture = try GitFixture()
    let clone = fixture.watched.appendingPathComponent("separate-clone")
    try fixture.git(["clone", "--branch", "main", fixture.remote.path, clone.path])
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let groups = RepositoryGroup.grouping(snapshots)
    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0.worktrees.count == 1 })
}

@Test func refreshClearsAttentionWhenLinkedCheckoutBecomesClean() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("external/linked")
    try fixture.dirty(linked)
    let dirty = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    #expect(RepositoryGroup.grouping(dirty).first?.needsAttention == true)
    try FileManager.default.removeItem(at: linked.appendingPathComponent("unfinished.txt"))
    let clean = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    #expect(RepositoryGroup.grouping(clean).first?.isClean == true)
    #expect(Set(dirty.map(\.id)) == Set(clean.map(\.id)))
}

@Test func bulkCleanupRunsOncePerRepositoryAndPreservesCheckedOutBranches() async throws {
    let fixture = try GitFixture()
    let linked = try fixture.addWorktree("external/linked", branch: "feature/checked-out")
    try fixture.git(["-C", fixture.main.path, "branch", "feature/gone"])
    for branch in ["feature/gone", "feature/checked-out"] {
        try fixture.git(["-C", fixture.main.path, "push", "--set-upstream", "origin", branch])
        try fixture.git(["--git-dir", fixture.remote.path, "update-ref", "-d", "refs/heads/\(branch)"])
    }
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched, linked], fetchRemotes: true)
    let result = await RepositoryScanner.cleanupGoneBranches(in: snapshots)
    #expect(result.deletedCount == 1)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.branchName == "feature/checked-out")
    let remaining = try fixture.git(["-C", linked.path, "branch", "--show-current"])
    #expect(remaining == "feature/checked-out")
}

@Test func removesOnlyTheSelectedCleanWorktreeAndKeepsItsBranch() async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/target", branch: "feature/keep")
    let sibling = try fixture.addWorktree("external/sibling")
    try fixture.git(["-C", target.path, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Keep this commit"])
    let tip = try fixture.git(["-C", target.path, "rev-parse", "HEAD"])
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == target.path })
    _ = try WorktreeRemoval.remove(checkout)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    #expect(FileManager.default.fileExists(atPath: fixture.main.path))
    #expect(try fixture.git(["-C", fixture.main.path, "rev-parse", "feature/keep"]) == tip)
    let after = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    #expect(after.count == 2)
    #expect(!after.contains { $0.path.path == target.path })
}

@Test func removingMissingWorktreeDoesNotPruneOtherMissingRegistrations() async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/target")
    let other = try fixture.addWorktree("external/other")
    try FileManager.default.removeItem(at: target)
    try FileManager.default.removeItem(at: other)
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == target.path })
    _ = try WorktreeRemoval.remove(checkout)
    let after = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    #expect(after.count == 2)
    #expect(after.contains { $0.path.path == other.path && $0.isUnavailable })
    #expect(!after.contains { $0.path.path == target.path })
}

@Test(arguments: ["dirty", "locked", "changed-head", "replaced-directory"])
func refusesWorktreeThatChangesAfterReview(_ change: String) async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/target", branch: "feature/test")
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == target.path })
    switch change {
    case "dirty": try fixture.dirty(target)
    case "locked": try fixture.git(["-C", fixture.main.path, "worktree", "lock", target.path])
    case "changed-head":
        try fixture.git(["-C", target.path, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Concurrent commit"])
    default:
        try FileManager.default.removeItem(at: target.appendingPathComponent(".git"))
        try fixture.dirty(target)
    }
    #expect(throws: CommitFlowError.self) { try WorktreeRemoval.remove(checkout) }
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func refusesMainWorktreeRemoval() async throws {
    let fixture = try GitFixture()
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let main = try #require(snapshots.first)
    #expect(WorktreeRemoval.disabledReason(for: main) != nil)
    #expect(throws: CommitFlowError.self) { try WorktreeRemoval.remove(main) }
    #expect(FileManager.default.fileExists(atPath: fixture.main.path))
}

@Test func preservesDetachedCommitsWithoutAnyRetainingRef() async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/detached")
    try fixture.git(["-C", target.path, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Unreferenced commit"])
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == target.path })
    #expect(throws: CommitFlowError.self) { try WorktreeRemoval.remove(checkout) }
    #expect(FileManager.default.fileExists(atPath: target.path))
    try fixture.git(["-C", target.path, "branch", "rescue"])
    _ = try WorktreeRemoval.remove(checkout)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try fixture.git(["-C", fixture.main.path, "rev-parse", "rescue"]) == checkout.worktree.head)
}

@Test @MainActor func removalRequiresAConfirmationRequestAndCanBeCancelled() async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/target")
    let snapshots = await RepositoryScanner.scan(roots: [fixture.watched], fetchRemotes: false)
    let checkout = try #require(snapshots.first { $0.path.path == target.path })
    let store = RepositoryStore()
    store.repositories = snapshots
    store.removeWorktree(checkout)
    #expect(!store.isRemovingWorktree)
    #expect(FileManager.default.fileExists(atPath: target.path))
    store.requestWorktreeRemoval(checkout)
    #expect(store.worktreeToRemove?.id == checkout.id)
    #expect(FileManager.default.fileExists(atPath: target.path))
    store.worktreeToRemove = nil
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test @MainActor func confirmedRemovalRefreshesTheGroupAndSelectsRemainingCheckout() async throws {
    let fixture = try GitFixture()
    let target = try fixture.addWorktree("external/target")
    let store = RepositoryStore()
    store.roots = [fixture.watched]
    store.repositories = await RepositoryScanner.scan(roots: store.roots, fetchRemotes: false)
    let checkout = try #require(store.repositories.first { $0.path.path == target.path })
    store.select(checkout.id)
    store.requestWorktreeRemoval(checkout)
    store.removeWorktree(checkout)
    for _ in 0..<200 {
        if !store.isRemovingWorktree && !store.isRefreshing { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!store.isRemovingWorktree && !store.isRefreshing)
    #expect(store.commitFlowError == nil)
    #expect(store.worktreeToRemove == nil)
    #expect(store.repositories.count == 1)
    #expect(store.selectedRepository?.path.path == fixture.main.path)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}
