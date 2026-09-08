# Release Notes

## Unreleased

- Added confirmed removal of individual linked worktrees from their actions menu, including stale registrations for missing folders. Main, dirty, locked, changed, and unreferenced detached checkouts are protected; local branches are kept.
- Automatically discover registered linked worktrees, including hidden checkouts and paths outside watched folders, and group them under their repository.
- Show each checkout's branch, path, changed files, and availability; select a checkout to inspect its files or open its exact folder in Finder or Terminal.
- Keep repositories with unavailable worktrees or incomplete discovery in Attention. Shared branches, repository counts, and remote fetches are counted once per repository.
- Recheck checkout identity before Git actions so a removed or replaced checkout cannot fall back to a parent repository.

## 0.2.0

- Fixed a possible permanent hang when a Git command wrote more than a pipe buffer of output; subprocess output now goes through temporary files and every Git command has an overall timeout, with remote fetches allowed up to ten minutes.
- Tightened the assisted commit flow: after staging, the working tree is verified again, and any change that appeared while staging aborts the commit instead of committing unverified edits.
- Commit change-set fingerprints now ignore ahead/behind/gone tracking summaries, so a background remote refresh no longer invalidates a message being reviewed.
- Fixed garbled non-ASCII filenames by disabling Git path quoting for status and diff output.
- Improved repository discovery: generically named folders such as `bin`, `dist`, `obj`, `vendor`, `Build`, `Library`, or `Temp` are skipped only when neither the folder itself nor its direct children contain a repository, while dependency folders such as `node_modules` remain always skipped.
- Repositories whose current branch is behind its upstream now count as needing attention with a "Behind remote" label and an inline branch hint.
- Capped untracked-file fingerprinting at the file size plus the first and last 512 KiB so large untracked artifacts cannot slow commit-message generation.
- A custom `GIT_SSH_COMMAND` or `GIT_SSH` and HTTP low-speed settings from the environment are now respected instead of replaced; interactive Git prompts remain disabled.

## 0.1.0

- Added recursive monitoring for one or more local workspace folders.
- Added remote-aware detection of uncommitted files and unpublished work across every local branch.
- Added attention and all-repository views, search, priority sorting, detailed file and branch inspection, and Finder/Terminal shortcuts.
- Added persistent watched folders, optional remote fetching, five-minute automatic refresh, and menu-bar status access.
- Added native macOS app packaging, installation, release scripts, and parser tests.
- Added safe, repository-wide cleanup for merged local branches whose upstream branch is gone.
- Added an OpenRouter-assisted commit flow with diff disclosure, secret redaction, editable messages, change-set race detection, and explicit staging/commit confirmation.
- Added separate Push and fast-forward-only Pull actions to the selected repository view.
- Added a contextual toolbar Pull button when the selected branch is behind its fetched upstream.
- Added last-commit, last-used, and reflog-backed approximate creation ages to branches needing attention.
- Added compact per-branch Clean Up and Push actions beside actionable upstream status.
- Fixed local-only branches showing “Needs push” without an action by adding safe Clean Up and Publish controls.
