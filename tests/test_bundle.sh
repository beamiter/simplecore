#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
outside="$(mktemp -d)"
trap 'rm -rf -- "$fixture" "$outside"' EXIT

for command in bash make python3 sha256sum shellcheck vim; do
	command -v "$command" >/dev/null || {
		echo "test_bundle.sh: required command is missing: $command" >&2
		exit 1
	}
done

bash -n \
	"$root/vendor.sh" \
	"$root/install-common.sh" \
	"$root/tests/test_bundle.sh" \
	"$root/tests/test_install_common.sh"
shellcheck \
	"$root/vendor.sh" \
	"$root/install-common.sh" \
	"$root/tests/test_bundle.sh" \
	"$root/tests/test_install_common.sh"
PYTHONPYCACHEPREFIX="$fixture/pycache" \
	python3 -m py_compile "$root/tests/fake_daemon.py"

mkdir "$fixture/simpleprobe"
printf 'plugin-owned:\n\t@:\n' >"$fixture/simpleprobe/Makefile"
SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe
SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" --check simpleprobe
grep -Fx 'plugin-owned:' "$fixture/simpleprobe/Makefile" >/dev/null
make -s -C "$fixture/simpleprobe" core-verify

# A truncated manifest must not turn the integrity gate into a no-op. Missing
# version/footer records and unknown record types used to verify successfully.
cp "$fixture/simpleprobe/.simplecore.manifest" "$fixture/manifest.good"
for mutation in empty version footer unknown; do
	case "$mutation" in
		empty) : >"$fixture/simpleprobe/.simplecore.manifest" ;;
		version) sed '/^version /d' "$fixture/manifest.good" >"$fixture/simpleprobe/.simplecore.manifest" ;;
		footer) sed '/^footer /d' "$fixture/manifest.good" >"$fixture/simpleprobe/.simplecore.manifest" ;;
		unknown) cp "$fixture/manifest.good" "$fixture/simpleprobe/.simplecore.manifest"
			printf 'unrecognized record\n' >>"$fixture/simpleprobe/.simplecore.manifest" ;;
	esac
	if make -s -C "$fixture/simpleprobe" core-verify; then
		echo "test_bundle.sh: accepted $mutation manifest" >&2
		exit 1
	fi
done
cp "$fixture/manifest.good" "$fixture/simpleprobe/.simplecore.manifest"

mkdir -p "$fixture/simplebad&name/.git"
touch "$fixture/simplebad&name/.simplecore.manifest"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" --check; then
	echo "test_bundle.sh: an unsafe discovered plugin name was accepted" >&2
	exit 1
fi

printf '\n# intentional footer drift\n' >>"$fixture/simpleprobe/Makefile"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" --check simpleprobe; then
	echo "test_bundle.sh: footer drift was accepted" >&2
	exit 1
fi
SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe
grep -Fx 'plugin-owned:' "$fixture/simpleprobe/Makefile" >/dev/null
make -s -C "$fixture/simpleprobe" core-verify

if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" ../outside; then
	echo "test_bundle.sh: path traversal was accepted as a plugin name" >&2
	exit 1
fi
ln -s "$outside" "$fixture/simpleescape"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleescape; then
	echo "test_bundle.sh: a plugin symlink escaped the suite" >&2
	exit 1
fi
test ! -e "$outside/.simplecore.manifest"

mkdir "$fixture/simplevictim"
printf '%s\n' untouched >"$fixture/simplevictim/marker"
ln -s simplevictim "$fixture/simplealias"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simplealias; then
	echo "test_bundle.sh: a plugin root symlink inside the suite was accepted" >&2
	exit 1
fi
test ! -e "$fixture/simplevictim/.simplecore.manifest"
test ! -e "$fixture/simplevictim/autoload"
[ "$(cat "$fixture/simplevictim/marker")" = untouched ]

mv "$fixture/simpleprobe/autoload" "$fixture/simpleprobe/autoload.saved"
ln -s "$outside" "$fixture/simpleprobe/autoload"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe; then
	echo "test_bundle.sh: a nested symlink escaped the plugin" >&2
	exit 1
fi
test ! -e "$outside/simpleprobe/core.vim"
rm "$fixture/simpleprobe/autoload"
mv "$fixture/simpleprobe/autoload.saved" "$fixture/simpleprobe/autoload"

printf '%s\n' 'outside-private-marker' >"$outside/private"
mv "$fixture/simpleprobe/Makefile" "$fixture/simpleprobe/Makefile.saved"
ln -s "$outside/private" "$fixture/simpleprobe/Makefile"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe; then
	echo "test_bundle.sh: a final destination symlink was accepted" >&2
	exit 1
fi
test -L "$fixture/simpleprobe/Makefile"
[ "$(cat "$outside/private")" = outside-private-marker ]
rm "$fixture/simpleprobe/Makefile"
mv "$fixture/simpleprobe/Makefile.saved" "$fixture/simpleprobe/Makefile"

# Preflight the whole plan: a bad later target must be rejected before an
# earlier drifted file is repaired, and mv must never treat that target as a
# directory into which it can hide a temporary file.
core_copy="$fixture/simpleprobe/autoload/simpleprobe/core.vim"
printf '%s\n' '" retain-until-preflight-finishes' >>"$core_copy"
mv "$fixture/simpleprobe/tests/fake_daemon.py" \
	"$fixture/simpleprobe/tests/fake_daemon.py.saved"
mkdir "$fixture/simpleprobe/tests/fake_daemon.py"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe; then
	echo "test_bundle.sh: a directory-valued destination was accepted" >&2
	exit 1
fi
grep -Fx '" retain-until-preflight-finishes' "$core_copy" >/dev/null
test -z "$(find "$fixture/simpleprobe/tests/fake_daemon.py" -mindepth 1 -print -quit)"
test -z "$(find "$fixture/simpleprobe" -maxdepth 1 -name '.simplecore.manifest.*' -print -quit)"
rmdir "$fixture/simpleprobe/tests/fake_daemon.py"
mv "$fixture/simpleprobe/tests/fake_daemon.py.saved" \
	"$fixture/simpleprobe/tests/fake_daemon.py"
SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe

mv "$fixture/simpleprobe/.simplecore.manifest" \
	"$fixture/simpleprobe/.simplecore.manifest.saved"
mkdir "$fixture/simpleprobe/.simplecore.manifest"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe; then
	echo "test_bundle.sh: a directory-valued generated manifest was accepted" >&2
	exit 1
fi
test -z "$(find "$fixture/simpleprobe/.simplecore.manifest" -mindepth 1 -print -quit)"
rmdir "$fixture/simpleprobe/.simplecore.manifest"
mv "$fixture/simpleprobe/.simplecore.manifest.saved" \
	"$fixture/simpleprobe/.simplecore.manifest"

(
	cd "$fixture/simpleprobe"
	grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
)

  vim -Nu NONE -n -i NONE -es \
	-S "$fixture/simpleprobe/tests/vim_core.vim"
SIMPLECORE_ROOT="$fixture/simpleprobe" \
	vim -Nu NONE -n -i NONE -es \
	-S "$fixture/simpleprobe/tests/defcompile.vim"

printf '\n" intentional drift\n' >> \
	"$fixture/simpleprobe/autoload/simpleprobe/core.vim"
if SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" --check simpleprobe; then
	echo "test_bundle.sh: drift check accepted a modified vendored file" >&2
	exit 1
fi

SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" simpleprobe
SIMPLECORE_SUITE="$fixture" "$root/vendor.sh" --check simpleprobe
