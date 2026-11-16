#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

die() {
	echo "build-chain: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: build-chain.sh --image <coord> -o <out-layout>
		                      [--cache <dir>] [--rebuild]
		                      [--payload <path>]... [--image-util <path>]

		Follow the stack of <coord> down to the host kind's root image. Then
		build every link that is not already in the cache, and leave the head
		layout at -o.
	USAGE
	exit 2
}

coord=""
out=""
cache=""
rebuild=no
passthrough=()

while [ $# -gt 0 ]; do
	case "$1" in
	--image)
		coord="$2"
		shift 2
		;;
	-o | --out)
		out="$2"
		shift 2
		;;
	--cache)
		cache="$2"
		shift 2
		;;
	--rebuild)
		rebuild=yes
		shift
		;;
	--payload | --image-util | --work)
		passthrough+=("$1" "$2")
		shift 2
		;;
	--insecure-lower-ref)
		passthrough+=("$1")
		shift
		;;
	-h | --help) usage ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$coord" ] || die "missing --image <coord>"
[ -n "$out" ] || die "missing -o <out-layout>"

images="$repo/tools/images.sh"

chain=()
lower_ref=""
link="$coord"
while :; do
	info="$("$images" meta "$link")" || die "no such image: $link"
	chain=("$info" ${chain[@]+"${chain[@]}"})
	[ "${#chain[@]}" -le 16 ] || die "stack too deep or cyclic at $coord"
	lower_ref="$(jq -r '.lower_ref' <<<"$info")"
	link="$(jq -r '.lower' <<<"$info")"
	[ -n "$link" ] || break
done

cache="${cache:-${TML_IMAGE_CACHE:-.image-cache}}"
mkdir -p "$cache"

work="$(mktemp -d "${TMPDIR:-/tmp}/tml-chain-XXXXXX")"
trap 'rm -rf "$work"' EXIT

lower=""
for info in "${chain[@]}"; do
	link="$(jq -r '.coord' <<<"$info")"
	layout="$cache/$(jq -r '.artifact' <<<"$info")"

	if [ "$rebuild" = no ] && [ -f "$layout/index.json" ]; then
		echo "build-chain: reusing $layout" >&2
	else
		rm -rf "$layout"
		"$images" resolve "$link" --out "$work/image"
		args=(--image "$work/image" -o "$layout")
		if [ -n "$lower" ]; then
			args+=(--lower "$lower")
		elif [ -n "$lower_ref" ]; then
			args+=(--lower-ref "$lower_ref")
		fi
		"$here/build-image.sh" "${args[@]}" ${passthrough[@]+"${passthrough[@]}"}
	fi
	lower="$layout"
done

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -a "$lower" "$out"
echo "build-chain: $coord -> $out (OK)" >&2
