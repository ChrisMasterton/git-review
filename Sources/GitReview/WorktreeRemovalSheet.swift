import SwiftUI

struct WorktreeRemovalSheet: View {
    @EnvironmentObject private var store: RepositoryStore
    let checkout: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Remove Worktree?", systemImage: "trash")
                .font(.title3.weight(.semibold))
            Text(checkout.branch == "(detached)" ? "Detached HEAD" : "Branch: \(checkout.branch)")
                .font(.callout.weight(.medium))
            Text(checkout.path.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("This permanently deletes the checkout folder, including uncommitted, untracked and ignored files, and removes its worktree registration. If the folder is already missing, only its registration is removed.")
                .font(.callout)
            if !checkout.changes.isEmpty {
                Text("This also discards \(checkout.changes.count) uncommitted item(s), including \(checkout.changes.prefix(3).map(\.path).joined(separator: ", ")).")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text(checkout.worktree.isDetached
                 ? "Detached commits without a branch or tag may be lost. Locked worktrees cannot be removed."
                 : "The local branch and its commits are kept. Locked worktrees cannot be removed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { store.worktreeToRemove = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove Worktree", role: .destructive) { store.removeWorktree(checkout) }
                    .disabled(store.isRemovingWorktree)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
