# Worktree changes

Use `CheckoutFolder.isMissing` to establish absence independently of Git inspection status; inaccessible paths are never missing. Worktree mutations must use explicit captured paths and fresh registration checks. Run `scripts/check-worktree-flows.sh` when changing worktree size, selection or cleanup.
