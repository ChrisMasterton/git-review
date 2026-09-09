import Foundation
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
