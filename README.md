# Git Review

Git Review is a native macOS utility for keeping track of unfinished Git work across many local repositories. Point it at one or more workspace folders and it recursively finds Git repositories, fetches their remotes, and highlights anything that still needs to be committed or pushed.

It follows the same lightweight SwiftUI approach as Container Review: no third-party dependencies, a focused list/detail workspace, a menu-bar companion, and a local `.app` build.

## What it checks

- Staged, modified, untracked, and conflicted files in each working tree.
- Every registered linked worktree, including checkouts in hidden directories or outside watched folders. Checkouts are grouped under one repository, with individual paths, branches, and changed-file counts.
- Unavailable worktrees and incomplete worktree discovery, which keep a repository in Attention instead of reporting it fully checked.
- Commits ahead of the configured upstream on every local branch, not only the checked-out branch.
- Local branches without an upstream, unless their tip is already present on a remote branch.
- Branch activity context: reliable last-commit age, local reflog-derived last-used age, and an approximate creation age when the original branch-creation reflog entry still exists.
- Commits behind the current branch's upstream. Repositories whose current branch is behind count as needing attention with a "Behind remote" label.
- Remote fetch failures, shown without hiding the local status result.
- One-click cleanup for unpublished local branches and branches whose upstream is gone. Cleanup uses Git's safe delete and skips checked-out or unmerged branches rather than force-deleting work.
- An assisted commit flow that generates an editable commit message from the selected repository's pending status and tracked diffs, then stages and commits all changes after confirmation.
- Separate Commit and Push actions, plus a fast-forward-only Pull action for clean working trees.
- Inline branch actions: publish a local-only branch to `origin`, safely clean up an unpublished or stale branch, or push any tracked branch that is ahead without checking it out first.

Remote fetching is enabled by default so the result reflects work pushed from other computers. Git prompts are disabled during automated refreshes; repositories that need interactive credentials show a fetch warning instead of blocking the scan. Automatic refresh runs every five minutes while the app is open.

Git Review follows Git's registered worktree list from each discovered checkout, so watching a linked checkout also finds its main checkout and siblings. It fetches and counts shared branches once per repository. Select a checkout in the Worktrees section to inspect its files and scope Commit, Push, Pull, Finder, and Terminal actions to that path. Missing or inaccessible checkouts retain their paths and show “Unavailable”; they are not automatically removed or pruned. Independently cloned repositories remain separate even when they have the same remote.

Use a checkout's **… → Remove Worktree…** menu to remove a linked checkout after confirming its exact path. This deletes the checkout directory, including ignored files, but keeps its local branch and commits. For a missing directory, it removes only that worktree's registration. The main checkout cannot be removed; dirty or locked checkouts are protected, and detached commits must be retained by an existing branch or tag. Git Review rechecks the checkout before removal and never forces removal or prunes other worktrees.

## OpenRouter commit messages

Export either `openrouter_api_key` or `OPENROUTER_API_KEY` in your shell configuration (for example, `~/.zshrc`) or set it in the environment used to launch Git Review. Apps opened from Finder or the Dock do not inherit Terminal's shell exports, so when no key is inherited, Git Review reads the OpenRouter settings from your interactive login shell. This lookup runs in the background with a five-second timeout and keeps the values in memory. Inherited app settings take precedence. `openrouter_model` or `OPENROUTER_MODEL` can optionally override the default `openrouter/auto` model. The shell fallback is checked on each generation attempt, so changes to shell exports can be picked up by retrying.

The Commit button first asks for permission to send data. Git Review redacts common credential formats, caps the request payload, and sends tracked diffs plus status information; untracked file contents are not sent. The generated message remains editable. Before staging anything, the app verifies that the working change set still matches the one used to generate the message, protecting against another agent changing the repository during review.

Push publishes existing commits from the current branch without staging or committing working-tree changes. It uses the existing branch remote when configured and creates an `origin` upstream for a new local branch. A local-only branch listed under Branches Needing Attention can also be published directly without checking it out. Pull is available only for clean working trees and runs with `--ff-only`, so it never creates an implicit merge commit.

Large generated dependency folders such as `node_modules`, `.build`, and `DerivedData` are skipped during discovery without inspection. Generically named folders such as `bin`, `dist`, `obj`, `vendor`, `Build`, `Library`, or `Temp` are skipped only when neither the folder itself nor its direct children contain a repository, so real projects that happen to use those names are still found. Nested repositories elsewhere are always discovered.

## Run from source

Requires macOS 14 or newer and Swift 6.

```bash
swift run
```

Or:

```bash
./run.sh
```

## Build or install the app

```bash
./scripts/build-app.sh
open ".build/Git Review.app"
```

Install to `/Applications`:

```bash
./scripts/install.sh
```

Create a release zip and SHA-256 file:

```bash
./package-release.sh
```

## Privacy

Outside the explicitly confirmed OpenRouter commit-message flow, Git Review uses your local Git CLI for status and remote operations. Git runs with interactive prompts disabled; a custom `GIT_SSH_COMMAND` or `GIT_SSH` from your environment is respected rather than replaced. It reads folder paths selected by you and the linked worktree paths registered by those repositories, including paths outside watched folders. It never automatically pushes or removes worktrees; repository actions are initiated by you.

## License

MIT No Attribution. See [LICENSE](LICENSE).
