# shellcheck shell=bash

# Because the images get executed in place, from an unpredictable file system
# layout, we don't encode the relative or absolute path to the qcow2 backing
# file and set it to the empty string. We invoke qemu or qemu-nbd with special
# arguments to assemble the chain at runtime.
compress_opts=(-c -o compression_type=zstd,cluster_size=128k)

finalize_delta() { # <overlay> <lower-head-blob> <out-delta>
	local overlay="$1" lower="$2" out="$3"
	qemu-img convert "${compress_opts[@]}" -f qcow2 -O qcow2 -B "$lower" -F qcow2 "$overlay" "$out"
	qemu-img rebase -u -b "" -f qcow2 "$out"
}

fetch_lower_ref() { # <ref> <out-layout>
	local ref="$1" out="$2" args=(--all)
	command -v skopeo >/dev/null || die "--lower-ref needs skopeo on PATH"
	[ "${insecure_lower_ref:-no}" = yes ] && args+=(--src-tls-verify=false)
	rm -rf "$out"
	skopeo copy "${args[@]}" "docker://$ref" "oci:$out" >&2
}

# Only add a delta for a volume whose content changed: an unchanged volume's
# delta would be empty, and so byte-identical to any other empty delta.
volume_unchanged() { # <overlay> <lower-head-blob>
	local overlay="$1" head="$2" overlay_size head_size status=0
	overlay_size="$(qemu-img info --output=json "$overlay" | jq -e '."virtual-size"')" ||
		die "cannot read the virtual size of $overlay"
	head_size="$(qemu-img info --output=json "$head" | jq -e '."virtual-size"')" ||
		die "cannot read the virtual size of $head"
	[ "$overlay_size" = "$head_size" ] || return 1
	qemu-img compare -q -f qcow2 -F qcow2 "$overlay" "$head" || status=$?
	case "$status" in
	0) return 0 ;;
	1) return 1 ;;
	*) die "failed to compare $raw against $head" ;;
	esac
}

# The blob paths of a role's qcow2 chain, base first, following each layer's
# `dev.treadmill.qcow2.lower` down from the layer carrying the role.
layout_chain_blobs() { # <layout> <role>
	local layout="$1" role="$2" manifest
	manifest="$(layout_manifest_path "$layout")"
	jq -er --arg dir "$layout/blobs/sha256" --arg role "$role" '
		(.layers | map({key: .digest, value: .}) | from_entries) as $by_digest
		| [.layers[] | select(.annotations["dev.treadmill.role"] == $role)]
		| if length == 1 then .[0] else error("no single \($role) head") end
		| [recurse(
			.annotations["dev.treadmill.qcow2.lower"] as $lower
			| if $lower then $by_digest[$lower] // error("missing lower \($lower)")
			  else empty end
		  )]
		| if all(.mediaType == "application/vnd.treadmill.qcow2") then .
		  else error("the \($role) chain is not all qcow2") end
		| reverse[]
		| $dir + "/" + (.digest | sub("^sha256:"; ""))
	' "$manifest"
}

layout_manifest_path() { # <layout>
	local layout="$1" digest
	digest="$(jq -r '.manifests[0].digest | sub("^sha256:"; "")' "$layout/index.json")"
	[ -n "$digest" ] && [ "$digest" != null ] ||
		die "$layout/index.json names no manifest digest"
	echo "$layout/blobs/sha256/$digest"
}
