# Worktree filesystem state

2026-09-09: Missing Codex checkout folders appeared as “Size unavailable” and displaced an existing checkout as the default selection. Git inspection errors did not establish whether a directory was absent. Disk labels now distinguish confirmed filesystem absence; selection prefers accessible work; missing rows collapse with a scoped registration cleanup action. Cleanup uses Git prune with temporary locks protecting registrations outside the captured missing set, including inaccessible and restored checkouts. Lock-release failures are reported.

Permanent guard: `scripts/check-worktree-flows.sh` exercises real filesystem allocation and Git registrations, including missing, restored, inaccessible, locked and unrequested checkouts. GUI validation covers labels, collapsed rows, default selection, recalculation and cleanup confirmation/cancellation.

The real linked-worktree fixture also exposed undercounting: calling Foundation skipDescendants on the .git pointer file suppressed descendants of the next directory. Only actual directories now invoke skipDescendants; symlink targets remain excluded without suppressing unrelated folders. The same smoke check protects this boundary.

Dirty worktree removal: cranky-noether in hibob had an untracked CLAUDE.md, which disabled the removal menu despite the requested discard-on-confirm behavior. The menu now permits dirty checkouts; the confirmed store action explicitly enables discarding files, while direct service calls default to Git's refusal. The smoke guard checks both paths and locked-worktree rejection.

Per-item discard: Working Tree rows now capture the checkout and raw Git path before confirmation. Status uses NUL-delimited porcelain, preserving quoted/newline filenames and rename origins. Git restore uses literal pathspecs and only affects the selected tracked paths; untracked items go to Trash. The real-Git/Trash smoke checks include unrelated changes, staged/unstaged modifications, rename pairs, additions, special filenames and submodule refusal to avoid a silent no-op.
