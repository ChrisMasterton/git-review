import Foundation

@main struct WorktreeFlowChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let main = root.appendingPathComponent("main")
        let missing = root.appendingPathComponent("missing")
        let restored = root.appendingPathComponent("restored")
        let unrequested = root.appendingPathComponent("unrequested")
        let locked = root.appendingPathComponent("locked")
        let restricted = root.appendingPathComponent("restricted")
        let inaccessible = restricted.appendingPathComponent("checkout")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
            try? FileManager.default.removeItem(at: root)
        }
        func git(_ args: [String]) throws {
            let result = GitCommand.run(args)
            guard result.exitCode == 0 else { throw CommitFlowError.command(result.error) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main", main.path])
        try git(["-C", main.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "base"])
        for path in [missing, restored, locked, inaccessible, unrequested] {
            try git(["-C", main.path, "worktree", "add", "--detach", path.path])
        }
        try git(["-C", main.path, "worktree", "lock", locked.path])
        try FileManager.default.removeItem(at: missing)
        try FileManager.default.removeItem(at: unrequested)
        try FileManager.default.moveItem(at: restored, to: root.appendingPathComponent("backup"))
        try FileManager.default.removeItem(at: locked)
        let snapshots = await RepositoryScanner.scan(roots: [main], fetchRemotes: false)
        let group = RepositoryGroup.grouping(snapshots)[0]
        precondition(group.preferredCheckout.path.path == GitPath.canonical(main).path)
        precondition(CheckoutFolder.isMissing(missing))
        precondition(!CheckoutFolder.isMissing(main))
        // Restore after the UI snapshot: metadata-only cleanup must keep its files.
        try FileManager.default.moveItem(at: root.appendingPathComponent("backup"), to: restored)
        try Data(repeating: 65, count: 100_000).write(to: restored.appendingPathComponent("build.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        precondition(!CheckoutFolder.isMissing(inaccessible))
        let removed = try WorktreeRemoval.clearMissingRegistrations(snapshots.filter { [GitPath.canonical(missing).path, GitPath.canonical(restored).path].contains($0.id) })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        try git(["-C", inaccessible.path, "status", "--porcelain"])
        precondition(removed == [GitPath.canonical(missing).path])
        precondition(FileManager.default.fileExists(atPath: restored.appendingPathComponent("build.bin").path))
        let after = await RepositoryScanner.scan(roots: [main], fetchRemotes: false)
        precondition(after.contains { $0.path.path == GitPath.canonical(locked).path })
        precondition(after.contains { $0.path.path == GitPath.canonical(unrequested).path })
        precondition(after.first { $0.path.path == GitPath.canonical(unrequested).path }?.worktree.lockReason == nil)
        precondition(after.contains { $0.path.path == GitPath.canonical(restored).path })
        precondition(after.first { $0.path.path == GitPath.canonical(restored).path }?.worktree.lockReason == nil)
        precondition(after.first { $0.path.path == GitPath.canonical(inaccessible).path }?.worktree.lockReason == nil)
        // Hidden/generated files count; metadata and symlink targets do not.
        let bytes = try WorktreeDiskUsage.measure(restored)
        precondition(bytes > 0)
        let cache = restored.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 66, count: 200_000).write(to: cache.appendingPathComponent("output"))
        let expanded = try WorktreeDiskUsage.measure(restored)
        print("allocation before=\(bytes) after=\(expanded)"); fflush(stdout)
        precondition(expanded > bytes)
        try FileManager.default.createSymbolicLink(at: restored.appendingPathComponent("link"), withDestinationURL: cache)
        let linked = try WorktreeDiskUsage.measure(restored)
        precondition(linked == expanded)
        do { _ = try WorktreeDiskUsage.measure(missing); fatalError("Expected missing folder error") } catch {}
        // The menu stays available for dirty checkouts, but the service only
        // discards data with the explicit confirmation flag.
        let dirty = after.first { $0.path.path == GitPath.canonical(restored).path }!
        precondition(WorktreeRemoval.disabledReason(for: dirty) == nil)
        do { _ = try WorktreeRemoval.remove(dirty); fatalError("Expected dirty refusal without confirmation") } catch {}
        _ = try WorktreeRemoval.remove(dirty, discardChanges: true)
        precondition(CheckoutFolder.isMissing(restored))
        let lockedSnapshot = after.first { $0.path.path == GitPath.canonical(locked).path }!
        do { _ = try WorktreeRemoval.remove(lockedSnapshot, discardChanges: true); fatalError("Expected locked refusal") } catch {}
        // Discard uses literal paths and changes only the selected item.
        let specialName = "data[1]\n.txt"
        let special = main.appendingPathComponent(specialName)
        let unrelated = main.appendingPathComponent("other.txt")
        try Data("base".utf8).write(to: special)
        try Data("other base".utf8).write(to: unrelated)
        try git(["-C", main.path, "add", "--all"])
        try git(["-C", main.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "files"])
        try Data("staged edit".utf8).write(to: special)
        try git(["--literal-pathspecs", "-C", main.path, "add", "--", specialName])
        try Data("unstaged edit".utf8).write(to: special)
        try Data("keep this".utf8).write(to: unrelated)
        func snapshot() async -> RepositorySnapshot {
            await RepositoryScanner.scan(roots: [main], fetchRemotes: false).first { $0.path.path == GitPath.canonical(main).path }!
        }
        var selected = await snapshot()
        let specialChange = selected.changes.first { $0.path == specialName }!
        _ = try DiscardChanges.discard(repository: selected, change: specialChange)
        let restoredText = try String(contentsOf: special, encoding: .utf8)
        precondition(restoredText == "base")
        let unrelatedText = try String(contentsOf: unrelated, encoding: .utf8)
        precondition(unrelatedText == "keep this")
        try git(["--literal-pathspecs", "-C", main.path, "mv", "--", specialName, "renamed.txt"])
        selected = await snapshot()
        let renamed = selected.changes.first { $0.path == "renamed.txt" }!
        precondition(renamed.originalPath == specialName)
        _ = try DiscardChanges.discard(repository: selected, change: renamed)
        precondition(FileManager.default.fileExists(atPath: special.path))
        precondition(!FileManager.default.fileExists(atPath: main.appendingPathComponent("renamed.txt").path))
        let added = main.appendingPathComponent("added.txt")
        try Data("new".utf8).write(to: added)
        try git(["-C", main.path, "add", "added.txt"])
        selected = await snapshot()
        _ = try DiscardChanges.discard(repository: selected, change: selected.changes.first { $0.path == "added.txt" }!)
        precondition(!FileManager.default.fileExists(atPath: added.path))
        let trashable = main.appendingPathComponent("temporary folder")
        try FileManager.default.createDirectory(at: trashable, withIntermediateDirectories: true)
        try Data("recoverable".utf8).write(to: trashable.appendingPathComponent("file"))
        selected = await snapshot()
        let moved = try DiscardChanges.discard(repository: selected, change: selected.changes.first { $0.path == "temporary folder/" }!)!
        precondition(!FileManager.default.fileExists(atPath: trashable.path))
        let recoveredText = try String(contentsOf: moved.appendingPathComponent("file"), encoding: .utf8)
        precondition(recoveredText == "recoverable")
        try FileManager.default.moveItem(at: moved, to: trashable)
        try git(["-C", main.path, "-c", "protocol.file.allow=always", "submodule", "add", main.path, "nested"])
        let subfile = main.appendingPathComponent("nested").appendingPathComponent(specialName)
        try Data("nested changes".utf8).write(to: subfile)
        selected = await snapshot()
        let nested = selected.changes.first { $0.path == "nested" }!
        precondition(nested.isSubmodule)
        do { _ = try DiscardChanges.discard(repository: selected, change: nested); fatalError("Expected explicit submodule guidance") } catch {}
        let nestedText = try String(contentsOf: subfile, encoding: .utf8)
        precondition(nestedText == "nested changes")
        print("PASS: worktree size, selection, protected cleanup, dirty removal; scoped discard of staged/unstaged edits, renames, additions and untracked directories through real Git and Trash.")
    }
}
