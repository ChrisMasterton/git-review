import Foundation
import SwiftUI

enum WorktreeDiskUsage {
    /// Allocated checkout bytes, excluding Git metadata. Symlinks are not followed.
    static func measure(_ root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var bytes: Int64 = 0
        for case let entry as URL in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: keys)
            if entry.lastPathComponent == ".git" {
                if values.isDirectory == true { entries.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory != true {
                guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                bytes += Int64(size)
            }
        }
        if let enumerationError { throw enumerationError }
        return bytes
    }
}

struct WorktreeDiskUsageLabel: View {
    let path: URL
    @State private var bytes: Int64?
    @State private var error: String?
    @State private var missing = false
    @State private var revision = 0
    @State private var measuring = true

    var body: some View {
        HStack(spacing: 5) {
            Label(missing ? "0 B · folder missing" : measuring ? "Calculating size…" : bytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " on disk"
            } ?? "Size unavailable", systemImage: "internaldrive")
            Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(measuring)
                .help("Recalculate checkout size")
                .accessibilityLabel("Recalculate checkout size")
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(missing ? "This checkout folder no longer exists. Only its Git registration remains; there are no checkout files to free." : error ?? "Estimated allocated space for checkout files, including hidden files, dependencies and build outputs. Excludes .git metadata and symlink targets. Shared filesystem blocks mean deleting this checkout may free less space.")
        .task(id: "\(path.path):\(revision)") {
            measuring = true
            bytes = nil
            error = nil
            missing = CheckoutFolder.isMissing(path)
            if missing { measuring = false; return }
            let task = Task.detached(priority: .utility) { try WorktreeDiskUsage.measure(path) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                bytes = result
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            measuring = false
        }
    }
}
