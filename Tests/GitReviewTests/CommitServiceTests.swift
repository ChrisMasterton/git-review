import Foundation
import GitReviewCore
import Testing
@testable import GitReview

private final class CommitFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-review-commit-\(UUID().uuidString)").resolvingSymlinksInPath()
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: [String]) throws -> String {
        let result = GitCommand.run(["-C", root.path] + args)
        guard result.exitCode == 0 else { throw CommitFlowError.command(result.error) }
        return result.output
    }
    func write(_ name: String, _ content: String) throws {
        try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func snapshot() async throws -> RepositorySnapshot {
        let snapshots = await RepositoryScanner.scan(roots: [root], fetchRemotes: false)
        return try #require(snapshots.first)
    }
}

@Test func commitPromptOmitsStagedNewFileContentsAndKeepsLocalFingerprint() async throws {
    let fixture = try CommitFixture()
    try fixture.write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4000))
    try fixture.git(["add", "--all"])
    // Includes an unstaged change to the same staged addition.
    try fixture.write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4001))
    let repository = try await fixture.snapshot()
    let before = try CommitService.context(for: repository)
    #expect(before.prompt.count <= 12_000)
    #expect(before.prompt.contains("NewFeature.swift"))
    #expect(!before.prompt.contains("newFileContentMustStayLocal"))
    try fixture.write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4002))
    let after = try CommitService.context(for: repository)
    #expect(before.fingerprint != after.fingerprint)
    #expect(throws: CommitFlowError.self) {
        try CommitService.commit(repository: repository, message: "Add feature", expectedFingerprint: before.fingerprint)
    }
}

@Test(arguments: [true, false])
func nonUTF8TrackedEditsCannotBypassCommitDraftVerification(_ staged: Bool) async throws {
    let fixture = try CommitFixture()
    let file = fixture.root.appendingPathComponent("legacy.txt")
    try Data([0x63, 0x61, 0x66, 0xe9, 0x0a]).write(to: file)
    try fixture.write("control.txt", "Keep this content\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try Data([0x75, 0x6e, 0xe9, 0x0a]).write(to: file)
    if staged { try fixture.git(["add", "legacy.txt"]) }
    let repository = try await fixture.snapshot()
    let reviewed = try CommitService.context(for: repository)
    try Data([0x64, 0x65, 0x75, 0x78, 0xe9, 0x0a]).write(to: file)
    if staged { try fixture.git(["add", "legacy.txt"]) }
    let indexBlob = try fixture.git(["rev-parse", ":legacy.txt"])
    let editedBlob = try fixture.git(["hash-object", "--", "legacy.txt"])
    let changed = try CommitService.context(for: repository)

    #expect(reviewed.fingerprint != changed.fingerprint)
    #expect(throws: CommitFlowError.self) {
        try CommitService.commit(repository: repository, message: "Save reviewed edit", expectedFingerprint: reviewed.fingerprint)
    }
    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try fixture.git(["rev-parse", ":legacy.txt"]) == indexBlob)
    #expect(try fixture.git(["hash-object", "--", "legacy.txt"]) == editedBlob)

    // A fresh review must still permit saving the exact non-UTF-8 bytes.
    let refreshed = try await fixture.snapshot()
    let fresh = try CommitService.context(for: refreshed)
    _ = try CommitService.commit(repository: refreshed, message: "Save legacy text", expectedFingerprint: fresh.fingerprint)
    #expect(try fixture.git(["rev-parse", "HEAD:legacy.txt"]) == editedBlob)
    #expect(try fixture.git(["show", "HEAD:control.txt"]) == "Keep this content")
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
}

@Test func whitespacePrefixedUntrackedEditsCannotBypassCommitDraftVerification() async throws {
    let fixture = try CommitFixture()
    try fixture.write("control.txt", "Keep this content\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    let path = " notes.txt"
    try fixture.write(path, "Reviewed content\n")
    let repository = try await fixture.snapshot()
    #expect(repository.changes.map(\.path) == [path])
    let reviewed = try CommitService.context(for: repository)
    try fixture.write(path, "Unreviewed content\n")
    let editedBlob = try fixture.git(["hash-object", "--", path])

    #expect(try CommitService.context(for: repository).fingerprint != reviewed.fingerprint)
    #expect(throws: CommitFlowError.self) {
        try CommitService.commit(repository: repository, message: "Save reviewed notes", expectedFingerprint: reviewed.fingerprint)
    }
    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent(path), encoding: .utf8) == "Unreviewed content\n")

    let fresh = try CommitService.context(for: repository)
    _ = try CommitService.commit(repository: repository, message: "Save notes", expectedFingerprint: fresh.fingerprint)
    #expect(try fixture.git(["rev-parse", "HEAD:\(path)"]) == editedBlob)
    #expect(try fixture.git(["show", "HEAD:control.txt"]) == "Keep this content")
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
}

@Test func untrackedSymlinkVerificationUsesTheSavedDestination() async throws {
    let fixture = try CommitFixture()
    try fixture.write("target-a.txt", "Same target content\n")
    try fixture.write("target-b.txt", "Same target content\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    let link = fixture.root.appendingPathComponent("selected-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target-a.txt")
    let repository = try await fixture.snapshot()
    let reviewed = try CommitService.context(for: repository)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target-b.txt")

    #expect(try CommitService.context(for: repository).fingerprint != reviewed.fingerprint)
    #expect(throws: CommitFlowError.self) {
        try CommitService.commit(repository: repository, message: "Save reviewed link", expectedFingerprint: reviewed.fingerprint)
    }
    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target-b.txt")

    let fresh = try CommitService.context(for: repository)
    _ = try CommitService.commit(repository: repository, message: "Save selected link", expectedFingerprint: fresh.fingerprint)
    #expect(try fixture.git(["show", "HEAD:selected-link"]) == "target-b.txt")
    #expect(try fixture.git(["ls-tree", "HEAD", "selected-link"]).hasPrefix("120000 blob "))
    #expect(try fixture.git(["show", "HEAD:target-a.txt"]) == "Same target content")
    #expect(try fixture.git(["show", "HEAD:target-b.txt"]) == "Same target content")
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
}

@Test func anEditDuringStagingCannotBeHiddenByTrimmedStatusOutput() async throws {
    let fixture = try CommitFixture()
    try fixture.write("a-control.txt", "Base control\n")
    try fixture.write("z-filtered.txt", "Base filtered\n")
    try fixture.write(".gitattributes", "z-filtered.txt filter=staging-gate\n")
    let script = fixture.root.appendingPathComponent(".git/slow-clean")
    let started = fixture.root.appendingPathComponent(".git/add-started")
    let release = fixture.root.appendingPathComponent(".git/add-release")
    let armed = fixture.root.appendingPathComponent(".git/staging-gate")
    try """
    #!/bin/sh
    if [ -f .git/staging-gate ]; then
        case "$(/bin/ps -o command= -p "$PPID")" in
            *" add --all --"*)
                touch .git/add-started
                attempts=0
                while [ ! -f .git/add-release ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.02
                    attempts=$((attempts + 1))
                done
                [ -f .git/add-release ] || exit 2
                ;;
        esac
    fi
    cat
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try fixture.git(["config", "filter.staging-gate.clean", script.path])
    try fixture.git(["config", "filter.staging-gate.required", "true"])
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.write("z-filtered.txt", "Reviewed filtered edit\n")
    let repository = try await fixture.snapshot()
    let reviewed = try CommitService.context(for: repository)
    try Data().write(to: armed)
    defer { try? Data().write(to: release) }
    // The real clean filter pauses only git add, after the earlier path was
    // inspected. Status and diff remain free to verify the submitted draft.
    let operation = Task.detached {
        try CommitService.commit(repository: repository, message: "Save reviewed edit", expectedFingerprint: reviewed.fingerprint)
    }
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    try fixture.write("a-control.txt", "New edit during staging\n")
    try Data().write(to: release)
    var rejected = false
    do { _ = try await operation.value }
    catch CommitFlowError.changedWhileStaging { rejected = true }
    #expect(rejected)
    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try fixture.git(["show", ":a-control.txt"]) == "Base control")
    #expect(try fixture.git(["show", ":z-filtered.txt"]) == "Reviewed filtered edit")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("a-control.txt"), encoding: .utf8) == "New edit during staging\n")

    try FileManager.default.removeItem(at: armed)
    let fresh = try CommitService.context(for: repository)
    _ = try CommitService.commit(repository: repository, message: "Save both reviewed edits", expectedFingerprint: fresh.fingerprint)
    #expect(try fixture.git(["show", "HEAD:a-control.txt"]) == "New edit during staging")
    #expect(try fixture.git(["show", "HEAD:z-filtered.txt"]) == "Reviewed filtered edit")
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
}

@Test(arguments: ["simple", "matching"])
func currentBranchPushTargetsOnlyItsConfiguredUpstream(_ pushDefault: String) async throws {
    let fixture = try CommitFixture()
    let remote = fixture.root.appendingPathExtension("git")
    defer { try? FileManager.default.removeItem(at: remote) }
    try fixture.git(["commit", "--allow-empty", "-m", "Base"])
    try fixture.git(["init", "--bare", remote.path])
    try fixture.git(["remote", "add", "origin", remote.path])
    try fixture.git(["push", "--set-upstream", "origin", "refs/heads/main:refs/heads/review-main"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["branch", "control"])
    try fixture.git(["push", "origin", "refs/heads/control:refs/heads/control"])
    try fixture.git(["checkout", "control"])
    try fixture.git(["commit", "--allow-empty", "-m", "Keep local control"])
    try fixture.git(["checkout", "main"])
    try fixture.git(["commit", "--allow-empty", "-m", "Publish current branch"])
    try fixture.git(["config", "push.default", pushDefault])
    let expected = try fixture.git(["rev-parse", "HEAD"])
    let repository = try await fixture.snapshot()
    #expect(repository.currentBranchNeedsPush)

    _ = try CommitService.push(repository: repository)

    let published = try fixture.git(["--git-dir", remote.path, "rev-parse", "refs/heads/review-main"])
    let control = try fixture.git(["--git-dir", remote.path, "rev-parse", "refs/heads/control"])
    #expect(published == expected)
    #expect(control == base)
    let refreshed = try await fixture.snapshot()
    #expect(refreshed.currentBranchTracking?.ahead == 0)
    #expect(refreshed.branches.first { $0.name == "control" }?.canPublish == true)
}

@Test(arguments: [true, false])
func inlinePushDisambiguatesBranchFromTagWithTheSameName(_ tracked: Bool) async throws {
    let fixture = try CommitFixture()
    let remote = fixture.root.appendingPathExtension("git")
    defer { try? FileManager.default.removeItem(at: remote) }
    try fixture.git(["commit", "--allow-empty", "-m", "Base"])
    try fixture.git(["init", "--bare", remote.path])
    try fixture.git(["remote", "add", "origin", remote.path])
    if tracked {
        try fixture.git(["push", "--set-upstream", "origin", "refs/heads/main:refs/heads/main"])
    } else {
        try fixture.git(["push", "origin", "refs/heads/main:refs/heads/published-base"])
    }
    try fixture.git(["tag", "main"])
    let tag = try fixture.git(["rev-parse", "refs/tags/main"])
    try fixture.git(["commit", "--allow-empty", "-m", "Advance branch"])
    let expected = try fixture.git(["rev-parse", "HEAD"])
    let repository = try await fixture.snapshot()
    let branch = try #require(repository.currentBranchTracking)
    #expect(branch.name == "main")
    #expect(branch.canPublish == !tracked)

    _ = try BranchActionService.push(repository: repository, branch: branch)

    let published = try fixture.git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"])
    #expect(published == expected)
    #expect(try fixture.git(["rev-parse", "refs/tags/main"]) == tag)
    let refreshed = try await fixture.snapshot()
    #expect(refreshed.currentBranchTracking?.upstream == "origin/main")
    #expect(!refreshed.currentBranchNeedsPush)
}

@Test func currentBranchPushRefusesAnExternalBranchSwitchAfterScanning() async throws {
    let fixture = try CommitFixture()
    let remote = fixture.root.appendingPathExtension("git")
    defer { try? FileManager.default.removeItem(at: remote) }
    try fixture.git(["commit", "--allow-empty", "-m", "Base"])
    try fixture.git(["init", "--bare", remote.path])
    try fixture.git(["remote", "add", "origin", remote.path])
    try fixture.git(["push", "--set-upstream", "origin", "refs/heads/main:refs/heads/main"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["commit", "--allow-empty", "-m", "Intended push"])
    let repository = try await fixture.snapshot()
    try fixture.git(["checkout", "--no-track", "-b", "private-work"])

    #expect(throws: CommitFlowError.self) {
        try CommitService.push(repository: repository)
    }

    #expect(try fixture.git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"]) == base)
    #expect(try fixture.git(["--git-dir", remote.path, "for-each-ref", "--format=%(refname)", "refs/heads"]) == "refs/heads/main")
    #expect(try fixture.git(["symbolic-ref", "HEAD"]) == "refs/heads/private-work")
}

@Test func pullRefusesAnExternalBranchSwitchAfterScanning() async throws {
    let fixture = try CommitFixture()
    let remote = fixture.root.appendingPathExtension("git")
    defer { try? FileManager.default.removeItem(at: remote) }
    try fixture.write("file.txt", "Base\n")
    try fixture.git(["add", "file.txt"])
    try fixture.git(["commit", "-m", "Base"])
    try fixture.git(["init", "--bare", remote.path])
    try fixture.git(["remote", "add", "origin", remote.path])
    try fixture.git(["push", "--set-upstream", "origin", "refs/heads/main:refs/heads/main"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["checkout", "-b", "other"])
    try fixture.git(["push", "--set-upstream", "origin", "refs/heads/other:refs/heads/other"])
    try fixture.write("file.txt", "Remote work\n")
    try fixture.git(["commit", "-am", "Advance other branch"])
    try fixture.git(["push", "origin", "refs/heads/other:refs/heads/other"])
    let remoteTip = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["reset", "--hard", base])
    try fixture.git(["checkout", "main"])
    let repository = try await fixture.snapshot()
    try fixture.git(["checkout", "other"])

    #expect(throws: CommitFlowError.self) { try CommitService.pull(repository: repository) }

    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "Base\n")
    #expect(try fixture.git(["--git-dir", remote.path, "rev-parse", "refs/heads/other"]) == remoteTip)
    // After refreshing the actual checkout, the ordinary fast-forward works.
    let refreshed = try await fixture.snapshot()
    _ = try CommitService.pull(repository: refreshed)
    #expect(try fixture.git(["rev-parse", "HEAD"]) == remoteTip)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "Remote work\n")
}

@Test(arguments: [0, 1]) @MainActor
func pendingCommitKeepsItsDraftUntilGitFinishes(_ hookExitCode: Int) async throws {
    let fixture = try CommitFixture()
    try fixture.write("file.txt", "Submitted content\n")
    let repository = try await fixture.snapshot()
    let context = try CommitService.context(for: repository)
    let hooks = fixture.root.appendingPathComponent(".git/hooks")
    let release = fixture.root.appendingPathComponent(".git/commit-release")
    let started = fixture.root.appendingPathComponent(".git/commit-started")
    let hook = hooks.appendingPathComponent("pre-commit")
    try """
    #!/bin/sh
    touch .git/commit-started
    attempts=0
    while [ ! -f .git/commit-release ] && [ "$attempts" -lt 500 ]; do
        sleep 0.02
        attempts=$((attempts + 1))
    done
    [ -f .git/commit-release ] || exit 2
    exit \(hookExitCode)
    """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try fixture.git(["config", "core.hooksPath", hooks.path])
    defer { try? Data().write(to: release) }
    let store = RepositoryStore()
    store.roots = []
    store.commitDraft = CommitDraft(repository: repository, fingerprint: context.fingerprint, model: "Manual", summary: "Fixture")
    store.commitMessage = "Save submitted message"
    store.commitDraftMessage()
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    #expect(store.isCommitting)

    // The sheet's Cancel button and Escape call this same action.
    store.cancelCommitDraft()
    #expect(store.commitDraft?.repository.id == repository.id)
    #expect(store.commitMessage == "Save submitted message")

    try Data().write(to: release)
    for _ in 0..<500 {
        if !store.isCommitting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isCommitting)
    if hookExitCode == 0 {
        #expect(store.commitFlowError == nil)
        #expect(store.commitDraft == nil)
        #expect(try fixture.git(["log", "-1", "--format=%B"]) == "Save submitted message")
        #expect(try fixture.git(["show", "HEAD:file.txt"]) == "Submitted content")
        #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
    } else {
        #expect(store.commitFlowError != nil)
        #expect(store.commitDraft?.repository.id == repository.id)
        #expect(store.commitMessage == "Save submitted message")
        // After resolving the hook failure, retry the retained draft directly.
        try fixture.git(["config", "core.hooksPath", "/dev/null"])
        store.commitFlowError = nil
        store.commitDraftMessage()
        for _ in 0..<500 {
            if !store.isCommitting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isCommitting)
        #expect(store.commitFlowError == nil)
        #expect(store.commitDraft == nil)
        #expect(try fixture.git(["log", "-1", "--format=%B"]) == "Save submitted message")
        #expect(try fixture.git(["show", "HEAD:file.txt"]) == "Submitted content")
        #expect(try fixture.git(["rev-list", "--count", "HEAD"]) == "1")
        #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
    }
}

@Test @MainActor func rejectedCommitDoesNotApproveEditsMadeByTheHook() async throws {
    let fixture = try CommitFixture()
    try fixture.write("control.txt", "Keep this content\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.write("file.txt", "Submitted content\n")
    let repository = try await fixture.snapshot()
    let context = try CommitService.context(for: repository)
    let hooks = fixture.root.appendingPathComponent(".git/hooks")
    let hook = hooks.appendingPathComponent("pre-commit")
    try """
    #!/bin/sh
    echo 'Unreviewed hook edits' > file.txt
    git add file.txt
    exit 1
    """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try fixture.git(["config", "core.hooksPath", hooks.path])
    let store = RepositoryStore()
    store.roots = []
    store.commitDraft = CommitDraft(repository: repository, fingerprint: context.fingerprint, model: "Manual", summary: "Fixture")
    store.commitMessage = "Save submitted message"
    store.commitDraftMessage()
    for _ in 0..<500 {
        if !store.isCommitting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isCommitting && store.commitFlowError != nil)

    try fixture.git(["config", "core.hooksPath", "/dev/null"])
    store.commitFlowError = nil
    store.commitDraftMessage()
    for _ in 0..<500 {
        if !store.isCommitting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isCommitting)
    #expect(store.commitFlowError == CommitFlowError.changedSinceGeneration.localizedDescription)
    #expect(store.commitMessage == "Save submitted message")
    #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
    #expect(try fixture.git(["show", ":file.txt"]) == "Unreviewed hook edits")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("control.txt"), encoding: .utf8) == "Keep this content\n")
    store.cancelCommitDraft()
    #expect(store.commitDraft == nil && store.commitMessage.isEmpty)
}

@Test(arguments: ["commit", "discard"])
func fileActionsRefuseAnExternalBranchSwitchAfterScanning(_ action: String) async throws {
    let fixture = try CommitFixture()
    try fixture.write("file.txt", "Base\n")
    try fixture.write("control.txt", "Keep this content\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["branch", "other"])
    try fixture.write("file.txt", "Uncommitted content\n")
    let repository = try await fixture.snapshot()
    let change = try #require(repository.changes.first { $0.path == "file.txt" })
    // Git carries the ordinary working-tree edit onto the other branch.
    try fixture.git(["checkout", "other"])

    #expect(throws: CommitFlowError.self) {
        if action == "commit" {
            let draft = try CommitService.context(for: repository)
            _ = try CommitService.commit(repository: repository, message: "Save edit", expectedFingerprint: draft.fingerprint)
        } else {
            _ = try DiscardChanges.discard(repository: repository, change: change)
        }
    }

    #expect(try fixture.git(["rev-parse", "refs/heads/main"]) == base)
    #expect(try fixture.git(["rev-parse", "refs/heads/other"]) == base)
    #expect(try fixture.git(["symbolic-ref", "HEAD"]) == "refs/heads/other")
    #expect(try fixture.git(["show", ":file.txt"]) == "Base")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "Uncommitted content\n")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("control.txt"), encoding: .utf8) == "Keep this content\n")
}

@Test(arguments: ["commit", "discard"])
func fileActionsStillWorkOnTheReviewedDetachedCheckout(_ action: String) async throws {
    let fixture = try CommitFixture()
    try fixture.write("file.txt", "Base\n")
    try fixture.git(["add", "--all"])
    try fixture.git(["commit", "-m", "Base"])
    let base = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["checkout", "--detach"])
    try fixture.write("file.txt", "Reviewed content\n")
    let repository = try await fixture.snapshot()
    try #require(repository.worktree.isDetached)

    if action == "commit" {
        let draft = try CommitService.context(for: repository)
        _ = try CommitService.commit(repository: repository, message: "Save detached edit", expectedFingerprint: draft.fingerprint)
        #expect(try fixture.git(["show", "HEAD:file.txt"]) == "Reviewed content")
        #expect(try fixture.git(["log", "-1", "--format=%B"]) == "Save detached edit")
    } else {
        let change = try #require(repository.changes.first)
        _ = try DiscardChanges.discard(repository: repository, change: change)
        #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "Base\n")
    }
    #expect(try fixture.git(["rev-parse", "refs/heads/main"]) == base)
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
    #expect(GitCommand.run(["-C", fixture.root.path, "symbolic-ref", "--quiet", "HEAD"]).exitCode == 1)
}
