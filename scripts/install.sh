#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
app_name="Git Review"
app_dir="${repo_dir}/.build/${app_name}.app"
install_dir="${INSTALL_DIR:-/Applications}"
target_app="${install_dir}/${app_name}.app"

"${script_dir}/build-app.sh"
mkdir -p "$install_dir"
if [[ -w "$install_dir" ]]; then
    rm -rf "$target_app"
    ditto "$app_dir" "$target_app"
else
    sudo rm -rf "$target_app"
    sudo ditto "$app_dir" "$target_app"
fi
echo "Installed ${target_app}"
