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

# Commit retries and stale file actions

2026-10-24: A rejected pre-commit hook left the message visible, but retry failed with “The repository changed after the commit draft was opened” even when no files changed. Git Review's own staging had invalidated the draft fingerprint. The commit service now captures the staged fingerprint before invoking hooks and returns it with a rejected commit so the retained draft can retry. The real-hook store regression failed before the repair; it now retries successfully and reads back exactly one commit, its message and file contents, and a clean working tree. A separate hook edits and stages a file before rejecting: retry still refuses that unreviewed content, preserves the message and control file, and leaves HEAD unchanged. No fingerprint is captured after a failed hook.

Switching branches in Terminal before opening a draft allowed Commit to save onto the new branch while the screen still named the scanned branch. The same switch during a Discard confirmation removed the carried-over working-tree edit. Both real-Git witnesses failed before the repair. Draft preparation and Discard now reuse the existing fresh branch check; unchanged detached checkouts remain supported, with their captured commit checked as well. Regression readback confirms unchanged branch refs, index and working-tree content for refused actions, plus successful commit/discard on a reviewed detached checkout.

# Failed fetch visibility

2026-10-24: A clean repository with an unavailable remote disappeared from the default Attention list, and the refresh summary said every repository was up to date. Fetch errors were recorded but omitted from attention and ranking. They now retain the repository in Attention with a “Fetch failed” label when no higher-priority local issue exists. The real local-remote regression failed before the repair; moving the bare remote offline reproduces the warning, keeps the failing repository visible alongside an unchanged clean control, and preserves local branch/status facts and HEAD. Restoring the remote and refreshing clears the warning and restores the clean counts.

Guards: `swift test` covers the new production-service/store journeys against disposable repositories, real hooks and local bare remotes. Existing push-target, branch-switch, commit-fingerprint, worktree and discard checks remain controls. No hosted remote, OpenRouter request, installed-app update or interactive GUI validation is part of this evidence.

Saved-result verification: `swift test --jobs 4` passed all 52 Swift Testing tests and 2 XCTest tests. Both `scripts/check-commit-flows.sh` and `scripts/check-worktree-flows.sh` passed, including real Trash recovery. `scripts/build-app.sh` produced `.build/Git Review.app`, and `git diff --check` passed. The test linker emitted a missing cached `_SwiftConcurrencyShims` module warning, but linked successfully and executed every suite.

# Commit verification output fidelity

2026-10-24: Editing a non-UTF-8 tracked text file after reviewing a draft was silently accepted and committed. Decoding the whole Git diff as UTF-8 failed and replaced the entire output with an empty string, leaving the fingerprint unchanged. Git command results now retain stdout bytes separately from display text; commit fingerprints hash the exact staged and unstaged diff bytes. Display decoding substitutes invalid sequences rather than losing the whole diff. The real-Git witness failed before the repair; guards now cover staged and unstaged edits, unchanged HEAD/index after refusal, successful fresh review, exact saved blob IDs and an unchanged control file.

A new file named ` notes.txt` had the same failure: trimming the beginning of `ls-files -z` output changed the path to `notes.txt`, so verification hashed a nonexistent file instead of the selected file. Untracked fingerprints now read the raw NUL-delimited path listing. The failing witness previously saved the later edit; it now rejects it without staging, retains the edited input, and confirms the exact saved blob and clean checkout after a fresh review.

Retargeting an untracked symlink to another same-length destination with identical target-file contents also went undetected and saved the unreviewed link. The fingerprint followed the link and hashed target contents, although Git saves the destination string itself. Symlink fingerprints now hash that string with a distinct type marker. The real-Git regression checks refusal without changing HEAD/index or either target file, then reads back the exact saved destination and Git symlink mode after fresh review.

An edit made while staging was paused also bypassed the intended refusal. Its first porcelain status line began with ` M`; stdout trimming removed the index-column space, and the column-based check missed the unstaged edit. The commit completed while that edit remained outside it. Staging verification now reuses the existing porcelain-v2/NUL parser. A bounded real clean filter holds `git add` while the fixture edits an earlier path. The regression failed before the repair; it now confirms the changed-while-staging error, unchanged HEAD and control index entry, preserved staged and unstaged input, and exact contents of both files after fresh review and commit.

# Ignore-rule precedence

2026-10-24: Add to .gitignore saved successfully but left a directory untracked when its existing rule was followed by a negation. Duplicate detection returned early for any earlier copy of the rule, overlooking Git's later-rule precedence. Only an identical final rule now skips appending, so a new ignore request takes precedence over prior exceptions. The real `git check-ignore` witness failed before the repair. Readback after saving and reopening confirms the selected root directory is ignored, neighboring and nested control paths remain visible, existing text is preserved, and repeating the final rule adds no duplicate.

These guards use disposable local Git repositories, exact blob IDs, saved-file readback and real Git ignore evaluation. Existing hook-retry, push-target, stale-checkout, watched-folder and privacy/prompt-budget checks remain controls; this evidence does not include hosted remotes, OpenRouter requests or GUI interaction.

Saved-result verification for this follow-up: `swift test --jobs 4` passed all 56 Swift Testing tests and 3 XCTest tests. Both commit and worktree smoke scripts passed, including real Trash recovery, and `scripts/build-app.sh` produced the updated local app bundle. `git diff --check` passed. The same cached `_SwiftConcurrencyShims` linker warning remained nonblocking. These new source changes are not committed or installed by this hunt.

# Commit drafts for untracked Git objects and configured diffs

2026-10-29: Making an untracked script executable after opening a draft left its fingerprint unchanged, so confirming the old draft saved the unreviewed executable mode. Advancing an untracked nested repository had the same failure: the directory read produced a constant fingerprint, and confirmation saved its newer commit. Both real-Git witnesses committed successfully before the repair when refusal was expected. Untracked draft verification now reuses the confirmation content helper, including executable mode and nested-repository HEAD, while retaining bounded sampling for large files. The regressions verify refusal before staging, unchanged parent HEAD/index and control contents, then exact saved Git mode or gitlink commit after a fresh review.

Enabling `diff.mnemonicPrefix` changed staged and unstaged headers for the same new file to `c/i` and `i/w`. The prompt builder matched full headers, so unstaged new-file contents bypassed its omission rule. The existing production prompt regression failed with this Git setting enabled. Diff reads now use explicit consistent prefixes; both settings omit the contents, retain the prompt budget, and still detect later edits. Prompt inspection is local and makes no OpenRouter request.

Ruled-out probes: ordinary binary edits already change the tracked diff fingerprint through Git's blob IDs; tracked paths beginning with a space remain intact in the NUL-delimited status parser. Neither required a production change.

Verification: `swift test --jobs 4` passed all 61 Swift Testing tests and 3 XCTest tests. Both smoke scripts passed, including real Git/Trash readback, and `scripts/build-app.sh` produced `.build/Git Review.app`. `git diff --check` passed. The focused test rebuild emitted the existing nonblocking cached `_SwiftConcurrencyShims` linker warning. Validation covered local source and disposable repositories; the app was not installed, and this run did not exercise the GUI, a hosted remote or OpenRouter.
