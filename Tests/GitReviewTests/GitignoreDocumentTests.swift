import Foundation
import XCTest
@testable import GitReview

final class GitignoreDocumentTests: XCTestCase {
    func testLiteralDirectoryRuleWithRealGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try git(["init"]), 0)
        var document = try GitignoreDocument(root: root)
        try document.appendDirectory("cache[1]/")
        try document.save(document.text)
        XCTAssertEqual(try git(["check-ignore", "cache[1]/file"]), 0)
        XCTAssertEqual(try git(["check-ignore", "cache1/file"]), 1)
        XCTAssertEqual(try git(["check-ignore", "nested/cache[1]/file"]), 1)
    }

    func testPreservesContentsAndRejectsExternalChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".gitignore")
        try Data("# existing\r\nold/".utf8).write(to: file)
        var document = try GitignoreDocument(root: root)
        try document.appendDirectory("new/")
        XCTAssertEqual(document.text, "# existing\r\nold/\r\n/new/\r\n")
        try Data("external\n".utf8).write(to: file)
        XCTAssertThrowsError(try document.save(document.text))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external\n")
    }

    func testAddingDirectoryRuleOverridesAnEarlierRuleThatWasNegated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> Int32 {
            GitCommand.run(["-C", root.path, "-c", "core.excludesFile=/dev/null"] + args).exitCode
        }
        XCTAssertEqual(git(["init"]), 0)
        let file = root.appendingPathComponent(".gitignore")
        let original = "# Keep this comment\n/cache/\n!/cache/\n"
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(git(["check-ignore", "--quiet", "cache/file.txt"]), 1)
        var document = try GitignoreDocument(root: root)
        try document.appendDirectory("cache/")
        try document.save(document.text)

        XCTAssertEqual(git(["check-ignore", "--quiet", "cache/file.txt"]), 0)
        XCTAssertEqual(git(["check-ignore", "--quiet", "cache-control/file.txt"]), 1)
        XCTAssertEqual(git(["check-ignore", "--quiet", "nested/cache/file.txt"]), 1)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix(original))
        var reloaded = try GitignoreDocument(root: root)
        XCTAssertEqual(reloaded.text, saved)
        try reloaded.appendDirectory("cache/")
        XCTAssertEqual(reloaded.text, saved)
    }
}
