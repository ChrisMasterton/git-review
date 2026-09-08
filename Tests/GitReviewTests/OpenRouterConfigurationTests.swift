import Foundation
import Testing
@testable import GitReview

private final class OpenRouterShellFixture {
    let directory: URL

    init(startup: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-review-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try startup.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var environment: [String: String] {
        ["HOME": directory.path, "ZDOTDIR": directory.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
    }
}

@Test func guiLaunchFindsExportedOpenRouterSettingsInZshrc() throws {
    let fixture = try OpenRouterShellFixture(startup: """
        print 'Shell startup message'
        export OPENROUTER_API_KEY='fixture-shell-key'
        export OPENROUTER_MODEL='fixture/shell-model'
        """)
    try "print 'Shell logout message'".write(
        to: fixture.directory.appendingPathComponent(".zlogout"), atomically: true, encoding: .utf8
    )
    let configuration = OpenRouterConfiguration.load(environment: fixture.environment)
    #expect(configuration.apiKey == "fixture-shell-key")
    #expect(configuration.model == "fixture/shell-model")
}

@Test func lowercaseShellSettingsAndNoisyStartupAreSupported() throws {
    let fixture = try OpenRouterShellFixture(startup: """
        for i in {1..10000}; do print 'Startup output that must not block the credential lookup'; done
        print 'Diagnostic' >&2
        export openrouter_api_key=' fixture-lowercase-key '
        export openrouter_model='fixture/lowercase-model'
        """)
    let configuration = OpenRouterConfiguration.load(environment: fixture.environment)
    #expect(configuration.apiKey == "fixture-lowercase-key")
    #expect(configuration.model == "fixture/lowercase-model")
}

@Test func inheritedKeySkipsShellStartup() throws {
    let fixture = try OpenRouterShellFixture(startup: "touch \"$HOME/startup-ran\"")
    var environment = fixture.environment
    environment["OPENROUTER_API_KEY"] = " fixture-app-key "
    let configuration = OpenRouterConfiguration.load(environment: environment)
    #expect(configuration.apiKey == "fixture-app-key")
    #expect(configuration.model == "openrouter/auto")
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("startup-ran").path))
}

@Test func inheritedSettingsTakePrecedenceAcrossAliases() {
    let configuration = OpenRouterConfiguration(
        environment: ["OPENROUTER_API_KEY": "app-key", "OPENROUTER_MODEL": "app/model"],
        shellEnvironment: ["openrouter_api_key": "shell-key", "openrouter_model": "shell/model"]
    )
    #expect(configuration.apiKey == "app-key")
    #expect(configuration.model == "app/model")
}

@Test func blankInheritedKeyFallsBackWhileKeepingInheritedModel() throws {
    let fixture = try OpenRouterShellFixture(startup: "export OPENROUTER_API_KEY='fixture-shell-key'")
    var environment = fixture.environment
    environment["openrouter_api_key"] = " \n "
    environment["OPENROUTER_MODEL"] = "fixture/app-model"
    let configuration = OpenRouterConfiguration.load(environment: environment)
    #expect(configuration.apiKey == "fixture-shell-key")
    #expect(configuration.model == "fixture/app-model")
}

@Test func unexportedOrMissingShellKeyRemainsMissing() throws {
    let fixture = try OpenRouterShellFixture(startup: "OPENROUTER_API_KEY='unexported-key'")
    let configuration = OpenRouterConfiguration.load(environment: fixture.environment)
    #expect(configuration.apiKey == nil)
    #expect(configuration.model == "openrouter/auto")
}

@Test func shellStartupTimeoutReturnsWithoutHanging() throws {
    let fixture = try OpenRouterShellFixture(startup: "while true; do :; done")
    let start = ProcessInfo.processInfo.systemUptime
    let configuration = OpenRouterConfiguration.load(environment: fixture.environment, timeout: 0.2)
    #expect(configuration.apiKey == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
}

@Test func unavailableShellLeavesConfigurationMissing() {
    let configuration = OpenRouterConfiguration.load(environment: ["SHELL": "/nonexistent/git-review-shell"])
    #expect(configuration.apiKey == nil)
}
