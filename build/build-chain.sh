#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
	echo "build-chain: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: build-chain.sh --image <dir> -o <out-layout>
		                      [--cache <dir>] [--rebuild]
		                      [--payload <path>]... [--image-util <path>]

		Follow "base" down to an image that takes no lower layer. Then build
		every link that is not already in the cache, and leave the head layout
		at -o.
	USAGE
	exit 2
}

image_dir=""
out=""
cache=""
rebuild=no
passthrough=()

while [ $# -gt 0 ]; do
	case "$1" in
	--image)
		image_dir="$2"
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

[ -n "$image_dir" ] || die "missing --image <dir>"
[ -n "$out" ] || die "missing -o <out-layout>"
[ -d "$image_dir" ] || die "no such image directory: $image_dir"

chain=()
lower_ref=""
dir="$(cd "$image_dir" && pwd)"
while :; do
	chain=("$dir" ${chain[@]+"${chain[@]}"})
	[ "${#chain[@]}" -le 16 ] || die "base chain too deep or cyclic at $image_dir"
	base="$(jq -er '.base // ""' "$dir/image.json")" ||
		die "$dir/image.json did not validate"
	case "$base" in
	./* | ../*)
		dir="$(cd "$dir/$base" 2>/dev/null && pwd)" ||
			die "$dir/image.json: no such base: $base"
		;;
	'') break ;;
	*)
		lower_ref="$base"
		break
		;;
	esac
done

cache="${cache:-${TML_IMAGE_CACHE:-.image-cache}}"
mkdir -p "$cache"

lower=""
for dir in "${chain[@]}"; do
	layout="$cache/$(basename "$(dirname "$dir")")--$(basename "$dir")"

	if [ "$rebuild" = no ] && [ -f "$layout/index.json" ]; then
		echo "build-chain: reusing $layout" >&2
	else
		rm -rf "$layout"
		args=(--image "$dir" -o "$layout")
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
echo "build-chain: $image_dir -> $out (OK)" >&2
