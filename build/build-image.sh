#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
	echo "build-image: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<-USAGE
		usage: build-image.sh --image <dir> -o <out-layout>
		                      [--lower <oci-layout> | --lower-ref <registry-ref>]
		                      [--insecure-lower-ref] [--payload <path>]...
		                      [--image-util <path>] [--work <dir>]
	USAGE
	exit 2
}

image_dir=""
lower=""
lower_ref=""
out=""
payloads=()
image_util="image-util"
work_parent=""
insecure_lower_ref=no

while [ $# -gt 0 ]; do
	case "$1" in
	--image)
		image_dir="$2"
		shift 2
		;;
	--lower)
		lower="$2"
		shift 2
		;;
	--lower-ref)
		lower_ref="$2"
		shift 2
		;;
	--insecure-lower-ref)
		insecure_lower_ref=yes
		shift
		;;
	-o | --out)
		out="$2"
		shift 2
		;;
	--payload)
		payloads+=("$2")
		shift 2
		;;
	--image-util)
		image_util="$2"
		shift 2
		;;
	--work)
		work_parent="$2"
		shift 2
		;;
	-h | --help) usage ;;
	*) die "unknown argument: $1" ;;
	esac
done

[ -n "$image_dir" ] || die "missing --image <dir>"
[ -n "$out" ] || die "missing -o <out-layout>"
[ -d "$image_dir" ] || die "no such image directory: $image_dir"
[ -z "$lower" ] || [ -z "$lower_ref" ] || die "--lower and --lower-ref are exclusive"
command -v "$image_util" >/dev/null || [ -x "$image_util" ] ||
	die "image-util not found: $image_util"

SUDO=""
[ "$(id -u)" = 0 ] || SUDO=sudo

for tool in qemu-img qemu-nbd sfdisk partx blkid mount umount findmnt fstrim \
	growpart resize2fs e2fsck systemd-nspawn curl sha256sum jq xz; do
	command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
qemu_nbd="$(command -v qemu-nbd)"

# shellcheck source=lib/disk.sh
. "$here/lib/disk.sh"
# shellcheck source=lib/guest.sh
. "$here/lib/guest.sh"
# shellcheck source=lib/oci.sh
. "$here/lib/oci.sh"

image_dir="$(cd "$image_dir" && pwd)"
name="$(basename "$(dirname "$image_dir")")/$(basename "$image_dir")"

img_title="" img_arch="" img_type="" img_base=""
img_version="" img_description="" img_grow=""

meta_env="$(jq -er '
	def req($k): .[$k] // error("missing \($k)");
	@sh "img_title=\(req("title")) img_arch=\(req("arch")) img_type=\(req("type"))
	     img_base=\(.base // "") img_version=\(.version // "")
	     img_description=\(.description // "") img_grow=\(.grow // "")"
' "$image_dir/image.json")" || die "$image_dir/image.json did not validate"
eval "$meta_env"

parse_size() { # <size>
	local v="$1" mult=1
	case "$v" in
	*[Kk]) mult=1024 v="${v%?}" ;;
	*[Mm]) mult=$((1024 * 1024)) v="${v%?}" ;;
	*[Gg]) mult=$((1024 * 1024 * 1024)) v="${v%?}" ;;
	esac
	case "$v" in '' | *[!0-9]*) die "cannot parse size: $1" ;; esac
	echo "$((v * mult))"
}

grow_bytes=""
[ -z "$img_grow" ] || grow_bytes="$(parse_size "$img_grow")"

host_arch="$(uname -m)"
if [ "$img_arch" != "$host_arch" ]; then
	[ -e "/proc/sys/fs/binfmt_misc/qemu-$img_arch" ] || die "\
$name targets $img_arch but this host is $host_arch, and no binfmt_misc
handler for qemu-$img_arch is registered. Register one, e.g.

    docker run --privileged --rm tonistiigi/binfmt --install all

or on NixOS set boot.binfmt.emulatedSystems, then retry."
fi

[ -f "$image_dir/provision.sh" ] || die "$name has no provision.sh"

partitioned=no
if [ "$img_type" = disk ]; then
	partitioned=yes
fi

if [ -n "$img_base" ]; then
	is_root=no
	[ -n "$lower" ] || [ -n "$lower_ref" ] ||
		die "$name has base \"$img_base\": pass --lower or --lower-ref"
else
	is_root=yes
	[ -z "$lower" ] && [ -z "$lower_ref" ] ||
		die "$name has no base: it fetches its own vendor image"
fi

if [ -z "$work_parent" ]; then
	work_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
fi
mkdir -p "$work_parent"
work="$(mktemp -d "$work_parent/tml-build-XXXXXX")"

cleanup() {
	disk_cleanup
	rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$out"
out="$(cd "$out" && pwd)"

echo "build-image: $name ($img_type, $img_arch) -> $out" >&2

payload_dir="$work/payload"
mkdir -p "$payload_dir"
for payload in ${payloads[@]+"${payloads[@]}"}; do
	install -m 0755 "$payload" "$payload_dir/$(basename "$payload")"
done

inputs_env="$work/inputs.env"
: >"$inputs_env"
if [ -f "$image_dir/inputs.json" ]; then
	jq -r --arg arch "$img_arch" '
		to_entries[]
		| (.key | split("__")) as $parts
		| select(($parts | length) == 1 or $parts[1] == $arch)
		| $parts[0] as $k
		| .value
		| "\($k)_version=\(.version | @sh)",
		  "\($k)_url=\(.url | @sh)",
		  "\($k)_sha256=\(.sha256 | @sh)"
	' "$image_dir/inputs.json" >>"$inputs_env"
fi

# The volumes an image consists of, each the chain of the role it provides.
# A `disk` is one partitioned disk. An `sd` card splits into its root and boot
# file systems, which are netbooted as separate volumes. The first volume is
# the one that is grown and mounted at /.
if [ "$img_type" = disk ]; then
	roles=(disk)
else
	roles=(rootfs bootfs)
fi
primary="${roles[0]}"

declare -A vol_layer0=() vol_head=() vol_chain_len=() vol_overlay=() vol_dev=()
lower_layout=""

if [ "$is_root" = yes ]; then
	vendor_url="$(jq -r '.vendor_image.url // empty' "$image_dir/inputs.json" 2>/dev/null || true)"
	vendor_sha="$(jq -r '.vendor_image.sha256 // empty' "$image_dir/inputs.json" 2>/dev/null || true)"
	[ -n "$vendor_url" ] && [ -n "$vendor_sha" ] ||
		die "$name has no base, so $image_dir/inputs.json needs vendor_image"

	echo "build-image: fetching the vendor image..." >&2
	download="$work/vendor.download"
	curl -fL --retry 3 "$vendor_url" -o "$download" || die "failed to fetch $vendor_url"
	echo "$vendor_sha  $download" | sha256sum -c - >/dev/null ||
		die "checksum mismatch for $vendor_url"

	if [ "$img_type" = disk ]; then
		vol_layer0[disk]="$work/disk.layer0.qcow2"
		qemu-img convert "${compress_opts[@]}" -f qcow2 -O qcow2 "$download" "${vol_layer0[disk]}"
		rm -f "$download"
	else
		sd_img="$work/sd.img"
		xz -dc "$download" >"$sd_img" || die "failed to decompress $vendor_url"
		rm -f "$download"

		vol_layer0[bootfs]="$work/bootfs.layer0.qcow2"
		convert_partition "$sd_img" 1 "${vol_layer0[bootfs]}" "${compress_opts[@]}"
		vol_layer0[rootfs]="$work/rootfs.layer0.qcow2"
		convert_partition "$sd_img" 2 "${vol_layer0[rootfs]}" "${compress_opts[@]}"
		rm -f "$sd_img"
	fi

	for role in "${roles[@]}"; do
		link_chain "$role" "${vol_layer0[$role]}"
		vol_head[$role]="$chain_head"
		vol_chain_len[$role]=1
	done
else
	if [ -n "$lower_ref" ]; then
		lower_layout="$work/lower"
		echo "build-image: copying $lower_ref into a local layout..." >&2
		fetch_lower_ref "$lower_ref" "$lower_layout"
	else
		[ -d "$lower" ] || die "no such lower layout: $lower"
		lower_layout="$(cd "$lower" && pwd)"
	fi
	"$image_util" verify "$lower_layout" --name "$name lower" ||
		die "the lower image did not verify"

	for role in "${roles[@]}"; do
		blobs="$(layout_chain_blobs "$lower_layout" "$role")" ||
			die "the lower image has no usable $role chain"
		mapfile -t lower_blobs <<<"$blobs"
		link_chain "$role" "${lower_blobs[@]}"
		vol_head[$role]="$chain_head"
		vol_chain_len[$role]="${#lower_blobs[@]}"
	done
fi

for role in "${roles[@]}"; do
	vol_overlay[$role]="$work/$role.overlay.qcow2"
	create_overlay "${vol_overlay[$role]}" "${vol_head[$role]}"
done

if [ -n "$grow_bytes" ]; then
	echo "build-image: growing $primary by $grow_bytes bytes" >&2
	grow_overlay "${vol_overlay[$primary]}" "$grow_bytes"
fi

nbd_attach "${vol_overlay[$primary]}" "$partitioned"
root_dev="$nbd_dev"
for role in "${roles[@]}"; do
	if [ "$role" = "$primary" ]; then
		vol_dev[$role]="$root_dev"
	else
		nbd_attach "${vol_overlay[$role]}" no
		vol_dev[$role]="$nbd_dev"
	fi
done
if [ -n "$grow_bytes" ]; then
	resize_root "$partitioned"
fi

mount_root="$(mktemp -d)"
$SUDO mount "$(root_partition "$partitioned")" "$mount_root"
if [ "$img_type" = disk ]; then
	mount_fstab_parts "$mount_root"
else
	# noatime: reading a file must not change the file system, or every image
	# would ship a boot delta.
	$SUDO mkdir -p "$mount_root/boot/firmware"
	$SUDO mount -t vfat -o noatime "${vol_dev[bootfs]}" "$mount_root/boot/firmware"
fi

build_nspawn_binds "$partitioned"

provision "$mount_root" "$image_dir" "$payload_dir" "$inputs_env"

# ext4 defers discarding just-freed blocks until the transaction that freed them
# commits, so fstrim on its own skips everything this image deleted and the trim
# does not reach the shipped blob. syncfs first.
findmnt -R -n -l -o TARGET "$mount_root" | while read -r mnt; do
	$SUDO sync -f "$mnt"
	$SUDO fstrim -v "$mnt" >&2
done
disk_cleanup

# A root image starts every chain with its vendor layer. Each volume the image
# changed gets a layer on top of its chain; an unchanged one gets none, since
# an empty layer would only duplicate its lower's content.
layer_args=()
chain_args=()
for role in "${roles[@]}"; do
	if [ "$is_root" = yes ]; then
		layer_args+=(--layer "$role=qcow2:${vol_layer0[$role]}")
	fi
	if volume_unchanged "${vol_overlay[$role]}" "${vol_head[$role]}"; then
		echo "build-image: $role is unchanged, adding no layer to it" >&2
	else
		delta="$work/$role.delta.qcow2"
		finalize_delta "${vol_overlay[$role]}" "${vol_head[$role]}" "$delta"
		layer_args+=(--layer "$role=qcow2:$delta")
		vol_chain_len[$role]=$((${vol_chain_len[$role]} + 1))
	fi
	rm -f "${vol_overlay[$role]}"
	chain_args+=(--chain "$role=${vol_chain_len[$role]}")
done
rm -f "$work"/chain-*.qcow2

# `version` and `description` are optional.
meta_args=(--title "$img_title" --name "$name")
if [ -n "$img_version" ]; then
	meta_args+=(--version "$img_version")
fi
if [ -n "$img_description" ]; then
	meta_args+=(--description "$img_description")
fi

if [ "$is_root" = yes ]; then
	"$image_util" assemble "${meta_args[@]}" -o "$out" "${layer_args[@]}"
else
	append_args=(append --lower "$lower_layout" "${meta_args[@]}" -o "$out")
	append_args+=(${layer_args[@]+"${layer_args[@]}"})
	if [ -n "$lower_ref" ]; then
		append_args+=(--base-name "$lower_ref")
	fi
	"$image_util" "${append_args[@]}"
fi

"$image_util" verify "$out" --title "$img_title" --name "$name" "${chain_args[@]}"

echo "build-image: $name -> $out (OK)" >&2
