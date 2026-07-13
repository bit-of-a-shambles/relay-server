#!/usr/bin/env bash
# Build and publish a Relay Server release.
set -euo pipefail

readonly GITHUB_REPO="bit-of-a-shambles/relay-server"

usage() {
  cat >&2 <<'EOF'
usage: scripts/release.sh [--dry-run] [--output-dir DIR] vX.Y.Z

--dry-run       assemble and checksum the release without calling gh
--output-dir    write artifacts to DIR (default: dist/releases)
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

dry_run="${RELAY_RELEASE_DRY_RUN:-0}"
output_dir="${RELAY_RELEASE_OUTPUT_DIR:-}"
tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    v*)
      [[ -z "$tag" ]] || { usage; exit 2; }
      tag="$1"
      shift
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must match vX.Y.Z" >&2
  usage
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
version="${tag#v}"
formula_template="$repo_root/packaging/homebrew/relay.rb"

if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  echo "error: release requires a clean git tree" >&2
  git -C "$repo_root" status --short >&2
  exit 1
fi

if [[ -z "$output_dir" ]]; then
  output_dir="$repo_root/dist/releases"
elif [[ "$output_dir" != /* ]]; then
  output_dir="$PWD/$output_dir"
fi

if [[ "$dry_run" != "1" && "$dry_run" != "true" ]]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required for a real release (use --dry-run for local assembly)"
  remote_repo="$(gh repo view "$GITHUB_REPO" --json nameWithOwner --jq .nameWithOwner)"
  [[ "$remote_repo" == "$GITHUB_REPO" ]] || fail "gh resolved $remote_repo, expected $GITHUB_REPO"
fi

echo "== Relay release $tag =="
echo "-- router gates"
(
  cd "$repo_root/router"
  npm ci
  npm run clean
  npm run build
  npm test
  npm run coverage
)

echo "-- daemon gates"
(
  cd "$repo_root/daemon"
  bundle exec srb tc
  bundle exec rspec
)

staging_parent="$(mktemp -d)"
cleanup() {
  rm -rf "$staging_parent"
}
trap cleanup EXIT

daemon_paths=(
  daemon/Gemfile
  daemon/Gemfile.lock
  daemon/bin/daemon
  daemon/config.ru
  daemon/db/
  daemon/lib/
)
for path in "${daemon_paths[@]}"; do
  git -C "$repo_root" ls-files -- "$path" | grep -q . || fail "tracked daemon runtime path is missing: $path"
done
for path in router/package.json router/package-lock.json; do
  git -C "$repo_root" ls-files --error-unmatch "$path" >/dev/null || fail "tracked router package file is missing: $path"
done

package_root="$staging_parent/relay-server-$version"
git -C "$repo_root" archive --format=tar --prefix="relay-server-$version/" HEAD -- "${daemon_paths[@]}" \
  | tar -xf - -C "$staging_parent"

mkdir -p "$package_root/router"
cp -R "$repo_root/router/dist" "$package_root/router/dist"
cp "$repo_root/router/package.json" "$repo_root/router/package-lock.json" "$package_root/router/"
printf '%s\n' "$version" > "$package_root/VERSION"

if find "$package_root" \( -name ".env" -o -name ".env.*" -o -name "node_modules" -o -name "vendor" -o -name "coverage" -o -name "spec" \) -print -quit | grep -q .; then
  fail "release payload contains ignored or development files"
fi

mkdir -p "$output_dir"
tarball="$output_dir/relay-server-$version.tar.gz"
checksum_file="$tarball.sha256"
tar -czf "$tarball" -C "$staging_parent" "relay-server-$version"

if command -v shasum >/dev/null 2>&1; then
  checksum="$(shasum -a 256 "$tarball" | awk '{print $1}')"
else
  checksum="$(sha256sum "$tarball" | awk '{print $1}')"
fi
printf '%s  %s\n' "$checksum" "$(basename "$tarball")" > "$checksum_file"

render_formula() {
  local target="$1"
  local source_url="$2"

  ruby - "$formula_template" "$target" "$source_url" "$checksum" "$version" <<'RUBY'
template_path, target_path, source_url, checksum, version = ARGV
content = File.read(template_path)
{
  "__RELAY_SOURCE_URL__" => source_url,
  "0000000000000000000000000000000000000000000000000000000000000000" => checksum,
  "__RELAY_VERSION__" => version
}.each do |token, value|
  raise "missing formula token #{token}" unless content.include?(token)

  content = content.gsub(token, value)
end
raise "formula contains unrendered token" if content.match?(/__RELAY_[A-Z0-9_]+__/)

File.write(target_path, content)
RUBY
}

public_formula="$output_dir/relay.rb"
local_formula="$output_dir/relay-local.rb"
public_url="https://github.com/$GITHUB_REPO/releases/download/$tag/relay-server-$version.tar.gz"
local_url="file://$tarball"
render_formula "$public_formula" "$public_url"
render_formula "$local_formula" "$local_url"

echo "-- artifacts"
echo "tarball:        $tarball"
echo "sha256:         $checksum"
echo "checksum:       $checksum_file"
echo "public formula: $public_formula"
echo "local formula:  $local_formula"

if [[ "$dry_run" == "1" || "$dry_run" == "true" ]]; then
  echo "dry-run: skipped gh release create"
else
  gh release create --repo "$GITHUB_REPO" "$tag" "$tarball" "$checksum_file" \
    --title "Relay Server $tag" \
    --generate-notes
fi
