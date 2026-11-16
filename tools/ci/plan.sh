#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

# The schema check runs in a sandbox without /usr/bin/env, so name the
# interpreter rather than taking it from the shebang.
images() {
	bash "$repo/tools/images.sh" "$@"
}

die() {
	echo "plan: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: plan.sh --check | --matrix [<coord>...]
	USAGE
	exit 2
}

mode=""
coords=()

while [ $# -gt 0 ]; do
	case "$1" in
	--check | --matrix)
		mode="${1#--}"
		shift
		;;
	-h | --help) usage ;;
	*)
		coords+=("$1")
		shift
		;;
	esac
done

[ -n "$mode" ] || usage
if [ "${#coords[@]}" -eq 0 ]; then
	mapfile -t coords < <(images list)
fi

# The level ladder in images.yml is finite, and Actions cannot template it.
max_level=9

runner_of() { # <arch>
	case "$1" in
	x86_64) echo ubuntu-26.04 ;;
	aarch64) echo ubuntu-26.04-arm ;;
	*) die "no CI runner for arch: $1" ;;
	esac
}

artifact_of() { # <coord>
	images meta "$1" | jq -r '.artifact'
}

entries=()
for coord in "${coords[@]}"; do
	info="$(images meta "$coord")" || die "no such image: $coord"

	level="$(jq -r '.level' <<<"$info")"
	[ "$level" -le "$max_level" ] ||
		die "$coord sits $level deep, past the $max_level levels CI can build"

	lower="$(jq -r '.lower' <<<"$info")"
	lower_artifact=""
	[ -z "$lower" ] || lower_artifact="$(artifact_of "$lower")"

	entries+=("$(jq -c \
		--arg runner "$(runner_of "$(jq -r '.arch' <<<"$info")")" \
		--arg lower_artifact "$lower_artifact" \
		'{image: .coord, artifact, $lower_artifact, lower_ref, $runner, arch, publish, level}' \
		<<<"$info")")
done

if [ "$mode" = check ]; then
	images check

	# publish.json: every set member must be an image we push to ghcr.io.
	publish_json="$repo/publish.json"
	jq -e '
		(.switchboard | type) == "string" and (.registry | type) == "string"
		and (.sets | type) == "object"
		and all(.sets[]; type == "array" and length > 0 and all(.[];
			(.image | type) == "string"
			and (.platform_profile | type) == "string" and .platform_profile != ""
			and (.predicate | type | IN("string", "null"))))
	' "$publish_json" >/dev/null || die "publish.json is not valid"
	while read -r coord; do
		info="$(images meta "$coord")" || die "publish.json: $coord is not an image"
		[ -n "$(jq -r '.publish' <<<"$info")" ] ||
			die "publish.json: $coord is not published to ghcr.io"
	done < <(jq -r '[.sets[][].image] | unique[]' "$publish_json")

	echo "plan: ${#entries[@]} images OK" >&2
	exit 0
fi

printf '%s\n' "${entries[@]}" | jq -sc --argjson max "$max_level" '
	. as $e
	| reduce range(0; $max + 1) as $l ({};
		.["level_\($l)"] = {include: [$e[] | select(.level == $l)]})
'
