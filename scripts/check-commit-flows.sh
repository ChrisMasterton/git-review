#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
sed '/^@main$/d' Sources/GitReview/GitReviewApp.swift > "$scratch/GitReviewApp.swift"
sources=()
for source in Sources/GitReview/*.swift; do
    if [[ "$source" != Sources/GitReview/GitReviewApp.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -I "$bin_dir/Modules" "${sources[@]}" "$scratch/GitReviewApp.swift" Tests/Smoke/CommitFlows.swift "$bin_dir"/GitReviewCore.build/*.o -o "$scratch/check-commit-flows"
"$scratch/check-commit-flows"
