import SwiftUI

struct WorktreeSection: View {
    @EnvironmentObject private var store: RepositoryStore
    let group: RepositoryGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worktrees (\(group.worktrees.count))").font(.headline)
            ForEach(group.worktrees) { checkout in
                HStack(alignment: .top, spacing: 12) {
                    Button { store.select(checkout.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: store.selectedRepositoryID == checkout.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(store.selectedRepositoryID == checkout.id ? Color.accentColor : .secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                WrappingHStack(horizontalSpacing: 10, verticalSpacing: 4) {
                                    Text(checkout.branch == "(detached)" ? "Detached HEAD" : checkout.branch)
                                        .font(.callout.weight(.semibold))
                                    if checkout.path == group.path { Text("Main").font(.caption).foregroundStyle(.secondary) }
                                    StatusPill(text: checkout.checkoutStatusLabel, good: !checkout.checkoutNeedsAttention)
                                    if checkout.canAccessCheckout {
                                        Text("\(checkout.workingTreeChangeCount) changed file\(checkout.workingTreeChangeCount == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if checkout.worktree.lockReason != nil {
                                        Label("Locked", systemImage: "lock")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .help(checkout.worktree.lockReason ?? "")
                                    }
                                }
                                Text(checkout.path.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Inspect \(checkout.branch) at \(checkout.path.path), \(checkout.checkoutStatusLabel)")
                    Menu {
                        Button("Open Terminal") { store.openTerminal(checkout) }
                            .disabled(!checkout.canAccessCheckout)
                        Button("Reveal in Finder") { store.reveal(checkout) }
                            .disabled(!checkout.canAccessCheckout)
                        Button("Copy Path") { store.copyPath(checkout) }
                        Divider()
                        Button("Remove Worktree…", role: .destructive) {
                            store.requestWorktreeRemoval(checkout)
                        }
                        .disabled(WorktreeRemoval.disabledReason(for: checkout) != nil || !store.canRequestWorktreeRemoval)
                        .help(WorktreeRemoval.disabledReason(for: checkout) ?? "Remove this checkout folder; keep its branch")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Actions for \(checkout.path.path)")
                }
                .padding(10)
                .background(
                    store.selectedRepositoryID == checkout.id ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
    }
}
