import Foundation

struct OpenRouterConfiguration: Sendable {
    let apiKey: String?
    let model: String

    init(environment: [String: String], shellEnvironment: [String: String] = [:]) {
        apiKey = Self.value(["openrouter_api_key", "OPENROUTER_API_KEY"], in: environment)
            ?? Self.value(["openrouter_api_key", "OPENROUTER_API_KEY"], in: shellEnvironment)
        model = Self.value(["openrouter_model", "OPENROUTER_MODEL"], in: environment)
            ?? Self.value(["openrouter_model", "OPENROUTER_MODEL"], in: shellEnvironment)
            ?? "openrouter/auto"
    }

    /// Call off the main thread: shell startup may take a few seconds.
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) -> Self {
        let inherited = Self(environment: environment)
        guard inherited.apiKey == nil else { return inherited }
        return Self(environment: environment, shellEnvironment: shellEnvironment(environment, timeout: timeout))
    }

    private static func value(_ names: [String], in environment: [String: String]) -> String? {
        names.compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func shellEnvironment(_ environment: [String: String], timeout: TimeInterval) -> [String: String] {
        let accountShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = environment["SHELL"] ?? accountShell ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return [:] }

        let names = ["openrouter_api_key", "OPENROUTER_API_KEY", "openrouter_model", "OPENROUTER_MODEL"]
        let marker = "GitReviewOpenRouter-\(UUID().uuidString)"
        // printenv reads only exported values and works with zsh, bash, and fish.
        // NUL framing separates the four values from any shell startup chatter.
        let command = "/usr/bin/printf '\\0\(marker)\\0'; " + names.map {
            "/usr/bin/printenv \($0); /usr/bin/printf '\\0'"
        }.joined(separator: "; ") + "; /usr/bin/printf '\(marker)-end\\0'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", command]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = pipe.fileHandleForReading
        defer {
            try? reader.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = reader.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return [:] }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return [:]
        }
        try? pipe.fileHandleForWriting.close()

        // Keep credentials in memory, drain noisy startup output without blocking,
        // and never wait for EOF from a background child that inherited stdout.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        func drain() {
            for _ in 0..<32 {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 65_536 { output = Data(output.suffix(65_536)) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let finished = exited.wait(timeout: .now() + 0.02) == .success
            drain()
            if finished { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
                return [:]
            }
        }
        guard process.terminationStatus == 0 else { return [:] }
        let fields = String(decoding: output, as: UTF8.self).components(separatedBy: "\0")
        guard let start = fields.firstIndex(of: marker), fields.count > start + names.count + 1,
              fields[start + names.count + 1] == "\(marker)-end" else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, fields[(start + 1)..<(start + 1 + names.count)]))
    }
}
