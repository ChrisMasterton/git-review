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
            Text("This permanently deletes the checkout folder, including ignored files, and removes its worktree registration. If the folder is already missing, only its registration is removed.")
                .font(.callout)
            Text(checkout.worktree.isDetached
                 ? "The detached commit must be reachable from an existing branch or tag. Git will refuse dirty or locked worktrees."
                 : "The local branch and its commits are kept. Git will refuse dirty or locked worktrees.")
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
