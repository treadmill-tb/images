# shellcheck shell=bash

# Because the images get executed in place, from an unpredictable file system
# layout, we don't encode the relative or absolute path to the qcow2 backing
# file and set it to the empty string. We invoke qemu or qemu-nbd with special
# arguments to assemble the chain at runtime.
finalize_delta() { # <work.raw> <lower-head-blob> <out-delta>
	local raw="$1" lower="$2" out="$3"
	qemu-img convert -c -f raw -O qcow2 -B "$lower" -F qcow2 "$raw" "$out"
	qemu-img rebase -u -b "" -f qcow2 "$out"
}

fetch_lower_ref() { # <ref> <out-layout>
	local ref="$1" out="$2" args=(--all)
	command -v skopeo >/dev/null || die "--lower-ref needs skopeo on PATH"
	[ "${insecure_lower_ref:-no}" = yes ] && args+=(--src-tls-verify=false)
	rm -rf "$out"
	skopeo copy "${args[@]}" "docker://$ref" "oci:$out" >&2
}

layout_root_blobs() { # <layout>
	local layout="$1" manifest
	manifest="$(layout_manifest_path "$layout")"
	jq -r --arg dir "$layout/blobs/sha256" '
		.layers[]
		| select(.annotations["dev.treadmill.role"] == "root")
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
