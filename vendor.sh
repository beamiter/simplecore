#!/usr/bin/env bash
# Vendor the simplecore bundle into every simple* plugin beside this directory.
#
#   ./vendor.sh              vendor into every sibling simple* plugin
#   ./vendor.sh simplegit    vendor into the named plugins only
#   ./vendor.sh --check      report drift, write nothing, exit 1 if any
#
# Set SIMPLECORE_SUITE when the plugins are not checked out beside this
# directory.
#
# Most bundle members are whole files.  Makefile.footer is not: it is the tail
# of a file the plugin also owns, vendored in `footer` mode, which replaces
# that tail and leaves everything above it alone.
#
# Each plugin is its own git repository and must stay independently
# installable, so the bundle is copied in rather than shared by reference.
# The copies are then pinned by a per-plugin .simplecore.manifest, which
# `make core-verify` checks on every build — that is what makes the drift
# visible instead of silent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The plugins are normally checked out beside this directory.  They need not be:
# this is its own repository and can be cloned anywhere, so SIMPLECORE_SUITE
# names the directory holding the plugins when it is not the parent.
suite="${SIMPLECORE_SUITE:-$(dirname "$here")}"
if [ ! -d "$suite" ]; then
	echo "vendor.sh: no such directory: $suite" >&2
	echo "       Set SIMPLECORE_SUITE to the directory holding the simple* plugins." >&2
	exit 1
fi
suite="$(cd "$suite" && pwd -P)"

check_only=0
targets=()
for arg in "$@"; do
	case "$arg" in
	--check) check_only=1 ;;
	-*) echo "vendor.sh: unknown option $arg" >&2; exit 2 ;;
	*)
		if [[ ! "$arg" =~ ^simple[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			echo "vendor.sh: invalid plugin name: $arg" >&2
			exit 2
		fi
		targets+=("$arg")
		;;
	esac
done

# With no arguments, discover the suite.  A bare simple* glob is not enough:
# the plugin directory also holds work in progress that has no daemon and no
# repository of its own, and vendoring a supervisor into it would conjure four
# files nobody asked for.  Membership is therefore "is a git repository that
# already carries the bundle" — explicit names still work for onboarding a new
# plugin.
if [ ${#targets[@]} -eq 0 ]; then
	for d in "$suite"/simple*/; do
		[ -d "$d/.git" ] || continue
		[ -f "$d/.simplecore.manifest" ] || continue
		targets+=("$(basename "$d")")
	done
	[ ${#targets[@]} -gt 0 ] || { echo "vendor.sh: no vendored plugins found beside $here" >&2; exit 1; }
fi

# Discovery is still untrusted filesystem input. Apply the same basename
# contract as explicit arguments before a name reaches awk, sed, or a path.
for plug in "${targets[@]}"; do
	if [[ ! "$plug" =~ ^simple[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		echo "vendor.sh: invalid discovered plugin name: $plug" >&2
		exit 2
	fi
done

version="$(awk '$1 == "VERSION" { print $2 }' "$here/MANIFEST")"
[ -n "$version" ] || { echo "vendor.sh: MANIFEST has no VERSION" >&2; exit 1; }

# Emit "<src> <dst> <mode>" for each record that applies to this plugin, with
# @PLUGIN@ already resolved and any SKIP entries for it filtered out.
records() {
	local plug=$1
	awk -v plug="$plug" '
		/^[[:space:]]*(#|$)/ { next }
		$1 == "VERSION" { next }
		$1 == "SKIP" { if ($2 == plug) skip[$3] = 1; next }
		{ rec[NR] = $1 " " $2 " " $3 }
		END {
			for (n = 1; n <= NR; n++) {
				if (!(n in rec)) continue
				split(rec[n], f, " ")
				if (f[1] in skip) continue
				gsub(/@PLUGIN@/, plug, f[2])
				print f[1], f[2], f[3]
			}
		}
	' "$here/MANIFEST"
}

safe_relative_path() {
	case "$1" in
	"" | /* | .. | ../* | */.. | */../*) return 1 ;;
	*) return 0 ;;
	esac
}

destination_parent_is_safe() {
	local relative=$1
	local parent component current
	local -a components

	parent="$(dirname "$relative")"
	current="$root"
	IFS='/' read -r -a components <<<"$parent"
	for component in "${components[@]}"; do
		[ "$component" = . ] && continue
		current="$current/$component"
		if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
			return 1
		fi
	done
	return 0
}

validate_record() {
	local src=$1 dst=$2 mode=$3

	if ! safe_relative_path "$src" || ! safe_relative_path "$dst"; then
		echo "vendor.sh: unsafe MANIFEST path: $src -> $dst" >&2
		return 1
	fi
	case "$mode" in
	copy | template | footer) ;;
	*)
		echo "vendor.sh: unknown mode '$mode' for $src" >&2
		return 1
		;;
	esac
	if [ ! -f "$here/$src" ] || [ -L "$here/$src" ]; then
		echo "vendor.sh: source must be a regular in-repository file: $src" >&2
		return 1
	fi
	if [ -L "$root/$dst" ] || { [ -e "$root/$dst" ] && [ ! -f "$root/$dst" ]; }; then
		echo "vendor.sh: destination must be a regular file or absent in plugin $plug: $dst" >&2
		return 1
	fi
	if ! destination_parent_is_safe "$dst"; then
		echo "vendor.sh: unsafe destination parent in plugin $plug: $dst" >&2
		return 1
	fi
}

# A `footer` record is a fragment rather than a file: it owns the tail of a
# file the plugin also owns, so it is spliced in instead of copied over.  The
# banner below is the seam — everything above it belongs to the plugin and is
# never touched, everything from it down belongs to the bundle.
footer_banner='# simplecore: the vendored daemon supervisor shared by the simple* suite.'

# Print the part of $1 the bundle owns: the banner, the rule line immediately
# above it, and everything after.  Prints nothing when there is no banner,
# which is how a first vendoring into a plugin is recognised.
footer_owned() {
	[ -f "$1" ] || return 0
	awk -v banner="$footer_banner" '
		{ line[NR] = $0 }
		index($0, banner) == 1 { at = NR }
		END {
			if (!at) exit
			if (at > 1 && line[at - 1] ~ /^# -+$/) at--
			for (n = at; n <= NR; n++) print line[n]
		}
	' "$1"
}

# Print the part of $1 the plugin owns, with the blank lines that separated the
# two trimmed off — the splice re-adds exactly one, so re-vendoring an
# unchanged footer is a no-op rather than a slow accumulation of blank lines.
footer_head() {
	[ -f "$1" ] || return 0
	awk -v banner="$footer_banner" '
		{ line[NR] = $0 }
		index($0, banner) == 1 { at = NR }
		END {
			stop = at ? at : NR + 1
			if (at && at > 1 && line[at - 1] ~ /^# -+$/) stop--
			for (n = 1; n < stop; n++) if (line[n] ~ /[^[:space:]]/) last = n
			for (n = 1; n <= last; n++) print line[n]
		}
	' "$1"
}

# Render a source file as it should appear inside the given plugin.
render() {
	local src=$1 mode=$2 plug=$3
	case "$mode" in
	copy) cat "$here/$src" ;;
	template | footer) sed "s/@PLUGIN@/$plug/g" "$here/$src" ;;
	*) echo "vendor.sh: unknown mode '$mode' for $src" >&2; exit 1 ;;
	esac
}

drift=0
for plug in "${targets[@]}"; do
	root="$suite/$plug"
	if [ -L "$root" ]; then
		echo "vendor.sh: plugin root must not be a symbolic link: $plug" >&2
		exit 1
	fi
	[ -d "$root" ] || { echo "vendor.sh: no such plugin: $plug" >&2; exit 1; }
	physical_root="$(cd "$root" && pwd -P)"
	case "$physical_root" in
	"$suite"/*) ;;
	*)
		echo "vendor.sh: plugin resolves outside the suite: $plug" >&2
		exit 1
		;;
	esac

	manifest="$root/.simplecore.manifest"
	if [ -L "$manifest" ] || { [ -e "$manifest" ] && [ ! -f "$manifest" ]; }; then
		echo "vendor.sh: manifest must be a regular file or absent in plugin $plug" >&2
		exit 1
	fi

	# Validate the entire plan before creating a manifest or touching the first
	# destination.  A bad later record must not leave an earlier file upgraded
	# and the plugin in a half-vendored state.
	while read -r src dst mode; do
		[ -n "$src" ] || continue
		validate_record "$src" "$dst" "$mode" || exit 1
	done < <(records "$plug")

	tmp_manifest="$(mktemp "$root/.simplecore.manifest.XXXXXX")"
	trap 'rm -f "$tmp_manifest"' EXIT
	{
		echo "# Generated by .simplecore/vendor.sh — do not edit."
		echo "# Verified by \`make core-verify\`; regenerate after changing the bundle."
		echo "version $version"
	} >"$tmp_manifest"

	changed=()
	while read -r src dst mode; do
		[ -n "$src" ] || continue
		# Repeat the preflight immediately before use to narrow filesystem races.
		validate_record "$src" "$dst" "$mode" || exit 1
		tmp="$(mktemp)"
		render "$src" "$mode" "$plug" >"$tmp"
		sum="$(sha256sum <"$tmp" | cut -d' ' -f1)"

		if [ "$mode" = footer ]; then
			# `sha256sum -c` cannot check a fragment, so the record names the
			# number of trailing lines it covers and core-verify hashes those.
			printf 'footer %s %s  %s\n' "$(wc -l <"$tmp" | tr -d ' ')" \
				"$sum" "$dst" >>"$tmp_manifest"
			owned="$(mktemp)"
			footer_owned "$root/$dst" >"$owned"
			if ! cmp -s "$tmp" "$owned"; then
				changed+=("$dst")
				if [ "$check_only" -eq 0 ]; then
					destination="$root/$dst"
					destination_directory="$(dirname "$destination")"
					mkdir -p "$destination_directory"
					physical_destination_directory="$(cd "$destination_directory" && pwd -P)"
					case "$physical_destination_directory" in
					"$physical_root" | "$physical_root"/*) ;;
					*)
						echo "vendor.sh: destination resolves outside plugin $plug: $dst" >&2
						exit 1
						;;
					esac
					head="$(mktemp)"
					footer_head "$destination" >"$head"
					tmp_destination="$(mktemp "$destination_directory/.simplecore.XXXXXX")"
					{
						if [ -s "$head" ]; then
							cat "$head"
							echo
						fi
						cat "$tmp"
					} >"$tmp_destination"
					chmod 0644 "$tmp_destination"
					mv -f "$tmp_destination" "$destination"
					rm -f "$head"
				fi
			fi
			rm -f "$owned" "$tmp"
			continue
		fi

		echo "$sum  $dst" >>"$tmp_manifest"

		if [ ! -f "$root/$dst" ] || ! cmp -s "$tmp" "$root/$dst"; then
			changed+=("$dst")
			if [ "$check_only" -eq 0 ]; then
				destination="$root/$dst"
				destination_directory="$(dirname "$destination")"
				mkdir -p "$destination_directory"
				physical_destination_directory="$(cd "$destination_directory" && pwd -P)"
				case "$physical_destination_directory" in
				"$physical_root" | "$physical_root"/*) ;;
				*)
					echo "vendor.sh: destination resolves outside plugin $plug: $dst" >&2
					exit 1
					;;
				esac
				tmp_destination="$(mktemp "$destination_directory/.simplecore.XXXXXX")"
				cat "$tmp" >"$tmp_destination"
				if [ -x "$here/$src" ]; then
					chmod 0755 "$tmp_destination"
				else
					chmod 0644 "$tmp_destination"
				fi
				mv -f "$tmp_destination" "$destination"
			fi
		fi
		rm -f "$tmp"
	done < <(records "$plug")

	if [ "$check_only" -eq 1 ]; then
		if [ ${#changed[@]} -ne 0 ] || ! cmp -s "$tmp_manifest" "$manifest"; then
			drift=1
			echo "drift: $plug"
			for f in "${changed[@]}"; do echo "    $f"; done
			cmp -s "$tmp_manifest" "$manifest" || echo "    .simplecore.manifest"
		fi
		rm -f "$tmp_manifest"
	else
		mv "$tmp_manifest" "$manifest"
		if [ ${#changed[@]} -eq 0 ]; then
			echo "$plug: up to date (bundle v$version)"
		else
			echo "$plug: updated ${#changed[@]} file(s) to bundle v$version"
			for f in "${changed[@]}"; do echo "    $f"; done
		fi
	fi
	trap - EXIT
done

exit "$drift"
