import Foundation
import GitReviewCore
import Testing

@Test func parsesNULTerminatedWorktreesWithoutLosingPathCharacters() throws {
    let output = "worktree /tmp/main\0HEAD abc\0branch refs/heads/main\0\0"
        + "worktree /tmp/外部 folder\ncheckout\0HEAD def\0detached\0locked removable\ndrive\0\0"
        + "worktree /tmp/missing\0HEAD ghi\0branch refs/heads/feature\0prunable gitdir missing\0\0"
        + "worktree /tmp/archive.git\0bare\0\0"
    let parsed = try GitWorktreeParser.parse(output)
    #expect(parsed.count == 4)
    #expect(parsed[0].branch == "main")
    #expect(parsed[1].path.path == "/tmp/外部 folder\ncheckout")
    #expect(parsed[1].isDetached)
    #expect(parsed[1].lockReason == "removable\ndrive")
    #expect(parsed[2].pruneReason == "gitdir missing")
    #expect(parsed[3].isBare)
}

@Test func preservesBooleanLocksAndUnknownWorktreeAttributes() throws {
    let parsed = try GitWorktreeParser.parse("worktree /tmp/main\0HEAD abc\0locked\0future-attribute value\0\0")
    #expect(parsed[0].lockReason == "")
}

@Test(arguments: ["", "worktree /tmp/main\nHEAD abc\n", "HEAD abc\0\0", "worktree /tmp/main\0\0"])
func rejectsIncompleteWorktreeOutput(_ output: String) {
    #expect(throws: GitWorktreeParser.ParseError.self) { try GitWorktreeParser.parse(output) }
}
