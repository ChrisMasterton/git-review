#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Compile the production types with a smoke-test entrypoint, without requiring
# Swift Testing (absent from some standalone Command Line Tools installations).
sed '/^@main$/d' Sources/GitReview/GitReviewApp.swift > "$scratch/GitReviewApp.swift"
sources=()
for source in Sources/GitReview/*.swift; do
    if [[ "$source" != Sources/GitReview/GitReviewApp.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -I "$bin_dir/Modules" "${sources[@]}" "$scratch/GitReviewApp.swift" Tests/Smoke/WorktreeFlows.swift "$bin_dir"/GitReviewCore.build/*.o -o "$scratch/check-worktree-flows"
"$scratch/check-worktree-flows"
