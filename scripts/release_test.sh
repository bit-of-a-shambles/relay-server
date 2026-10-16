#!/usr/bin/env bash
# Offline packaging contract. Component gates run independently; these shims
# isolate archive selection from package registries, compilers and real agents.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-packaging.XXXXXX")"
fixture="$test_root/source"
mkdir -p "$fixture"/{scripts,packaging/homebrew,daemon/bin,daemon/db,daemon/lib,router/dist} "$test_root/shims" "$test_root/unpacked"
cp "$repo_root/scripts/release.sh" "$fixture/scripts/"
cp "$repo_root/packaging/homebrew/relay.rb" "$fixture/packaging/homebrew/"
for executable in daemon harness_bridge permission_hook; do
  cp "$repo_root/daemon/bin/$executable" "$fixture/daemon/bin/"
done
printf 'source "https://rubygems.org"\n' > "$fixture/daemon/Gemfile"
printf 'fixture\n' > "$fixture/daemon/Gemfile.lock"
printf 'run ->(_) { [200, {}, []] }\n' > "$fixture/daemon/config.ru"
printf 'SELECT 1;\n' > "$fixture/daemon/db/001_fixture.sql"
printf 'module RelayFixture; end\n' > "$fixture/daemon/lib/fixture.rb"
printf '{"name":"relay-packaging-fixture","version":"0.0.0"}\n' > "$fixture/router/package.json"
cp "$fixture/router/package.json" "$fixture/router/package-lock.json"
printf 'console.log("packaging fixture");\n' > "$fixture/router/dist/index.js"
printf '.env*\nrouter/dist/\n' > "$fixture/.gitignore"
for command_name in npm bundle; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/shims/$command_name"
  chmod +x "$test_root/shims/$command_name"
done
git -C "$fixture" init -q
git -C "$fixture" add .
git -C "$fixture" -c user.name='Relay Packaging Test' -c user.email='test@relay.invalid' commit -qm fixture
printf 'must not ship\n' > "$fixture/daemon/.env.release-ignored-sentinel"
git -C "$fixture" check-ignore -q daemon/.env.release-ignored-sentinel
PATH="$test_root/shims:$PATH" bash "$fixture/scripts/release.sh" --dry-run --output-dir "$test_root/output" v0.1.0 > "$test_root/release.log"
tarball="$test_root/output/relay-server-0.1.0.tar.gz"
tar -tzf "$tarball" > "$test_root/contents.txt"
if grep -E '(^|/)(\.env[^/]*|node_modules|vendor|coverage|spec)(/|$)' "$test_root/contents.txt" >/dev/null; then
  echo "error: ignored or development payload found in release" >&2
  exit 1
fi
tar -xzf "$tarball" -C "$test_root/unpacked"
for executable in daemon harness_bridge permission_hook; do
  test -r "$test_root/unpacked/relay-server-0.1.0/daemon/bin/$executable" || {
    echo "error: runtime entry point missing or unreadable: $executable" >&2
    exit 1
  }
  ruby -c "$test_root/unpacked/relay-server-0.1.0/daemon/bin/$executable" >/dev/null
done
test -x "$test_root/unpacked/relay-server-0.1.0/daemon/bin/daemon"
test -x "$test_root/unpacked/relay-server-0.1.0/daemon/bin/permission_hook"
test -f "$test_root/unpacked/relay-server-0.1.0/router/dist/index.js"
test "$(cat "$test_root/unpacked/relay-server-0.1.0/VERSION")" = '0.1.0'
(cd "$test_root/output" && shasum -a 256 -c relay-server-0.1.0.tar.gz.sha256)
if grep -E '__RELAY_[A-Z0-9_]+__' "$test_root/output/relay.rb" >/dev/null; then
  echo 'error: formula contains an unrendered token' >&2
  exit 1
fi
echo "release packaging passed: helper executables included, ignored files excluded, checksum valid"
