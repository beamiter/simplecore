#!/usr/bin/env bash
# The installer is deliberately sourced from the runtime-resolved repository
# root; this harness validates that exact source boundary.
# shellcheck disable=SC1091
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

mock_bin="$fixture/mock bin"
plugin_root="$fixture/plugin root"
mkdir -p "$mock_bin" "$plugin_root/lib"

cat >"$mock_bin/rustc" <<'MOCK_RUSTC'
#!/usr/bin/env bash
case "${1:-}" in
--version) printf '%s\n' 'rustc 1.88.0 (mock)' ;;
-vV) printf '%s\n' 'rustc 1.88.0 (mock)' 'host: x86_64-unknown-linux-gnu' ;;
*) exit 2 ;;
esac
MOCK_RUSTC

cat >"$mock_bin/cargo" <<'MOCK_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$MOCK_CARGO_ARGS"
target=''
target_dir=''
while [ "$#" -gt 0 ]; do
	case "$1" in
	--target) target=$2; shift 2 ;;
	--target-dir) target_dir=$2; shift 2 ;;
	*) shift ;;
	esac
done
[ -n "$target" ] && [ -n "$target_dir" ]
output="$target_dir/$target/release/$SIMPLECORE_BINARY"
mkdir -p "$(dirname "$output")"
cat >"$output" <<'MOCK_BINARY'
#!/usr/bin/env bash
case "${1:-}" in
--self-test) [ "${MOCK_SELF_TEST_FAIL:-0}" -eq 0 ] ;;
--version) printf '%s\n' 'simpleprobe 4.0.0' ;;
*) exit 2 ;;
esac
MOCK_BINARY
chmod 0755 "$output"
MOCK_CARGO
chmod 0755 "$mock_bin/rustc" "$mock_bin/cargo"

old_binary="$plugin_root/lib/simpleprobe-daemon"
cat >"$old_binary" <<'OLD_BINARY'
#!/usr/bin/env bash
printf '%s\n' old
OLD_BINARY
chmod 0755 "$old_binary"

export PATH="$mock_bin:$PATH"
export MOCK_CARGO_ARGS="$fixture/cargo-args"
export SIMPLECORE_BINARY=simpleprobe-daemon
export SIMPLECORE_DISPLAY=SimpleProbe
export SIMPLECORE_MIN_RUST_MINOR=88
export SIMPLECORE_ROOT="$plugin_root"
export SIMPLECORE_VERIFY=self-test

export MOCK_SELF_TEST_FAIL=1
if (source "$root/install-common.sh"); then
	echo "test_install_common.sh: failed self-test was accepted" >&2
	exit 1
fi
[ "$("$old_binary")" = old ]

export MOCK_SELF_TEST_FAIL=0
caller_trap_marker="$fixture/caller-trap-ran"
(
	trap 'printf "%s\n" preserved >"$caller_trap_marker"' EXIT
	source "$root/install-common.sh"
)
[ "$(cat "$caller_trap_marker")" = preserved ]
[ "$("$old_binary" --version)" = 'simpleprobe 4.0.0' ]
[ "$(stat -c '%a' "$old_binary")" = 755 ]

grep -Fx -- '--release' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- '--locked' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- '--bin' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- 'simpleprobe-daemon' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- '--target' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- 'x86_64-unknown-linux-gnu' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- '--target-dir' "$MOCK_CARGO_ARGS" >/dev/null
grep -Fx -- "$plugin_root/target" "$MOCK_CARGO_ARGS" >/dev/null

export SIMPLECORE_BINARY=../escape
if (source "$root/install-common.sh"); then
	echo "test_install_common.sh: path-like binary name was accepted" >&2
	exit 1
fi

export SIMPLECORE_BINARY=simpleprobe-daemon
mv "$old_binary" "$plugin_root/lib/simpleprobe-daemon.saved"
outside_destination="$fixture/outside destination"
mkdir "$outside_destination"
ln -s "$outside_destination" "$old_binary"
if (source "$root/install-common.sh"); then
	echo "test_install_common.sh: symlinked binary destination was accepted" >&2
	exit 1
fi
test -L "$old_binary"
test -z "$(find "$outside_destination" -mindepth 1 -print -quit)"
rm "$old_binary"
mv "$plugin_root/lib/simpleprobe-daemon.saved" "$old_binary"

mv "$old_binary" "$plugin_root/lib/simpleprobe-daemon.saved"
mkdir "$old_binary"
if (source "$root/install-common.sh"); then
	echo "test_install_common.sh: directory-valued binary destination was accepted" >&2
	exit 1
fi
test -z "$(find "$old_binary" -mindepth 1 -print -quit)"
rmdir "$old_binary"
mv "$plugin_root/lib/simpleprobe-daemon.saved" "$old_binary"

mv "$plugin_root/lib" "$plugin_root/real-lib"
ln -s "$fixture" "$plugin_root/lib"
if (source "$root/install-common.sh"); then
	echo "test_install_common.sh: symlinked install directory was accepted" >&2
	exit 1
fi
test ! -e "$fixture/simpleprobe-daemon"
