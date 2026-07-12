#!/usr/bin/env bash
# Focused M59 packaging test: ignored worktree files must not enter releases.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
output_dir="$(mktemp -d)"
sentinel="$repo_root/daemon/.env.release-ignored-sentinel"

cleanup() {
  rm -f "$sentinel"
  rm -rf "$output_dir"
}
trap cleanup EXIT

printf 'must not ship\n' > "$sentinel"
git -C "$repo_root" check-ignore -q "$sentinel"
"$repo_root/scripts/release.sh" --dry-run --output-dir "$output_dir" v0.1.0 >/dev/null

tarball="$output_dir/relay-server-0.1.0.tar.gz"
if tar -tzf "$tarball" | grep -E '(^|/)(\.env|\.env\.|node_modules|vendor|coverage|spec)(/|$)' >/dev/null; then
  echo "error: ignored or development payload found in release" >&2
  exit 1
fi

if tar -tzf "$tarball" | grep -F '.env.release-ignored-sentinel' >/dev/null; then
  echo "error: ignored sentinel found in release" >&2
  exit 1
fi

echo "release packaging test passed: ignored sentinel absent"
