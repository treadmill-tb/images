#!/usr/bin/env bash
#
# The one reader of the host x layer model.
#
# A host kind (`images/<host>/`) is a root image: it fetches a vendor image and
# wires the guest up to the Treadmill API. A layer (`layers/<layer>/`) is a
# functional addition defined once and applied to every host kind. An image is
# addressed by a coordinate: `<host>` for the root, `<host>/<layer>` otherwise.
#
# `resolve` materializes a coordinate into the single-directory shape
# `build-image.sh` builds from, so nothing below this script knows about layers.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

die() {
	echo "images: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: images.sh list
		       images.sh meta <coord>
		       images.sh resolve <coord> --out <dir>
		       images.sh check

		Coordinates are <host> for a host kind's root image and <host>/<layer>
		for a layer applied to it.
	USAGE
	exit 2
}

# Deep enough for any stack worth building, shallow enough to catch a cycle.
max_depth=9

host_keys='["title","version","description","arch","type","grow","publish","include"]'
layer_keys='["base","title","description","publish","grow","include","hosts"]'

# -- the model ----------------------------------------------------------------

hosts() {
	local dir
	for dir in "$repo"/images/*/; do
		[ -f "$dir/image.json" ] || continue
		basename "$dir"
	done
}

layers() {
	local dir
	for dir in "$repo"/layers/*/; do
		[ -f "$dir/layer.json" ] || continue
		basename "$dir"
	done
}

host_dir() { # <host>
	[ -f "$repo/images/$1/image.json" ] || die "no such host kind: $1"
	echo "$repo/images/$1"
}

layer_dir() { # <layer>
	[ -f "$repo/layers/$1/layer.json" ] || die "no such layer: $1"
	echo "$repo/layers/$1"
}

node_get() { # <json-file> <filter>
	jq -er "$2" "$1" || die "$1 did not validate"
}

layer_get() { # <layer> <filter>
	node_get "$(layer_dir "$1")/layer.json" "$2"
}

# A base that names a layer stacks on it; anything else is a registry reference
# that `build-image.sh --lower-ref` pulls, and must look like one.
base_kind() { # <base>
	case "$1" in
	'') echo root ;;
	*)
		if [ -f "$repo/layers/$1/layer.json" ]; then
			echo layer
		elif [ "${1#*/}" != "$1" ]; then
			echo ref
		else
			die "base \"$1\" is neither a layer nor a registry reference"
		fi
		;;
	esac
}

layer_level() { # <layer>
	local layer="$1" n=1 base
	while :; do
		base="$(layer_get "$layer" '.base // ""')"
		[ "$(base_kind "$base")" = layer ] || break
		n=$((n + 1))
		[ "$n" -le "$max_depth" ] || die "layer stack too deep or cyclic at $1"
		layer="$base"
	done
	echo "$n"
}

# A layer applies to a host when it does not restrict itself to other hosts and
# the layer it stacks on applies too.
layer_applies() { # <layer> <host>
	local layer="$1" host="$2" n=0 base
	while :; do
		jq -e --arg h "$host" '(.hosts // null) == null or any(.hosts[]; . == $h)' \
			"$(layer_dir "$layer")/layer.json" >/dev/null || return 1
		base="$(layer_get "$layer" '.base // ""')"
		[ "$(base_kind "$base")" = layer ] || return 0
		n=$((n + 1))
		[ "$n" -le "$max_depth" ] || die "layer stack too deep or cyclic at $1"
		layer="$base"
	done
}

list() {
	local host layer level
	for host in $(hosts); do
		echo "$host"
		for layer in $(layers); do
			layer_applies "$layer" "$host" || continue
			level="$(layer_level "$layer")"
			echo "$level $host/$layer"
		done | sort -k1,1n -k2,2 | cut -d' ' -f2
	done
}

# -- metadata -----------------------------------------------------------------

render() { # <template> <host> <host-title> <host-description> <layer>
	local out="$1"
	out="${out//\{host\}/$2}"
	out="${out//\{host_title\}/$3}"
	out="${out//\{host_description\}/$4}"
	out="${out//\{layer\}/$5}"
	case "$out" in
	*'{'*'}'*) die "unknown placeholder in template: $1" ;;
	esac
	printf '%s' "$out"
}

host_description() { # <host>
	local dir="$1" text
	if [ -f "$dir/description.txt" ]; then
		text="$(cat "$dir/description.txt")"
	else
		text="$(node_get "$dir/image.json" '.description // ""')"
	fi
	[ -n "$text" ] || die "$dir has no description"
	echo "$text"
}

# meta <coord>: everything a builder or the CI planner needs about one image.
meta() { # <coord>
	local coord="$1" host layer dir hdir
	host="${coord%%/*}"
	layer="${coord#"$host"}"
	layer="${layer#/}"
	case "$layer" in
	*/*) die "not a coordinate: $coord" ;;
	esac

	hdir="$(host_dir "$host")"
	local htitle hdesc arch type version grow publish base lower lower_ref
	local title description level name artifact

	htitle="$(node_get "$hdir/image.json" '.title')"
	hdesc="$(host_description "$hdir")"
	arch="$(node_get "$hdir/image.json" '.arch')"
	type="$(node_get "$hdir/image.json" '.type')"

	if [ -z "$layer" ]; then
		dir="$hdir"
		title="$htitle"
		description="$hdesc"
		version="$(node_get "$hdir/image.json" '.version // ""')"
		grow="$(node_get "$hdir/image.json" '.grow // ""')"
		publish="$(node_get "$hdir/image.json" '.publish // ""')"
		base="" lower="" lower_ref=""
		level=0
		name="$host"
		artifact="$host"
	else
		layer_applies "$layer" "$host" ||
			die "layer $layer does not apply to host kind $host"
		dir="$(layer_dir "$layer")"
		# Templates render against the host, never the layer below, or a
		# stacked title would read "... with X with Y".
		local stem="${hdesc%.}"
		title="$(render "$(layer_get "$layer" '.title')" "$host" "$htitle" "$stem" "$layer")"
		description="$(render "$(layer_get "$layer" '.description')" "$host" "$htitle" "$stem" "$layer")"
		publish="$(render "$(layer_get "$layer" '.publish // "{host}-{layer}"')" \
			"$host" "$htitle" "$stem" "$layer")"
		# A layer inherits the lower image's version annotation.
		version=""
		grow="$(layer_get "$layer" '.grow // ""')"
		base="$(layer_get "$layer" '.base // ""')"
		case "$(base_kind "$base")" in
		root) lower="$host" lower_ref="" ;;
		layer) lower="$host/$base" lower_ref="" ;;
		ref) lower="" lower_ref="$base" ;;
		esac
		level="$(layer_level "$layer")"
		name="$host/$layer"
		artifact="$host--$layer"
	fi

	jq -nc \
		--arg coord "$coord" --arg host "$host" --arg layer "$layer" \
		--arg dir "${dir#"$repo"/}" --arg name "$name" --arg artifact "$artifact" \
		--arg title "$title" --arg description "$description" \
		--arg arch "$arch" --arg type "$type" --arg version "$version" \
		--arg grow "$grow" --arg publish "$publish" \
		--arg lower "$lower" --arg lower_ref "$lower_ref" \
		--argjson level "$level" \
		'{$coord, $host, $layer, $dir, $name, $artifact, $title, $description,
		  $arch, $type, $version, $grow, $publish, $lower, $lower_ref, $level}'
}

# -- resolve ------------------------------------------------------------------

# The component directories a node pulls its provisioning fragments from, into
# `include_dirs` so a bad include aborts the script rather than a subshell.
include_dirs=()
set_include_dirs() { # <node-json>
	local list inc
	include_dirs=()
	list="$(jq -r '(.include // [])[]' "$1")" || die "$1 did not validate"
	[ -n "$list" ] || return 0
	while IFS= read -r inc; do
		[ -d "$repo/$inc" ] || die "$1: no such include: $inc"
		include_dirs+=("$repo/$inc")
	done <<<"$list"
}

resolve() { # <coord> <out>
	local coord="$1" out="$2" info dir node_json
	info="$(meta "$coord")"
	dir="$repo/$(jq -r '.dir' <<<"$info")"
	if [ -f "$dir/layer.json" ]; then
		node_json="$dir/layer.json"
	else
		node_json="$dir/image.json"
	fi
	[ -f "$dir/provision.sh" ] || die "$coord: $dir has no provision.sh"

	rm -rf "$out"
	mkdir -p "$out"
	out="$(cd "$out" && pwd)"

	# The node's own files win nothing: a component may not shadow them, and
	# two components may not shadow each other.
	set_include_dirs "$node_json"
	local src entry target
	for src in "$dir" ${include_dirs[@]+"${include_dirs[@]}"}; do
		for entry in "$src"/*; do
			[ -e "$entry" ] || continue
			case "$(basename "$entry")" in
			image.json | layer.json | description.txt | inputs.json) continue ;;
			esac
			target="$out/$(basename "$entry")"
			[ -e "$target" ] &&
				die "$coord: $(basename "$entry") comes from both $src and elsewhere"
			ln -s "$entry" "$target"
		done
	done

	# Inputs compose the same way, so a pin shared by several images lives in
	# exactly one file.
	local inputs=()
	for src in "$dir" ${include_dirs[@]+"${include_dirs[@]}"}; do
		[ -f "$src/inputs.json" ] && inputs+=("$src/inputs.json")
	done
	if [ "${#inputs[@]}" -gt 0 ]; then
		jq -es '
			reduce .[] as $i ({};
				reduce ($i | keys_unsorted[]) as $k (.;
					if has($k) then error("input \($k) is defined twice") else .[$k] = $i[$k] end))
		' "${inputs[@]}" >"$out/inputs.json" || die "$coord: cannot merge inputs.json"
	fi

	jq -n --argjson info "$info" '
		$info
		| {name, title, description, arch, type}
		+ (if $info.version == "" then {} else {version: $info.version} end)
		+ (if $info.grow == "" then {} else {grow: $info.grow} end)
		+ {base: (if $info.lower_ref != "" then $info.lower_ref else $info.lower end)}
	' >"$out/image.json"
}

# -- check --------------------------------------------------------------------

check() {
	local host layer dir base allowed n=0
	[ -n "$(hosts)" ] || die "images/ defines no host kind"

	for host in $(hosts); do
		dir="$(host_dir "$host")"
		jq -e --argjson known "$host_keys" '
			(keys - $known) as $extra
			| if ($extra | length) > 0 then error("unknown keys: \($extra | join(", "))") else . end
			| if (.title | type) != "string" then error("missing title") else . end
			| if (.arch | IN("x86_64", "aarch64")) then . else error("bad arch") end
			| if (.type | IN("disk", "sd")) then . else error("bad type") end
			| if (.publish | type | IN("string", "null")) then . else error("bad publish") end
		' "$dir/image.json" >/dev/null || die "$dir/image.json is not valid"
		[ -f "$dir/provision.sh" ] || die "$dir: no provision.sh"
		jq -e '.vendor_image | .url and .sha256' "$dir/inputs.json" >/dev/null 2>&1 ||
			die "$dir is a root image, so its inputs.json needs vendor_image"
		set_include_dirs "$dir/image.json"
		host_description "$dir" >/dev/null
	done

	for layer in $(layers); do
		dir="$(layer_dir "$layer")"
		jq -e --argjson known "$layer_keys" '
			(keys - $known) as $extra
			| if ($extra | length) > 0 then error("unknown keys: \($extra | join(", "))") else . end
			| if (.title | type) != "string" then error("missing title") else . end
			| if (.description | type) != "string" then error("missing description") else . end
			| if (.hosts | type | IN("array", "null")) then . else error("bad hosts") end
		' "$dir/layer.json" >/dev/null || die "$dir/layer.json is not valid"
		[ -f "$dir/provision.sh" ] || die "$dir: no provision.sh"
		set_include_dirs "$dir/layer.json"
		base="$(layer_get "$layer" '.base // ""')"
		base_kind "$base" >/dev/null
		[ "$(layer_level "$layer")" -le "$max_depth" ] ||
			die "$layer sits past the $max_depth levels CI can build"
		allowed="$(jq -r '(.hosts // [])[]' "$dir/layer.json")"
		for host in $allowed; do
			host_dir "$host" >/dev/null
		done
	done

	# Every instance must resolve, and no two may claim the same ghcr name.
	local work publish seen=""
	work="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$work'" EXIT
	while read -r coord; do
		[ -n "$coord" ] || continue
		resolve "$coord" "$work/image"
		publish="$(jq -r '.publish' <<<"$(meta "$coord")")"
		if [ -n "$publish" ]; then
			case " $seen " in
			*" $publish "*) die "two images publish to $publish" ;;
			esac
			seen="$seen $publish"
		fi
		n=$((n + 1))
	done < <(list)
	echo "images: $n images OK" >&2
}

# -- cli ----------------------------------------------------------------------

[ $# -gt 0 ] || usage
command="$1"
shift

case "$command" in
list)
	[ $# -eq 0 ] || usage
	list
	;;
meta)
	[ $# -eq 1 ] || usage
	meta "$1"
	;;
resolve)
	coord=""
	out=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-o | --out)
			out="$2"
			shift 2
			;;
		-*) usage ;;
		*)
			[ -z "$coord" ] || usage
			coord="$1"
			shift
			;;
		esac
	done
	[ -n "$coord" ] && [ -n "$out" ] || usage
	resolve "$coord" "$out"
	;;
check)
	[ $# -eq 0 ] || usage
	check
	;;
-h | --help) usage ;;
*) die "unknown command: $command" ;;
esac
