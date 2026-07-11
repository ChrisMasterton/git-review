import AppKit
import CryptoKit
import GitReviewCore
import SwiftUI

struct RepositorySnapshot: Identifiable, Equatable, Sendable {
    let path: URL
    let workspaceRoot: URL
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
    var needsAttention: Bool {
        statusError != nil || !changes.isEmpty || !unpublishedBranches.isEmpty
    }
    var isClean: Bool { !needsAttention }
    var riskRank: Int {
        if statusError != nil { return 5 }
        if conflictCount > 0 { return 4 }
        if !changes.isEmpty && !unpublishedBranches.isEmpty { return 3 }
        if !changes.isEmpty { return 2 }
        if !unpublishedBranches.isEmpty { return 1 }
        return 0
    }
    var statusLabel: String {
        if statusError != nil { return "Git error" }
        if conflictCount > 0 { return "Conflicts" }
        if !changes.isEmpty && !unpublishedBranches.isEmpty { return "Local work + push" }
        if !changes.isEmpty { return "Uncommitted" }
        if !unpublishedBranches.isEmpty { return "Needs push" }
        return "Up to date"
    }
}

struct CommandResult: Sendable {
    let output: String
    let error: String
    let exitCode: Int32
}

struct BranchCleanupFailure: Sendable {
    let repositoryName: String
    let branchName: String
    let reason: String
}

struct BranchCleanupResult: Sendable {
    let deletedCount: Int
    let failures: [BranchCleanupFailure]

    var summary: String {
        if failures.isEmpty {
            return "Deleted \(deletedCount) merged branch\(deletedCount == 1 ? "" : "es")."
        }
        return "Deleted \(deletedCount) merged branch\(deletedCount == 1 ? "" : "es"); skipped \(failures.count) branch\(failures.count == 1 ? "" : "es") that Git could not safely delete."
    }

    var detail: String {
        guard !failures.isEmpty else {
            return "No branches were force-deleted."
        }
        let lines = failures.prefix(8).map { failure in
            "\(failure.repositoryName) / \(failure.branchName): \(failure.reason)"
        }
        let remainder = failures.count - lines.count
        return (lines + (remainder > 0 ? ["…and \(remainder) more."] : [])).joined(separator: "\n")
    }
}

enum GitCommand {
    static let executable: String = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "git"
    }()

    static func run(_ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        environment["GIT_HTTP_LOW_SPEED_LIMIT"] = "1"
        environment["GIT_HTTP_LOW_SPEED_TIME"] = "10"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return CommandResult(
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                error: error.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )
        } catch {
            return CommandResult(output: "", error: error.localizedDescription, exitCode: -1)
        }
    }
}

struct CommitContext: Sendable {
    let prompt: String
    let fingerprint: String
    let summary: String
}

struct CommitDraft: Sendable {
    let repository: RepositorySnapshot
    let fingerprint: String
    let model: String
    let summary: String
}

enum CommitFlowError: LocalizedError {
    case noAPIKey
    case noChanges
    case changedSinceGeneration
    case command(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenRouter API key not found. Set openrouter_api_key or OPENROUTER_API_KEY in the environment used to launch Git Review, then reopen the app."
        case .noChanges:
            return "No pending changes were found to commit."
        case .changedSinceGeneration:
            return "The repository changed after the commit message was generated. Nothing was staged or committed. Refresh and generate a new message."
        case let .command(detail), let .invalidResponse(detail):
            return detail
        }
    }
}

enum CommitService {
    private static let maxPromptCharacters = 60_000

    static var apiKey: String? {
        let environment = ProcessInfo.processInfo.environment
        return [environment["openrouter_api_key"], environment["OPENROUTER_API_KEY"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static var model: String {
        let environment = ProcessInfo.processInfo.environment
        return [environment["openrouter_model"], environment["OPENROUTER_MODEL"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "openrouter/auto"
    }

    static func context(for repository: RepositorySnapshot) throws -> CommitContext {
        let prefix = ["-C", repository.path.path]
        let status = GitCommand.run(prefix + ["status", "--short", "--branch", "--untracked-files=all"])
        guard status.exitCode == 0 else {
            throw CommitFlowError.command(status.error.isEmpty ? "Unable to read Git status." : status.error)
        }
        let statusLines = status.output.split(separator: "\n")
        guard statusLines.contains(where: { !$0.hasPrefix("## ") }) else { throw CommitFlowError.noChanges }

        let staged = GitCommand.run(prefix + ["diff", "--cached", "--no-ext-diff", "--unified=3", "--"])
        let unstaged = GitCommand.run(prefix + ["diff", "--no-ext-diff", "--unified=3", "--"])
        let untracked = GitCommand.run(prefix + ["ls-files", "--others", "--exclude-standard", "-z"])

        let rawContext = """
        GIT STATUS
        \(status.output)

        STAGED DIFF
        \(staged.output)

        UNSTAGED DIFF
        \(unstaged.output)
        """
        let untrackedFingerprint = fingerprintForUntrackedFiles(untracked.output, repository: repository)
        let fingerprintMaterial = rawContext + "\nUNTRACKED CONTENT HASHES\n" + untrackedFingerprint
        let fingerprint = SHA256.hash(data: Data(fingerprintMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var redacted = redactSecrets(in: rawContext)
        var truncationNote = ""
        if redacted.count > maxPromptCharacters {
            redacted = String(redacted.prefix(maxPromptCharacters))
            truncationNote = "\n\n[Diff truncated locally after \(maxPromptCharacters) characters.]"
        }

        let prompt = """
        Write a precise Git commit message for the changes below.

        Requirements:
        - Return only the commit message, with no Markdown fences or commentary.
        - Use an imperative subject line, ideally 50-72 characters.
        - Add a short body only when it clarifies important behavior or multiple related changes.
        - Do not invent changes that are not visible in the status or diff.
        - Untracked file contents are not included; infer them only from their paths.

        Repository: \(repository.name)
        Branch: \(repository.branch)

        \(redacted)\(truncationNote)
        """

        let fileCount = statusLines.filter { !$0.hasPrefix("## ") }.count
        return CommitContext(
            prompt: prompt,
            fingerprint: fingerprint,
            summary: "\(fileCount) changed file\(fileCount == 1 ? "" : "s"); diff payload \(min(rawContext.count, maxPromptCharacters).formatted()) characters"
        )
    }

    static func generateMessage(context: CommitContext, apiKey: String) async throws -> (message: String, model: String) {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw CommitFlowError.invalidResponse("OpenRouter endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Git Review", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(OpenRouterCommitRequest(model: model, prompt: context.prompt))

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoded = try? JSONDecoder().decode(OpenRouterCommitResponse.self, from: data)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let detail = decoded?.apiErrorMessage ?? "OpenRouter request failed."
            throw CommitFlowError.invalidResponse(detail)
        }
        guard let decoded else {
            throw CommitFlowError.invalidResponse("OpenRouter returned an invalid response.")
        }
        let completion: OpenRouterCommitCompletion
        do {
            completion = try decoded.completion(fallbackModel: model)
        } catch let error as OpenRouterCommitResponseError {
            throw CommitFlowError.invalidResponse(error.localizedDescription)
        }
        let message = cleanCommitMessage(completion.message)
        guard !message.isEmpty else {
            throw CommitFlowError.invalidResponse("OpenRouter returned an empty commit message.")
        }
        return (message, completion.model)
    }

    static func commit(repository: RepositorySnapshot, message: String, expectedFingerprint: String) throws -> String {
        let currentContext = try context(for: repository)
        guard currentContext.fingerprint == expectedFingerprint else {
            throw CommitFlowError.changedSinceGeneration
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw CommitFlowError.invalidResponse("Enter a commit message before committing.")
        }

        let prefix = ["-C", repository.path.path]
        let add = GitCommand.run(prefix + ["add", "--all", "--"])
        guard add.exitCode == 0 else {
            throw CommitFlowError.command(add.error.isEmpty ? "Unable to stage repository changes." : add.error)
        }
        let commit = GitCommand.run(prefix + ["commit", "--message", trimmedMessage])
        guard commit.exitCode == 0 else {
            throw CommitFlowError.command(commit.error.isEmpty ? "Git commit failed." : commit.error)
        }
        return commit.output.split(separator: "\n").first.map(String.init) ?? "Commit created"
    }

    static func pull(repository: RepositorySnapshot) throws -> String {
        let prefix = ["-C", repository.path.path]
        let status = GitCommand.run(prefix + ["status", "--porcelain", "--untracked-files=all"])
        guard status.exitCode == 0 else {
            throw CommitFlowError.command(status.error.isEmpty ? "Unable to check the working tree before pulling." : status.error)
        }
        guard status.output.isEmpty else {
            throw CommitFlowError.command("Commit or discard local changes before pulling. Nothing was changed.")
        }
        let pull = GitCommand.run(prefix + ["pull", "--ff-only"])
        guard pull.exitCode == 0 else {
            throw CommitFlowError.command(pull.error.isEmpty ? "Fast-forward pull failed." : pull.error)
        }
        return pull.output.isEmpty ? "Repository is already up to date" : pull.output.split(separator: "\n").last.map(String.init) ?? "Pull complete"
    }

    static func push(repository: RepositorySnapshot) throws -> String {
        let prefix = ["-C", repository.path.path]
        let branchResult = GitCommand.run(prefix + ["symbolic-ref", "--quiet", "--short", "HEAD"])
        guard branchResult.exitCode == 0, !branchResult.output.isEmpty else {
            throw CommitFlowError.command("Cannot push from a detached HEAD.")
        }

        let configuredRemote = GitCommand.run(prefix + ["config", "--get", "branch.\(branchResult.output).remote"])
        let arguments: [String]
        if configuredRemote.exitCode == 0, !configuredRemote.output.isEmpty {
            arguments = prefix + ["push"]
        } else {
            let origin = GitCommand.run(prefix + ["remote", "get-url", "origin"])
            guard origin.exitCode == 0, !origin.output.isEmpty else {
                throw CommitFlowError.command("No upstream or origin remote is configured for \(branchResult.output).")
            }
            arguments = prefix + ["push", "--set-upstream", "origin", branchResult.output]
        }

        let push = GitCommand.run(arguments)
        guard push.exitCode == 0 else {
            throw CommitFlowError.command(push.error.isEmpty ? "Git push failed." : push.error)
        }
        return "pushed \(branchResult.output)"
    }

    private static func cleanCommitMessage(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```gitcommit", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        if result.lowercased().hasPrefix("commit message:") {
            result = String(result.dropFirst("commit message:".count))
        }
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
    }

    private static func redactSecrets(in value: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?im)^([+ -]*[^\n]*(?:api[_-]?key|token|secret|password|private[_-]?key)[^\n]*[:=]\s*).*$"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key|token|secret|password)(\s*[:=]\s*)[^\s\"']+"#, "$1$2[REDACTED]"),
            (#"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"sk-or-v1-[A-Za-z0-9_-]+"#, "[REDACTED_OPENROUTER_KEY]"),
            (#"gh[pousr]_[A-Za-z0-9_]{20,}"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"AKIA[A-Z0-9]{16}"#, "[REDACTED_AWS_KEY]"),
            (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "[REDACTED_JWT]")
        ]
        return replacements.reduce(value) { result, replacement in
            result.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    private static func fingerprintForUntrackedFiles(_ output: String, repository: RepositorySnapshot) -> String {
        output.split(separator: "\0").map(String.init).sorted().map { path in
            let url = repository.path.appendingPathComponent(path)
            return "\(path)\t\(fileFingerprint(url))"
        }.joined(separator: "\n")
    }

    private static func fileFingerprint(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return "read-error"
        }
    }
}

enum BranchActionService {
    static func deleteSafely(repository: RepositorySnapshot, branch: BranchTrackingStatus) throws -> String {
        guard branch.upstreamGone else {
            throw CommitFlowError.command("The upstream for \(branch.name) is not marked as gone.")
        }
        let result = GitCommand.run([
            "-C", repository.path.path,
            "branch", "--delete", "--", branch.name
        ])
        guard result.exitCode == 0 else {
            throw CommitFlowError.command(
                result.error.isEmpty
                    ? "Git would not safely delete \(branch.name). It may be checked out or contain unmerged commits."
                    : result.error
            )
        }
        return "Deleted merged branch \(branch.name)"
    }

    static func push(repository: RepositorySnapshot, branch: BranchTrackingStatus) throws -> String {
        guard branch.ahead > 0 else {
            throw CommitFlowError.command("\(branch.name) has no commits waiting to be pushed.")
        }
        let prefix = ["-C", repository.path.path]
        let remoteResult = GitCommand.run(prefix + ["config", "--get", "branch.\(branch.name).remote"])
        let mergeResult = GitCommand.run(prefix + ["config", "--get", "branch.\(branch.name).merge"])
        guard remoteResult.exitCode == 0, !remoteResult.output.isEmpty,
              mergeResult.exitCode == 0, mergeResult.output.hasPrefix("refs/heads/") else {
            throw CommitFlowError.command("No usable upstream is configured for \(branch.name).")
        }

        let remoteBranch = String(mergeResult.output.dropFirst("refs/heads/".count))
        let result = GitCommand.run(prefix + [
            "push", remoteResult.output, "\(branch.name):\(remoteBranch)"
        ])
        guard result.exitCode == 0 else {
            throw CommitFlowError.command(result.error.isEmpty ? "Git push failed for \(branch.name)." : result.error)
        }
        return "Pushed \(branch.name) to \(remoteResult.output)/\(remoteBranch)"
    }
}

enum RepositoryScanner {
    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".cache", ".gradle", ".idea", ".next", ".nuxt",
        ".swiftpm", ".terraform", ".venv", "Build", "DerivedData", "Library",
        "Pods", "Temp", "bin", "coverage", "dist", "node_modules", "obj", "vendor"
    ]

    static func scan(roots: [URL], fetchRemotes: Bool) async -> [RepositorySnapshot] {
        let repositories = discoverRepositories(in: roots)
        guard !repositories.isEmpty else { return [] }

        return await withTaskGroup(of: RepositorySnapshot.self) { group in
            var iterator = repositories.makeIterator()
            for _ in 0..<min(6, repositories.count) {
                if let repository = iterator.next() {
                    group.addTask { inspect(repository.path, root: repository.root, fetchRemotes: fetchRemotes) }
                }
            }

            var results: [RepositorySnapshot] = []
            while let snapshot = await group.next() {
                results.append(snapshot)
                if let repository = iterator.next() {
                    group.addTask { inspect(repository.path, root: repository.root, fetchRemotes: fetchRemotes) }
                }
            }
            return results
        }
    }

    static func cleanupGoneBranches(in repositories: [RepositorySnapshot]) async -> BranchCleanupResult {
        await withTaskGroup(of: BranchCleanupResult.self) { group in
            for repository in repositories where repository.branches.contains(where: \.upstreamGone) {
                group.addTask {
                    var deletedCount = 0
                    var failures: [BranchCleanupFailure] = []
                    for branch in repository.branches.filter(\.upstreamGone) {
                        let result = GitCommand.run([
                            "-C", repository.path.path,
                            "branch", "--delete", "--", branch.name
                        ])
                        if result.exitCode == 0 {
                            deletedCount += 1
                        } else {
                            let detail = result.error
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
            guard isGitRepository(root) || FileManager.default.fileExists(atPath: root.path) else { continue }
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
                if values?.isSymbolicLink == true || skippedDirectoryNames.contains(url.lastPathComponent) {
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

    private static func inspect(_ path: URL, root: URL, fetchRemotes: Bool) -> RepositorySnapshot {
        let prefix = ["-C", path.path]
        let remotes = GitCommand.run(prefix + ["remote"])
        var fetchError: String?
        if fetchRemotes, remotes.exitCode == 0, !remotes.output.isEmpty {
            let fetch = GitCommand.run(prefix + ["fetch", "--all", "--prune", "--quiet"])
            if fetch.exitCode != 0 { fetchError = fetch.error.isEmpty ? "Fetch failed" : fetch.error }
        }

        let rawStatus = GitCommand.run(prefix + ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"])
        let parsed = GitStatusParser.parse(rawStatus.output)
        let rawBranches = GitCommand.run(prefix + [
            "for-each-ref",
            "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)",
            "refs/heads"
        ])
        let parsedBranches = rawBranches.exitCode == 0 ? BranchTrackingParser.parse(rawBranches.output) : []
        let checkoutReflog = GitCommand.run(prefix + [
            "reflog", "show", "--date=unix", "--format=%gD%x09%gs", "HEAD"
        ])
        let checkoutDates = checkoutReflog.exitCode == 0
            ? BranchActivityParser.lastCheckoutDates(
                checkoutReflog.output,
                branchNames: Set(parsedBranches.map(\.name))
            )
            : [:]
        let branches = parsedBranches.map { branch in
            let isPublishedWithoutUpstream: Bool
            if branch.upstream == nil {
                let containingRemotes = GitCommand.run(prefix + ["branch", "--remotes", "--contains", branch.name])
                isPublishedWithoutUpstream = containingRemotes.exitCode == 0 && !containingRemotes.output.isEmpty
            } else {
                isPublishedWithoutUpstream = branch.isPublishedWithoutUpstream
            }
            let creationDate: Date?
            if branch.upstreamGone {
                let branchReflog = GitCommand.run(prefix + [
                    "reflog", "show", "--date=unix", "--format=%gD%x09%gs", branch.name
                ])
                creationDate = branchReflog.exitCode == 0
                    ? BranchActivityParser.approximateCreationDate(branchReflog.output)
                    : nil
            } else {
                creationDate = nil
            }
            return BranchTrackingStatus(
                name: branch.name,
                upstream: branch.upstream,
                ahead: branch.ahead,
                behind: branch.behind,
                isPublishedWithoutUpstream: isPublishedWithoutUpstream,
                upstreamGone: branch.upstreamGone,
                lastCommitDate: branch.lastCommitDate,
                lastCheckoutDate: checkoutDates[branch.name],
                approximateCreatedDate: creationDate
            )
        }
        let remoteURLResult = GitCommand.run(prefix + ["remote", "get-url", "origin"])
        let commit = GitCommand.run(prefix + ["log", "-1", "--format=%h%x09%ar%x09%s"])
        let commitFields = commit.output.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)

        return RepositorySnapshot(
            path: path,
            workspaceRoot: root,
            branch: parsed.branch,
            upstream: parsed.upstream,
            ahead: parsed.ahead,
            behind: parsed.behind,
            changes: parsed.changes,
            branches: branches,
            remoteURL: remoteURLResult.exitCode == 0 && !remoteURLResult.output.isEmpty ? remoteURLResult.output : nil,
            lastCommitHash: commitFields.indices.contains(0) && !commitFields[0].isEmpty ? commitFields[0] : nil,
            lastCommitAge: commitFields.indices.contains(1) ? commitFields[1] : nil,
            lastCommitSubject: commitFields.indices.contains(2) ? commitFields[2] : nil,
            fetchError: fetchError,
            statusError: rawStatus.exitCode == 0 ? nil : (rawStatus.error.isEmpty ? "Unable to read Git status" : rawStatus.error)
        )
    }
}

enum RepositoryScope: String, CaseIterable, Identifiable {
    case attention
    case all
    var id: Self { self }
    var label: String { self == .attention ? "Attention" : "All" }
}

enum RepositorySort: String, CaseIterable, Identifiable {
    case priority
    case name
    case path
    var id: Self { self }
    var label: String {
        switch self { case .priority: "Priority"; case .name: "Name"; case .path: "Path" }
    }
    var systemImage: String {
        switch self { case .priority: "exclamationmark.circle"; case .name: "textformat"; case .path: "folder" }
    }
}

@MainActor
final class RepositoryStore: ObservableObject {
    @Published var roots: [URL] = []
    @Published var repositories: [RepositorySnapshot] = []
    @Published var selectedRepositoryID: RepositorySnapshot.ID?
    @Published var scope: RepositoryScope = .attention
    @Published var sort: RepositorySort = .priority
    @Published var query = ""
    @Published var isRefreshing = false
    @Published var isCleaningBranches = false
    @Published var cleanupResult: BranchCleanupResult?
    @Published var commitConsentRepository: RepositorySnapshot?
    @Published var commitDraft: CommitDraft?
    @Published var commitMessage = ""
    @Published var commitFlowError: String?
    @Published var isGeneratingCommit = false
    @Published var isCommitting = false
    @Published var isPushing = false
    @Published var isPulling = false
    @Published var branchActionIDs: Set<String> = []
    @Published var statusText = "Add a folder to begin"
    @Published var lastRefreshed: Date?
    @Published var fetchRemotes: Bool {
        didSet { UserDefaults.standard.set(fetchRemotes, forKey: Self.fetchKey) }
    }

    private static let rootsKey = "repositoryRoots"
    private static let fetchKey = "fetchRemotes"
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        roots = (UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        fetchRemotes = UserDefaults.standard.object(forKey: Self.fetchKey) as? Bool ?? true
    }

    deinit { autoRefreshTask?.cancel() }

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var attentionCount: Int { repositories.filter(\.needsAttention).count }
    var cleanCount: Int { repositories.filter(\.isClean).count }
    var uncommittedCount: Int { repositories.filter { !$0.changes.isEmpty }.count }
    var unpushedCount: Int { repositories.filter { !$0.unpublishedBranches.isEmpty }.count }
    var fetchWarningCount: Int { repositories.filter { $0.fetchError != nil }.count }
    var goneUpstreamBranchCount: Int {
        repositories.reduce(0) { count, repository in
            count + repository.branches.filter(\.upstreamGone).count
        }
    }

    var visibleRepositories: [RepositorySnapshot] {
        var values = scope == .attention ? repositories.filter(\.needsAttention) : repositories
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            values = values.filter {
                [$0.name, $0.path.path, $0.branch, $0.upstream ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
        }
        return values.sorted { lhs, rhs in
            switch sort {
            case .priority:
                if lhs.riskRank != rhs.riskRank { return lhs.riskRank > rhs.riskRank }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .path:
                return lhs.path.path.localizedStandardCompare(rhs.path.path) == .orderedAscending
            }
        }
    }

    func start() {
        guard autoRefreshTask == nil else { return }
        if !roots.isEmpty { refresh() }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refresh()
            }
        }
    }

    func addRoots() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders to watch"
        panel.message = "Git Review will inspect these folders and their subfolders for Git repositories."
        panel.prompt = "Watch Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }

        let combined = roots + panel.urls.map(\.standardizedFileURL)
        roots = Array(Dictionary(grouping: combined, by: \.path).compactMap(\.value.first))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        persistRoots()
        refresh()
    }

    func removeRoot(_ root: URL) {
        roots.removeAll { $0.standardizedFileURL == root.standardizedFileURL }
        persistRoots()
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        guard !roots.isEmpty else {
            repositories = []
            selectedRepositoryID = nil
            statusText = "Add a folder to begin"
            return
        }
        isRefreshing = true
        statusText = fetchRemotes ? "Fetching remotes and checking repositories..." : "Checking repositories..."
        let rootsToScan = roots
        let shouldFetch = fetchRemotes
        Task {
            let next = await RepositoryScanner.scan(roots: rootsToScan, fetchRemotes: shouldFetch)
            repositories = next
            if let selectedRepositoryID, !next.contains(where: { $0.id == selectedRepositoryID }) {
                self.selectedRepositoryID = nil
            }
            lastRefreshed = Date()
            isRefreshing = false
            if next.isEmpty {
                statusText = "No Git repositories found"
            } else if attentionCount == 0 {
                statusText = "All \(next.count) repositories are up to date"
            } else {
                statusText = "\(attentionCount) of \(next.count) repositories need attention"
            }
        }
    }

    func cleanupGoneBranches() {
        guard !isCleaningBranches, goneUpstreamBranchCount > 0 else { return }
        isCleaningBranches = true
        statusText = "Safely deleting merged branches with gone upstreams..."
        let repositoriesToClean = repositories
        Task {
            let result = await RepositoryScanner.cleanupGoneBranches(in: repositoriesToClean)
            cleanupResult = result
            isCleaningBranches = false
            statusText = result.summary
            refresh()
        }
    }

    func dismissCleanupResult() {
        cleanupResult = nil
    }

    func requestCommit(_ repository: RepositorySnapshot) {
        guard !repository.changes.isEmpty else {
            commitFlowError = CommitFlowError.noChanges.localizedDescription
            return
        }
        guard CommitService.apiKey != nil else {
            commitFlowError = CommitFlowError.noAPIKey.localizedDescription
            return
        }
        commitConsentRepository = repository
    }

    func cancelCommitConsent() {
        commitConsentRepository = nil
    }

    func generateCommitMessage() {
        guard let repository = commitConsentRepository else { return }
        guard let apiKey = CommitService.apiKey else {
            commitConsentRepository = nil
            commitFlowError = CommitFlowError.noAPIKey.localizedDescription
            return
        }
        commitConsentRepository = nil
        isGeneratingCommit = true
        statusText = "Generating a commit message for \(repository.name)..."

        Task {
            do {
                let context = try await Task.detached(priority: .userInitiated) {
                    try CommitService.context(for: repository)
                }.value
                let generated = try await CommitService.generateMessage(context: context, apiKey: apiKey)
                commitDraft = CommitDraft(
                    repository: repository,
                    fingerprint: context.fingerprint,
                    model: generated.model,
                    summary: context.summary
                )
                commitMessage = generated.message
                statusText = "Review the generated commit message"
            } catch {
                commitFlowError = error.localizedDescription
                statusText = "Commit message generation failed"
            }
            isGeneratingCommit = false
        }
    }

    func cancelCommitDraft() {
        commitDraft = nil
        commitMessage = ""
    }

    func commitGeneratedMessage() {
        guard let draft = commitDraft, !isCommitting else { return }
        let message = commitMessage
        isCommitting = true
        statusText = "Staging and committing \(draft.repository.name)..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CommitService.commit(
                        repository: draft.repository,
                        message: message,
                        expectedFingerprint: draft.fingerprint
                    )
                }.value
                commitDraft = nil
                commitMessage = ""
                statusText = result
                isCommitting = false
                refresh()
            } catch {
                commitFlowError = error.localizedDescription
                statusText = "Commit failed"
                isCommitting = false
            }
        }
    }

    func push(_ repository: RepositorySnapshot) {
        guard !isPushing else { return }
        guard repository.currentBranchNeedsPush else {
            commitFlowError = "The current branch has no commits waiting to be pushed."
            return
        }
        isPushing = true
        statusText = "Pushing \(repository.branch) from \(repository.name)..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CommitService.push(repository: repository)
                }.value
                statusText = result
            } catch {
                commitFlowError = error.localizedDescription
                statusText = "Push failed"
            }
            isPushing = false
            refresh()
        }
    }

    func pull(_ repository: RepositorySnapshot) {
        guard !isPulling else { return }
        guard repository.changes.isEmpty else {
            commitFlowError = "Commit or discard local changes before pulling. Nothing was changed."
            return
        }
        isPulling = true
        statusText = "Pulling \(repository.name) with fast-forward only..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CommitService.pull(repository: repository)
                }.value
                statusText = result
            } catch {
                commitFlowError = error.localizedDescription
                statusText = "Pull failed"
            }
            isPulling = false
            refresh()
        }
    }

    func dismissCommitError() {
        commitFlowError = nil
    }

    func isBranchActionInProgress(repository: RepositorySnapshot, branch: BranchTrackingStatus) -> Bool {
        branchActionIDs.contains(branchActionID(repository: repository, branch: branch))
    }

    func cleanupBranch(repository: RepositorySnapshot, branch: BranchTrackingStatus) {
        let actionID = branchActionID(repository: repository, branch: branch)
        guard !branchActionIDs.contains(actionID) else { return }
        branchActionIDs.insert(actionID)
        statusText = "Safely deleting \(branch.name)..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BranchActionService.deleteSafely(repository: repository, branch: branch)
                }.value
                statusText = result
                branchActionIDs.remove(actionID)
                refresh()
            } catch {
                branchActionIDs.remove(actionID)
                commitFlowError = error.localizedDescription
                statusText = "Branch cleanup failed"
            }
        }
    }

    func pushBranch(repository: RepositorySnapshot, branch: BranchTrackingStatus) {
        let actionID = branchActionID(repository: repository, branch: branch)
        guard !branchActionIDs.contains(actionID) else { return }
        branchActionIDs.insert(actionID)
        statusText = "Pushing \(branch.name)..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BranchActionService.push(repository: repository, branch: branch)
                }.value
                statusText = result
                branchActionIDs.remove(actionID)
                refresh()
            } catch {
                branchActionIDs.remove(actionID)
                commitFlowError = error.localizedDescription
                statusText = "Branch push failed"
            }
        }
    }

    func select(_ id: RepositorySnapshot.ID?) { selectedRepositoryID = id }

    func reveal(_ repository: RepositorySnapshot) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.path])
    }

    func openTerminal(_ repository: RepositorySnapshot) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [repository.path],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: configuration
        )
    }

    func copyPath(_ repository: RepositorySnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repository.path.path, forType: .string)
        statusText = "Copied \(repository.name) path"
    }

    private func persistRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsKey)
    }

    private func branchActionID(repository: RepositorySnapshot, branch: BranchTrackingStatus) -> String {
        repository.id + "\u{0}" + branch.name
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var isCleanupConfirmationPresented = false

    private var cleanupResultPresented: Binding<Bool> {
        Binding(
            get: { store.cleanupResult != nil },
            set: { if !$0 { store.dismissCleanupResult() } }
        )
    }

    private var commitConsentPresented: Binding<Bool> {
        Binding(
            get: { store.commitConsentRepository != nil },
            set: { if !$0 { store.cancelCommitConsent() } }
        )
    }

    private var commitDraftPresented: Binding<Bool> {
        Binding(
            get: { store.commitDraft != nil },
            set: { if !$0 { store.cancelCommitDraft() } }
        )
    }

    private var commitErrorPresented: Binding<Bool> {
        Binding(
            get: { store.commitFlowError != nil },
            set: { if !$0 { store.dismissCommitError() } }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                RepositoryListHeader()
                RepositoryList()
                Divider()
                StatusBar()
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 440, max: 560)
        } detail: {
            RepositoryDetail()
        }
        .frame(minWidth: 1040, minHeight: 660)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Scope", selection: $store.scope) {
                    ForEach(RepositoryScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            ToolbarItemGroup {
                SortMenu()
                if store.isGeneratingCommit || store.isCommitting || store.isPushing || store.isPulling {
                    ProgressView().controlSize(.small)
                }
                Toggle(isOn: $store.fetchRemotes) {
                    Label("Fetch Remotes", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .help("Fetch all remotes before checking which branches need to be pushed")
                FolderMenu()
                if let repository = store.selectedRepository, repository.behind > 0 {
                    Button {
                        store.pull(repository)
                    } label: {
                        Label("Pull", systemImage: "arrow.down.circle.fill")
                    }
                    .help("Pull \(repository.behind) remote commit\(repository.behind == 1 ? "" : "s") into \(repository.name) using fast-forward only")
                    .disabled(
                        !repository.changes.isEmpty ||
                        store.isPulling ||
                        store.isPushing ||
                        store.isRefreshing ||
                        store.isCommitting ||
                        store.isGeneratingCommit
                    )
                }
                Button(role: .destructive) {
                    isCleanupConfirmationPresented = true
                } label: {
                    Label("Clean Gone Branches", systemImage: "trash")
                }
                .help("Safely delete merged local branches whose upstream branch is gone")
                .disabled(store.goneUpstreamBranchCount == 0 || store.isRefreshing || store.isCleaningBranches || !store.branchActionIDs.isEmpty)
                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || store.roots.isEmpty)
            }
        }
        .searchable(text: $store.query, placement: .sidebar, prompt: "Filter repositories")
        .confirmationDialog(
            "Clean Up \(store.goneUpstreamBranchCount) Gone Branch\(store.goneUpstreamBranchCount == 1 ? "" : "es")?",
            isPresented: $isCleanupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Safely", role: .destructive) {
                store.cleanupGoneBranches()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Git Review will use Git’s safe delete across all scanned repositories. Checked-out branches and branches with unmerged commits will be skipped; nothing will be force-deleted.")
        }
        .alert("Branch Cleanup Complete", isPresented: cleanupResultPresented) {
            Button("OK") { store.dismissCleanupResult() }
        } message: {
            if let result = store.cleanupResult {
                Text("\(result.summary)\n\n\(result.detail)")
            }
        }
        .confirmationDialog(
            "Generate a Commit Message?",
            isPresented: commitConsentPresented,
            titleVisibility: .visible
        ) {
            Button("Generate Commit Message") {
                store.generateCommitMessage()
            }
            Button("Cancel", role: .cancel) {
                store.cancelCommitConsent()
            }
        } message: {
            Text("Git Review will send a redacted, size-limited copy of the selected repository’s status and tracked diffs to OpenRouter. Untracked file contents are not sent. You will review the message before anything is staged or committed.")
        }
        .alert("Repository Action Could Not Be Completed", isPresented: commitErrorPresented) {
            Button("OK") { store.dismissCommitError() }
        } message: {
            Text(store.commitFlowError ?? "Unknown error")
        }
        .sheet(isPresented: commitDraftPresented) {
            CommitDraftSheet().environmentObject(store)
        }
        .onAppear { store.start() }
    }
}

struct RepositoryListHeader: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(store.attentionCount > 0 ? .orange : .green)
                Text(store.roots.isEmpty ? "No folders watched" : "\(store.roots.count) folder\(store.roots.count == 1 ? "" : "s") watched")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }

            if !store.repositories.isEmpty {
                HStack(spacing: 14) {
                    Metric(label: "Attention", value: store.attentionCount, color: .orange)
                    Metric(label: "Uncommitted", value: store.uncommittedCount, color: .orange)
                    Metric(label: "Unpushed", value: store.unpushedCount, color: .blue)
                    Metric(label: "Clean", value: store.cleanCount, color: .green)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

struct Metric: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(String(value)).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RepositoryList: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        List(selection: Binding(get: { store.selectedRepositoryID }, set: { store.select($0) })) {
            ForEach(store.visibleRepositories) { repository in
                RepositoryRow(repository: repository)
                    .tag(repository.id)
                    .contextMenu {
                        Button("Open in Terminal") { store.openTerminal(repository) }
                        Button("Reveal in Finder") { store.reveal(repository) }
                        Button("Copy Path") { store.copyPath(repository) }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.visibleRepositories.isEmpty {
                if store.roots.isEmpty {
                    ContentUnavailableView {
                        Label("Choose Your Workspaces", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add one or more folders. Git Review will find repositories below them and keep watch for local work.")
                    } actions: {
                        Button("Add Folders") { store.addRoots() }
                    }
                } else if store.repositories.isEmpty && store.isRefreshing {
                    ProgressView("Scanning folders...")
                } else if store.scope == .attention && !store.repositories.isEmpty {
                    ContentUnavailableView(
                        "Everything Is Accounted For",
                        systemImage: "checkmark.seal",
                        description: Text("No uncommitted files or unpublished branches were found.")
                    )
                } else {
                    ContentUnavailableView(
                        store.repositories.isEmpty ? "No Repositories Found" : "No Matches",
                        systemImage: "arrow.triangle.branch",
                        description: Text(store.repositories.isEmpty ? "Try adding a folder that contains Git repositories." : "Try a different filter.")
                    )
                }
            }
        }
    }
}

struct RepositoryRow: View {
    let repository: RepositorySnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(repository: repository, size: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(repository.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(repository.statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Text(repository.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 11) {
                    Label(repository.branch, systemImage: "arrow.triangle.branch")
                    if repository.workingTreeChangeCount > 0 {
                        Label("\(repository.workingTreeChangeCount) file\(repository.workingTreeChangeCount == 1 ? "" : "s")", systemImage: "doc.badge.ellipsis")
                    }
                    if !repository.unpublishedBranches.isEmpty {
                        Label(pushSummary, systemImage: "arrow.up.circle")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }

    private var pushSummary: String {
        let commits = repository.unpublishedCommitCount
        let local = repository.localOnlyBranchCount
        if commits > 0 { return "\(commits) ahead" }
        return "\(local) local branch\(local == 1 ? "" : "es")"
    }

    private var statusColor: Color {
        repository.isClean ? .green : (repository.statusError == nil ? .orange : .red)
    }
}

struct RepositoryDetail: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        Group {
            if let repository = store.selectedRepository {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        DetailHeader(repository: repository)
                        RepositorySummary(repository: repository)
                        if let fetchError = repository.fetchError {
                            WarningStrip(title: "Remote fetch failed", detail: fetchError)
                        }
                        if let statusError = repository.statusError {
                            WarningStrip(title: "Git status failed", detail: statusError)
                        }
                        ChangeSection(repository: repository)
                        BranchSection(repository: repository)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select a Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Choose a repository to inspect its working tree and unpublished branches.")
                )
            }
        }
    }
}

struct WrappingHStack: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 10, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(for: subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let size = result.sizes[index]
            let position = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func arrangement(
        for subviews: Subviews,
        width: CGFloat
    ) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return (
            positions,
            sizes,
            CGSize(width: contentWidth, height: sizes.isEmpty ? 0 : y + rowHeight)
        )
    }
}

struct DetailHeader: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                StatusDot(repository: repository, size: 12)
                Text(repository.name).font(.title2.weight(.semibold)).lineLimit(1)
                StatusPill(text: repository.statusLabel, good: repository.isClean)
                Spacer()
            }
            Text(repository.path.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8) {
                Button { store.requestCommit(repository) } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(repository.changes.isEmpty || store.isGeneratingCommit || store.isCommitting || store.isPushing || store.isPulling)
                Button { store.push(repository) } label: {
                    Label("Push", systemImage: "arrow.up.circle")
                }
                .fixedSize(horizontal: true, vertical: false)
                .help(repository.currentBranchNeedsPush ? "Push local commits from \(repository.branch)" : "The current branch has no commits waiting to be pushed")
                .disabled(!repository.currentBranchNeedsPush || store.isGeneratingCommit || store.isCommitting || store.isPushing || store.isPulling || store.isRefreshing)
                Button { store.pull(repository) } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                .fixedSize(horizontal: true, vertical: false)
                .help(repository.changes.isEmpty ? "Pull the current branch using fast-forward only" : "Commit or discard local changes before pulling")
                .disabled(!repository.changes.isEmpty || store.isPulling || store.isPushing || store.isRefreshing || store.isCommitting || store.isGeneratingCommit)
                Button { store.openTerminal(repository) } label: { Label("Open Terminal", systemImage: "terminal") }
                    .fixedSize(horizontal: true, vertical: false)
                Button { store.reveal(repository) } label: { Label("Reveal in Finder", systemImage: "folder") }
                    .fixedSize(horizontal: true, vertical: false)
                Button { store.copyPath(repository) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    .fixedSize(horizontal: true, vertical: false)
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(store.isRefreshing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CommitDraftSheet: View {
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Commit Message").font(.title3.weight(.semibold))
                    Text(store.commitDraft?.repository.name ?? "Repository")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.commitDraft?.model ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $store.commitMessage)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("\(store.commitDraft?.summary ?? "") · Git Review will verify the diff again, then stage all changes and commit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { store.cancelCommitDraft() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Commit Changes") {
                    store.commitGeneratedMessage()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isCommitting)
            }
        }
        .padding(22)
        .frame(width: 620, height: 390)
        .interactiveDismissDisabled(store.isCommitting)
    }
}

struct RepositorySummary: View {
    let repository: RepositorySnapshot

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 9) {
            GridRow {
                MetadataColumn(items: [
                    ("Branch", repository.branch),
                    ("Upstream", repository.upstream ?? "No upstream"),
                    ("Ahead / behind", "+\(repository.ahead) / -\(repository.behind)"),
                    ("Remote", repository.remoteURL ?? "No origin")
                ])
                MetadataColumn(items: [
                    ("Staged", String(repository.stagedCount)),
                    ("Modified", String(repository.modifiedCount)),
                    ("Untracked", String(repository.untrackedCount)),
                    ("Conflicts", String(repository.conflictCount))
                ])
            }
        }
        .padding(.vertical, 2)

        if let subject = repository.lastCommitSubject {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text(repository.lastCommitHash ?? "").font(.callout.monospaced().weight(.medium))
                Text(subject).font(.callout).lineLimit(1)
                Text(repository.lastCommitAge ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MetadataColumn: View {
    let items: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(items, id: \.0) { label, value in
                GridRow {
                    Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(value).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }
}

struct ChangeSection: View {
    let repository: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Working Tree").font(.headline)
            if repository.changes.isEmpty {
                EmptyLine(symbol: "checkmark.circle", text: "No uncommitted files", color: .green)
            } else {
                ForEach(Array(repository.changes.enumerated()), id: \.offset) { _, change in
                    HStack(spacing: 9) {
                        Text(changeLabel(change))
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(change.isConflicted ? .red : .orange)
                            .frame(width: 24, alignment: .leading)
                        Text(change.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if change.isStaged { Text("STAGED").font(.caption2.weight(.bold)).foregroundStyle(.blue) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func changeLabel(_ change: GitFileChange) -> String {
        if change.isUntracked { return "??" }
        return "\(change.indexStatus.map(String.init) ?? ".")\(change.workTreeStatus.map(String.init) ?? ".")"
    }
}

struct BranchSection: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Branches Needing Attention").font(.headline)
            if repository.unpublishedBranches.isEmpty {
                EmptyLine(symbol: "checkmark.circle", text: "All local branches are published", color: .green)
            } else {
                ForEach(repository.unpublishedBranches, id: \.name) { branch in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) {
                            Image(systemName: branch.upstream == nil ? "point.3.connected.trianglepath.dotted" : "arrow.up.circle.fill")
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                            Text(branch.name).font(.callout.weight(.medium))
                            Text(branch.upstreamGone ? "Upstream gone" : (branch.upstream ?? "No upstream"))
                                .font(.callout)
                                .foregroundStyle(branch.upstreamGone ? .orange : .secondary)
                            Spacer()
                            if branch.ahead > 0 { Text("\(branch.ahead) ahead").font(.caption.weight(.semibold)).foregroundStyle(.blue) }
                            if branch.behind > 0 { Text("\(branch.behind) behind").font(.caption).foregroundStyle(.secondary) }
                            if store.isBranchActionInProgress(repository: repository, branch: branch) {
                                ProgressView().controlSize(.small).frame(width: 62)
                            } else if branch.upstreamGone {
                                Button(role: .destructive) {
                                    store.cleanupBranch(repository: repository, branch: branch)
                                } label: {
                                    Label("Clean Up", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .tint(.orange)
                                .disabled(store.isRefreshing || store.isCleaningBranches)
                                .help("Safely delete this local branch; unmerged or checked-out branches are preserved")
                            } else if branch.ahead > 0 {
                                Button {
                                    store.pushBranch(repository: repository, branch: branch)
                                } label: {
                                    Label("Push", systemImage: "arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .tint(.blue)
                                .disabled(store.isRefreshing || store.isCleaningBranches)
                                .help("Push \(branch.name) to its configured upstream")
                            }
                        }
                        BranchActivitySummary(branch: branch)
                            .padding(.leading, 27)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct BranchActivitySummary: View {
    let branch: BranchTrackingStatus

    var body: some View {
        WrappingHStack(horizontalSpacing: 14, verticalSpacing: 4) {
            if let date = branch.lastCommitDate {
                activityLabel("Commit", date: date, symbol: "clock")
            }
            if let date = branch.lastCheckoutDate {
                activityLabel("Used", date: date, symbol: "arrow.left.arrow.right")
            }
            if branch.upstreamGone, let date = branch.approximateCreatedDate {
                activityLabel("Created ~", date: date, symbol: "sparkles")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func activityLabel(_ label: String, date: Date, symbol: String) -> some View {
        Label("\(label) \(relativeAge(date))", systemImage: symbol)
            .fixedSize(horizontal: true, vertical: false)
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func relativeAge(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct EmptyLine: View {
    let symbol: String
    let text: String
    let color: Color
    var body: some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(color)
    }
}

struct WarningStrip: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusDot: View {
    let repository: RepositorySnapshot
    let size: CGFloat
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1) }
            .shadow(color: color.opacity(0.4), radius: size * 0.4)
            .accessibilityLabel(repository.statusLabel)
    }
    private var color: Color {
        if repository.statusError != nil || repository.conflictCount > 0 { return .red }
        if repository.needsAttention { return .orange }
        return .green
    }
}

struct StatusPill: View {
    let text: String
    let good: Bool
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((good ? Color.green : Color.orange).opacity(0.16))
            .foregroundStyle(good ? .green : .orange)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SortMenu: View {
    @EnvironmentObject private var store: RepositoryStore
    var body: some View {
        Menu {
            ForEach(RepositorySort.allCases) { sort in
                Button { store.sort = sort } label: {
                    Label(sort.label, systemImage: store.sort == sort ? "checkmark" : sort.systemImage)
                }
            }
        } label: {
            Label("Sort: \(store.sort.label)", systemImage: store.sort.systemImage)
        }
    }
}

struct FolderMenu: View {
    @EnvironmentObject private var store: RepositoryStore
    var body: some View {
        Menu {
            Button { store.addRoots() } label: {
                Label("Add Folders...", systemImage: "folder.badge.plus")
            }
            if !store.roots.isEmpty {
                Divider()
                ForEach(store.roots, id: \.path) { root in
                    Menu(root.lastPathComponent) {
                        Text(root.path)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                        Divider()
                        Button("Stop Watching", role: .destructive) {
                            store.removeRoot(root)
                        }
                    }
                }
            }
        } label: {
            Label("Watched Folders", systemImage: "folder")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var store: RepositoryStore
    var body: some View {
        HStack(spacing: 8) {
            Text(store.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let date = store.lastRefreshed {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: RepositoryStore
    var body: some View {
        if store.roots.isEmpty {
            Button("Add Folders...") {
                NSApp.activate(ignoringOtherApps: true)
                store.addRoots()
            }
        } else {
            Button("Refresh Now") { store.refresh() }
            Toggle("Fetch Remotes", isOn: $store.fetchRemotes)
            Divider()
            if store.attentionCount == 0 {
                Text(store.repositories.isEmpty ? "No repositories scanned" : "All repositories up to date")
            } else {
                ForEach(store.repositories.filter(\.needsAttention).sorted { $0.name < $1.name }.prefix(15)) { repository in
                    Button("\(repository.name) — \(repository.statusLabel)") {
                        store.select(repository.id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct GitReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()

    var body: some Scene {
        WindowGroup("Git Review") {
            ContentView().environmentObject(store)
        }

        MenuBarExtra("Git Review", systemImage: "arrow.triangle.branch") {
            MenuBarContent()
                .environmentObject(store)
                .onAppear { store.start() }
        }

        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folders...") { store.addRoots() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Refresh Repositories") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(store.roots.isEmpty || store.isRefreshing)
            }
        }
    }
}
