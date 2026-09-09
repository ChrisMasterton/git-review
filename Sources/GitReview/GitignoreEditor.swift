import SwiftUI

struct GitignoreDocument {
    let url: URL
    let original: Data?
    var text: String

    init(root: URL) throws {
        url = root.appendingPathComponent(".gitignore")
        original = try Self.read(url)
        guard let decoded = String(data: original ?? Data(), encoding: .utf8) else {
            throw NSError(domain: "Gitignore", code: 1, userInfo: [NSLocalizedDescriptionKey: ".gitignore is not UTF-8 text."])
        }
        text = decoded
    }

    private static func read(_ url: URL) throws -> Data? {
        // Do not follow a symlink and accidentally edit a file outside this checkout.
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type],
           type as? FileAttributeType == .typeSymbolicLink {
            throw NSError(domain: "Gitignore", code: 2, userInfo: [NSLocalizedDescriptionKey: ".gitignore is a symbolic link. Edit its target separately."])
        }
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    mutating func appendDirectory(_ path: String) throws {
        guard path.hasSuffix("/"), !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              !path.contains("\n"), !path.contains("\r") else {
            throw NSError(domain: "Gitignore", code: 3, userInfo: [NSLocalizedDescriptionKey: "This directory path cannot be represented safely as an ignore rule."])
        }
        let escaped = path.map { character -> String in
            "\\*?[] !#".contains(character) ? "\\" + String(character) : String(character)
        }.joined()
        let rule = "/" + escaped
        if text.split(separator: "\n").contains(Substring(rule)) { return }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if !text.isEmpty && !text.hasSuffix("\n") { text += newline }
        text += rule + newline
    }

    func save(_ edited: String) throws {
        guard try Self.read(url) == original else {
            throw NSError(domain: "Gitignore", code: 4, userInfo: [NSLocalizedDescriptionKey: ".gitignore changed on disk. Close and reopen the editor to load the latest contents before saving."])
        }
        try Data(edited.utf8).write(to: url, options: .atomic)
    }
}

struct GitignoreEditor: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let directory: String?
    let onSave: () -> Void
    @State private var document: GitignoreDocument?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit .gitignore").font(.title3.weight(.semibold))
            Text(root.appendingPathComponent(".gitignore").path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let directory {
                Text("Review the rule for \(directory), then save to ignore this directory.").font(.callout)
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .disableAutocorrection(true)
                .border(Color.secondary.opacity(0.3))
                .disabled(document == nil)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        try document?.save(text)
                        onSave()
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(document == nil)
            }
        }
        .padding(22)
        .frame(width: 660, height: 460)
        .interactiveDismissDisabled()
        .onAppear {
            do {
                var loaded = try GitignoreDocument(root: root)
                if let directory { try loaded.appendDirectory(directory) }
                document = loaded
                text = loaded.text
            } catch { self.error = error.localizedDescription }
        }
    }
}
