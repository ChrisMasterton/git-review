#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_dir"
version="${1:-${GIT_REVIEW_VERSION:-}}"
if [[ -z "$version" ]]; then version="$(< VERSION)"; fi
version="${version#v}"

./scripts/build-app.sh "$version"
mkdir -p dist
zip_name="GitReview-${version}-macOS.zip"
rm -f "dist/${zip_name}" "dist/${zip_name}.sha256"
ditto -c -k --keepParent --norsrc --noextattr ".build/Git Review.app" "dist/${zip_name}"
(cd dist && shasum -a 256 "$zip_name" > "${zip_name}.sha256")
echo "Packaged dist/${zip_name}"
