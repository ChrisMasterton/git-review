import Foundation
import GitReviewCore

enum GitPath {
    /// Foundation resolves /private/var aliases differently when the final
    /// directory is absent. Resolve the existing ancestor before appending
    /// missing components so unavailable checkouts retain their identity.
    static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }
}

struct RepositorySnapshot: Identifiable, Equatable, Sendable {
    let path: URL
    let workspaceRoot: URL
    let commonDirectory: URL
    let repositoryPath: URL
    let worktree: GitWorktree
    let isUnavailable: Bool
    let worktreeDiscoveryError: String?
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let changes: [GitFileChange]
    let branches: [BranchTrackingStatus]
    let remoteURL: String?
    let lastCommitHash: String?
    let lastCommitAge: String?
    let lastCommitSubject: String?
    let fetchError: String?
    let statusError: String?

    var id: String { path.path }
    var name: String { path.lastPathComponent }
    var relativePath: String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let repoPath = path.standardizedFileURL.path
        if repoPath == rootPath { return name }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return repoPath.hasPrefix(prefix) ? String(repoPath.dropFirst(prefix.count)) : repoPath
    }
    var stagedCount: Int { changes.filter(\.isStaged).count }
    var modifiedCount: Int { changes.filter(\.isModified).count }
    var untrackedCount: Int { changes.filter(\.isUntracked).count }
    var conflictCount: Int { changes.filter(\.isConflicted).count }
    var workingTreeChangeCount: Int { changes.count }
    var unpublishedBranches: [BranchTrackingStatus] { branches.filter(\.needsPush) }
    var unpublishedCommitCount: Int { branches.reduce(0) { $0 + $1.ahead } }
    var localOnlyBranchCount: Int { branches.filter { $0.upstream == nil }.count }
    var currentBranchTracking: BranchTrackingStatus? { branches.first { $0.name == branch } }
    var currentBranchNeedsPush: Bool { currentBranchTracking?.needsPush == true || ahead > 0 }
    var canAccessCheckout: Bool { !isUnavailable && statusError == nil }
    var checkoutNeedsAttention: Bool {
        !canAccessCheckout || !changes.isEmpty || currentBranchNeedsPush || behind > 0
    }
    var checkoutStatusLabel: String {
        if isUnavailable { return "Unavailable" }
        if statusError != nil { return "Git error" }
        if conflictCount > 0 { return "Conflicts" }
        if !changes.isEmpty { return "Uncommitted" }
        if currentBranchNeedsPush { return "Needs push" }
        if behind > 0 { return "Behind remote" }
        return "Up to date"
    }
    var needsAttention: Bool {
        isUnavailable || worktreeDiscoveryError != nil || statusError != nil || !changes.isEmpty || !unpublishedBranches.isEmpty || behind > 0
    }
    var isClean: Bool { !needsAttention }
    var riskRank: Int {
        if isUnavailable || worktreeDiscoveryError != nil || statusError != nil { return 6 }
        if conflictCount > 0 { return 5 }
        if !changes.isEmpty && !unpublishedBranches.isEmpty { return 4 }
        if !changes.isEmpty { return 3 }
        if !unpublishedBranches.isEmpty { return 2 }
        if behind > 0 { return 1 }
        return 0
    }
    var statusLabel: String {
        if isUnavailable { return "Unavailable worktree" }
        if worktreeDiscoveryError != nil { return "Worktree discovery failed" }
        if statusError != nil { return "Git error" }
        if conflictCount > 0 { return "Conflicts" }
        if !changes.isEmpty && !unpublishedBranches.isEmpty { return "Local work + push" }
        if !changes.isEmpty { return "Uncommitted" }
        if !unpublishedBranches.isEmpty { return "Needs push" }
        if behind > 0 { return "Behind remote" }
        return "Up to date"
    }
}

/// Shared branch state is counted once, while each checkout keeps its own
/// working tree, selection identity, and action path.
struct RepositoryGroup: Identifiable, Sendable {
    let id: String
    let worktrees: [RepositorySnapshot]

    static func grouping(_ snapshots: [RepositorySnapshot]) -> [RepositoryGroup] {
        Dictionary(grouping: snapshots, by: { $0.commonDirectory.path }).map { id, values in
            let unique = Dictionary(grouping: values, by: \.id).compactMap { $0.value.first }
            return RepositoryGroup(id: id, worktrees: unique.sorted { lhs, rhs in
                let leftMain = lhs.path == lhs.repositoryPath
                let rightMain = rhs.path == rhs.repositoryPath
                if leftMain != rightMain { return leftMain }
                return lhs.path.path.localizedStandardCompare(rhs.path.path) == .orderedAscending
            })
        }.sorted { $0.id < $1.id }
    }

    var primary: RepositorySnapshot { worktrees[0] }
    var name: String { primary.repositoryPath.lastPathComponent }
    var path: URL { primary.repositoryPath }
    var actionCheckout: RepositorySnapshot { worktrees.first(where: \.canAccessCheckout) ?? primary }
    var preferredCheckout: RepositorySnapshot {
        worktrees.first(where: \.checkoutNeedsAttention) ?? primary
    }
    var needsAttention: Bool { worktrees.contains(where: \.needsAttention) }
    var isClean: Bool { !needsAttention }
    var workingTreeChangeCount: Int { worktrees.reduce(0) { $0 + $1.workingTreeChangeCount } }
    var unavailableCount: Int { worktrees.filter(\.isUnavailable).count }
    var unpublishedBranches: [BranchTrackingStatus] { primary.unpublishedBranches }
    var unpublishedCommitCount: Int { primary.unpublishedCommitCount }
    var riskRank: Int { worktrees.map(\.riskRank).max() ?? 0 }
    var statusLabel: String {
        if unavailableCount > 0 { return "Unavailable worktree" }
        return worktrees.max(by: { $0.riskRank < $1.riskRank })?.statusLabel ?? primary.statusLabel
    }

    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) || worktrees.contains { checkout in
            [checkout.path.path, checkout.branch, checkout.upstream ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
