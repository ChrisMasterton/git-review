import Foundation

enum GitCommand {
    static let executable: String = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "git"
    }()

    /// Runs Git and waits with an overall timeout. Output goes to temporary
    /// files instead of pipes, so a child writing more than a pipe buffer of
    /// stderr can never block forever, and the caller never hangs on a stuck
    /// remote or hook.
    static func run(_ arguments: [String], timeout: TimeInterval = 120) -> CommandResult {
        let process = Process()
        process.executableURL = executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Interactive prompts must stay off for background scans.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Everything else is a default only, so custom SSH setups keep working.
        if environment["GIT_SSH_COMMAND"] == nil && environment["GIT_SSH"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        }
        if environment["GIT_HTTP_LOW_SPEED_LIMIT"] == nil {
            environment["GIT_HTTP_LOW_SPEED_LIMIT"] = "1"
        }
        if environment["GIT_HTTP_LOW_SPEED_TIME"] == nil {
            environment["GIT_HTTP_LOW_SPEED_TIME"] = "10"
        }
        process.environment = environment

        let fileManager = FileManager.default
        let scratchDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("git-review-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = scratchDirectory.appendingPathComponent("stdout")
        let stderrURL = scratchDirectory.appendingPathComponent("stderr")

        do {
            try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
            process.standardError = try FileHandle(forWritingTo: stderrURL)
        } catch {
            try? fileManager.removeItem(at: scratchDirectory)
            return CommandResult(output: "", error: error.localizedDescription, exitCode: -1)
        }
        defer { try? fileManager.removeItem(at: scratchDirectory) }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(output: "", error: error.localizedDescription, exitCode: -1)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        process.waitUntilExit()

        let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        var error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if timedOut {
            let note = "Git command exceeded its \(Int(timeout)) second limit and was stopped."
            error = error.isEmpty ? note : error + "\n" + note
        }
        return CommandResult(
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            error: error.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }
}

