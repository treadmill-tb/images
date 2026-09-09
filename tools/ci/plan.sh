#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

die() {
	echo "plan: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: plan.sh --check | --matrix [<image-dir>...]
	USAGE
	exit 2
}

mode=""
dirs=()

while [ $# -gt 0 ]; do
	case "$1" in
	--check | --matrix)
		mode="${1#--}"
		shift
		;;
	-h | --help) usage ;;
	*)
		dirs+=("$1")
		shift
		;;
	esac
done

[ -n "$mode" ] || usage
if [ "${#dirs[@]}" -eq 0 ]; then
	for d in "$repo"/images/*/*/; do dirs+=("${d%/}"); done
fi

# Make sure we abort at some point to avoid infinite recursion and cyclic
# dependencies.
max_level=9

known_keys='["title","version","description","arch","type","base","grow","publish"]'

artifact_of() { # <dir>
	echo "$(basename "$(dirname "$1")")--$(basename "$1")"
}

runner_of() { # <arch>
	case "$1" in
	x86_64) echo ubuntu-latest ;;
	aarch64) echo ubuntu-24.04-arm ;;
	*) die "no CI runner for arch: $1" ;;
	esac
}

base_of() { # <dir>
	jq -er '.base // ""' "$1/image.json" || die "$1/image.json did not validate"
}

depth_of() { # <dir>
	local dir="$1" n=0 base
	while :; do
		base="$(base_of "$dir")"
		case "$base" in
		./* | ../*) dir="$(cd "$dir/$base" && pwd)" ;;
		*) break ;;
		esac
		n=$((n + 1))
		[ "$n" -le 16 ] || die "base chain too deep or cyclic at $1"
	done
	echo "$n"
}

entries=()
for dir in "${dirs[@]}"; do
	dir="$(cd "$dir" 2>/dev/null && pwd)" || die "no such image directory: $dir"
	[ -f "$dir/image.json" ] || die "$dir: no image.json"
	jq -e --argjson known "$known_keys" '
		(keys - $known) as $extra
		| if ($extra | length) > 0 then error("unknown keys: \($extra | join(", "))") else . end
		| if (.title | type) != "string" then error("missing title") else . end
		| if (.arch | IN("x86_64", "aarch64")) then . else error("bad arch") end
		| if (.type | IN("disk", "sd")) then . else error("bad type") end
		| if (.publish | type | IN("string", "null")) then . else error("bad publish") end
	' "$dir/image.json" >/dev/null || die "$dir/image.json is not valid"
	[ -f "$dir/provision.sh" ] || die "$dir: no provision.sh"

	base="$(base_of "$dir")"
	lower_artifact=""
	lower_ref=""
	case "$base" in
	./* | ../*)
		parent="$(cd "$dir/$base" 2>/dev/null && pwd)" ||
			die "$dir/image.json: no such base: $base"
		[ -f "$parent/image.json" ] || die "$dir/image.json: base $base is not an image"
		lower_artifact="$(artifact_of "$parent")"
		;;
	'')
		jq -e '.vendor_image | .url and .sha256' "$dir/inputs.json" >/dev/null 2>&1 ||
			die "$dir has no base, so its inputs.json needs vendor_image"
		;;
	*) lower_ref="$base" ;;
	esac

	level="$(depth_of "$dir")"
	[ "$level" -le "$max_level" ] ||
		die "$dir sits $level deep, past the $max_level levels CI can build"

	arch="$(jq -r '.arch' "$dir/image.json")"
	publish="$(jq -r --arg default "$(basename "$(dirname "$dir")")-$(basename "$dir")" \
		'if has("publish") then .publish else $default end' "$dir/image.json")"

	entries+=("$(jq -nc \
		--arg image "${dir#"$repo"/}" \
		--arg artifact "$(artifact_of "$dir")" \
		--arg lower_artifact "$lower_artifact" \
		--arg lower_ref "$lower_ref" \
		--arg runner "$(runner_of "$arch")" \
		--arg arch "$arch" \
		--arg publish "$publish" \
		--argjson level "$level" \
		'{$image, $artifact, $lower_artifact, $lower_ref, $runner, $arch, $publish, $level}')")
done

if [ "$mode" = check ]; then
	echo "plan: ${#entries[@]} images OK" >&2
	exit 0
fi

printf '%s\n' "${entries[@]}" | jq -sc --argjson max "$max_level" '
	. as $e
	| reduce range(0; $max + 1) as $l ({};
		.["level_\($l)"] = {include: [$e[] | select(.level == $l)]})
'
