# Worktree filesystem state

2026-09-09: Missing Codex checkout folders appeared as “Size unavailable” and displaced an existing checkout as the default selection. Git inspection errors did not establish whether a directory was absent. Disk labels now distinguish confirmed filesystem absence; selection prefers accessible work; missing rows collapse with a scoped registration cleanup action. Cleanup uses Git prune with temporary locks protecting registrations outside the captured missing set, including inaccessible and restored checkouts. Lock-release failures are reported.

Permanent guard: `scripts/check-worktree-flows.sh` exercises real filesystem allocation and Git registrations, including missing, restored, inaccessible, locked and unrequested checkouts. GUI validation covers labels, collapsed rows, default selection, recalculation and cleanup confirmation/cancellation.

The real linked-worktree fixture also exposed undercounting: calling Foundation skipDescendants on the .git pointer file suppressed descendants of the next directory. Only actual directories now invoke skipDescendants; symlink targets remain excluded without suppressing unrelated folders. The same smoke check protects this boundary.

Dirty worktree removal: cranky-noether in hibob had an untracked CLAUDE.md, which disabled the removal menu despite the requested discard-on-confirm behavior. The menu now permits dirty checkouts; the confirmed store action explicitly enables discarding files, while direct service calls default to Git's refusal. The smoke guard checks both paths and locked-worktree rejection.

Per-item discard: Working Tree rows now capture the checkout and raw Git path before confirmation. Status uses NUL-delimited porcelain, preserving quoted/newline filenames and rename origins. Git restore uses literal pathspecs and only affects the selected tracked paths; untracked items go to Trash. The real-Git/Trash smoke checks include unrelated changes, staged/unstaged modifications, rename pairs, additions, special filenames and submodule refusal to avoid a silent no-op.

# Commit and push action integrity

2026-10-23: The checkout-level Push used a bare `git push`, unlike the branch-row action. With a differently named upstream, Git's default `simple` mode rejected the push; `matching` mode instead advanced an unrelated branch and left the selected branch unpublished. Both actions now share explicit source and destination branch refs. Real local bare-remote tests read back the intended upstream commit, the unchanged control branch, and refreshed ahead counts for both modes.

A same-named tag made Git shorten a branch to `heads/main`, breaking current-branch matching, while short push refspecs failed as ambiguous. Branch discovery now retains literal local names, and containment, reflog and push commands use qualified branch refs. The tracked and unpublished fixtures both push successfully, configure or retain `origin/main`, preserve the local tag, and read back the saved remote commit.

Switching branches in Terminal after a scan caused the checkout-level Push to publish the newly checked-out branch despite the screen still naming the original branch. Pull likewise advanced the other branch and changed its files. Both actions now share a fresh branch check. Real-Git regressions verify that stale actions leave remote refs, local commits and file contents unchanged; refreshing the actual checkout then permits its ordinary fast-forward pull.

Cancel or Escape could clear a commit draft while a hook was still running, leaving no message to retry after rejection. The editor and Cancel action now remain locked until Git finishes, with a store guard covering cancellation paths. A bounded real pre-commit hook holds the save for the regression: cancellation preserves the draft while pending; rejection retains it; success reads back the submitted commit message and file content with a clean working tree.

Permanent guards: the added cases in `Tests/GitReviewTests/CommitServiceTests.swift` run with `swift test`. These exercise the production scanner, action services and store against disposable local Git repositories; they do not contact a hosted remote or OpenRouter. Existing commit fingerprint, worktree and discard smoke checks remain separate guards.

# Watched folders during refresh

2026-10-23: Stop Watching saved the reduced folder list while a refresh was pending, but that scan subsequently restored the removed repositories and their selected detail. Refresh now discards results captured for an older folder list and checks the current roots. The real-scanner store regression covers stopping one of two roots and the last root, asserting exact visible checkout paths, cleared selection, empty-state text and preferences reloaded from an isolated UserDefaults suite. The fixture compares filesystem paths rather than URL directory-slash spellings.
