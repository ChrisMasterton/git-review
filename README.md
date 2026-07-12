# Git Review

Git Review is a native macOS utility for keeping track of unfinished Git work across many local repositories. Point it at one or more workspace folders and it recursively finds Git repositories, fetches their remotes, and highlights anything that still needs to be committed or pushed.

It follows the same lightweight SwiftUI approach as Container Review: no third-party dependencies, a focused list/detail workspace, a menu-bar companion, and a local `.app` build.

## What it checks

- Staged, modified, untracked, and conflicted files in each working tree.
- Commits ahead of the configured upstream on every local branch, not only the checked-out branch.
- Local branches without an upstream, unless their tip is already present on a remote branch.
- Branch activity context: reliable last-commit age, local reflog-derived last-used age, and an approximate creation age when the original branch-creation reflog entry still exists.
- Commits behind the current branch's upstream.
- Remote fetch failures, shown without hiding the local status result.
- One-click cleanup for unpublished local branches and branches whose upstream is gone. Cleanup uses Git's safe delete and skips checked-out or unmerged branches rather than force-deleting work.
- An assisted commit flow that generates an editable commit message from the selected repository's pending status and tracked diffs, then stages and commits all changes after confirmation.
- Separate Commit and Push actions, plus a fast-forward-only Pull action for clean working trees.
- Inline branch actions: publish a local-only branch to `origin`, safely clean up an unpublished or stale branch, or push any tracked branch that is ahead without checking it out first.

Remote fetching is enabled by default so the result reflects work pushed from other computers. Git prompts are disabled during automated refreshes; repositories that need interactive credentials show a fetch warning instead of blocking the scan. Automatic refresh runs every five minutes while the app is open.

## OpenRouter commit messages

Set either `openrouter_api_key` or `OPENROUTER_API_KEY` in the environment used to launch Git Review. `OPENROUTER_MODEL` can optionally override the default `openrouter/auto` model.

The Commit button first asks for permission to send data. Git Review redacts common credential formats, caps the request payload, and sends tracked diffs plus status information; untracked file contents are not sent. The generated message remains editable. Before staging anything, the app verifies that the working change set still matches the one used to generate the message, protecting against another agent changing the repository during review.

Push publishes existing commits from the current branch without staging or committing working-tree changes. It uses the existing branch remote when configured and creates an `origin` upstream for a new local branch. A local-only branch listed under Branches Needing Attention can also be published directly without checking it out. Pull is available only for clean working trees and runs with `--ff-only`, so it never creates an implicit merge commit.

Large generated dependency folders such as `node_modules`, `.build`, `DerivedData`, and `vendor` are skipped during discovery. Nested repositories elsewhere are still found.

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

Outside the explicitly confirmed OpenRouter commit-message flow, Git Review is local-only. It reads folder paths selected by you and shells out to the local Git CLI for discovery metadata, status, branch tracking, log summary, and remote fetch. Git Review never pushes. Branch deletion and commit actions run only after confirmation.

## License

MIT No Attribution. See [LICENSE](LICENSE).
