import Foundation
import GitReviewCore

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "CommitFlows", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct CommitFlows {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-review-commit-smoke-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        @discardableResult func git(_ args: [String]) throws -> String {
            let result = GitCommand.run(["-C", root.path] + args)
            try check(result.exitCode == 0, result.error)
            return result.output
        }
        func write(_ name: String, _ content: String) throws {
            try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4000))
        try git(["add", "--all"])
        try write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4001))
        let snapshots = await RepositoryScanner.scan(roots: [root], fetchRemotes: false)
        let repository = snapshots[0]
        let before = try CommitService.context(for: repository)
        print("Large staged addition: \(before.prompt.count) prompt characters")
        try check(before.prompt.count <= 14_096, "Prompt exceeds 12,000 characters")
        try check(before.prompt.contains("NewFeature.swift"), "Missing file path")
        try check(!before.prompt.contains("newFileContentMustStayLocal"), "New-file contents sent")
        try write("NewFeature.swift", String(repeating: "newFileContentMustStayLocal\n", count: 4002))
        let after = try CommitService.context(for: repository)
        try check(before.fingerprint != after.fingerprint, "Omitted content lost fingerprint coverage")
        do {
            _ = try CommitService.commit(repository: repository, message: "Add feature", expectedFingerprint: before.fingerprint)
            throw NSError(domain: "Unexpected commit", code: 1)
        } catch CommitFlowError.changedSinceGeneration {}
        let initialIndex = try git(["diff", "--cached"])

        let store = RepositoryStore()
        store.requestCommit(repository)
        store.writeManualCommitMessage()
        for _ in 0..<500 {
            if !store.isGeneratingCommit { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(store.commitFlowError == nil, store.commitFlowError ?? "")
        guard let draft = store.commitDraft else { fatalError("No manual draft") }
        try check(draft.model == "Manual" && store.commitMessage.isEmpty, "Manual editor not empty")
        let draftIndex = try git(["diff", "--cached"])
        try check(draftIndex == initialIndex, "Draft staged files")
        do {
            _ = try CommitService.commit(repository: repository, message: " \n ", expectedFingerprint: draft.fingerprint)
            throw NSError(domain: "Unexpected blank commit", code: 1)
        } catch CommitFlowError.invalidResponse {}
        let message = "Add feature\n\nWritten by a human."
        _ = try CommitService.commit(repository: repository, message: message, expectedFingerprint: draft.fingerprint)
        let committedMessage = try git(["log", "-1", "--format=%B"])
        try check(committedMessage == message, "Manual message changed")
        let status = try git(["status", "--porcelain"])
        try check(status.isEmpty, "Manual commit left changes")
        store.cancelCommitDraft()
        try check(store.commitDraft == nil && store.commitMessage.isEmpty, "Cancel did not clear draft")

        try write("NewFeature.swift", "let newBehavior = true\napi_key = hiddenCredentialValue\n")
        try write("untracked.txt", "untrackedContentMustStayLocal")
        let edited = try CommitService.context(for: repository)
        try check(edited.prompt.contains("newBehavior"), "Modified excerpt missing")
        try check(!edited.prompt.contains("hiddenCredentialValue"), "Credential not redacted")
        try check(!edited.prompt.contains("untrackedContentMustStayLocal"), "Untracked content sent")
        try git(["rm", "-f", "NewFeature.swift"])
        let deleted = try CommitService.context(for: repository)
        try check(!deleted.prompt.contains("newFileContentMustStayLocal"), "Deleted content sent")

        let manyDiffs = (0..<100).map { index in
            "diff --git a/file\(index) b/file\(index)\n--- a/file\(index)\n+++ b/file\(index)\n@@ -1 +1 @@\n-old\n+" + String(repeating: "界", count: 5000)
        }.joined(separator: "\n")
        let compact = CommitDiffSummary.context(status: String(repeating: "M file\n", count: 2000), staged: manyDiffs, unstaged: manyDiffs)
        try check(compact.count < 14_096, "Many-file budget exceeded")
        try check(compact.contains("omitted locally"), "No truncation notice")

        let data = try JSONEncoder().encode(OpenRouterCommitRequest(model: "openrouter/auto", prompt: edited.prompt))
        let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(request["stream"] as? Bool == false, "Streaming unexpectedly enabled")
        try check(request["max_completion_tokens"] as? Int == 4_096, "Missing output headroom")
        let response = try JSONDecoder().decode(OpenRouterCommitResponse.self, from: Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Cut off"}}]}"#.utf8))
        do {
            _ = try response.completion(fallbackModel: "fixture")
            throw NSError(domain: "Accepted truncated message", code: 1)
        } catch OpenRouterCommitResponseError.outputTruncated {}
        print("PASS: compact diffs, local fingerprints, manual commit, redaction, budgets, and output cutoff handling")
    }
}
