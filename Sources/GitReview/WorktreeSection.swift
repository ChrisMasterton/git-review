import SwiftUI

struct WorktreeSection: View {
    @EnvironmentObject private var store: RepositoryStore
    let group: RepositoryGroup
    @State private var showMissing = false
    @State private var cleanupTargets: [RepositorySnapshot] = []
    private var missing: [RepositorySnapshot] { group.worktrees.filter { $0.path != group.path && $0.hasMissingDirectory } }
    private var visible: [RepositorySnapshot] { group.worktrees.filter { showMissing || $0.path == group.path || !$0.hasMissingDirectory } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worktrees (\(group.worktrees.count))").font(.headline)
            if !missing.isEmpty {
                HStack {
                    Button {
                        showMissing.toggle()
                    } label: {
                        Label("\(missing.count) missing folders · 0 B checkout files", systemImage: showMissing ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Clear Missing…") {
                        cleanupTargets = missing.filter { WorktreeRemoval.disabledReason(for: $0) == nil }
                    }
                    .disabled(!store.canRequestWorktreeRemoval || missing.allSatisfy { WorktreeRemoval.disabledReason(for: $0) != nil })
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("These folders are already gone. Clear their stale Git registrations in one step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(visible) { checkout in
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
                    WorktreeDiskUsageLabel(path: checkout.path)
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
        .confirmationDialog("Clear missing worktree registrations?", isPresented: Binding(
            get: { !cleanupTargets.isEmpty },
            set: { if !$0 { cleanupTargets = [] } }
        ), titleVisibility: .visible) {
            Button("Clear Missing Registrations", role: .destructive) {
                store.clearMissingWorktrees(cleanupTargets)
                cleanupTargets = []
            }
            Button("Cancel", role: .cancel) { cleanupTargets = [] }
        } message: {
            Text("Clear stale worktree registrations from \(group.path.path)? Git rechecks all registrations in this repository and prunes stale metadata only. Checkout folders are never deleted and locked registrations are kept. Detached commits without a branch or tag may be lost.")
        }
        .onChange(of: group.id) { _, _ in showMissing = false; cleanupTargets = [] }
    }
}
