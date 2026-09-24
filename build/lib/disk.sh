# shellcheck shell=bash

loop_dev=""
mount_root=""
dev_links=""

disk_cleanup() {
	if [ -n "$mount_root" ]; then
		$SUDO umount -R "$mount_root" 2>/dev/null || true
		rmdir "$mount_root" 2>/dev/null || true
		mount_root=""
	fi
	if [ -n "$loop_dev" ]; then
		$SUDO losetup -d "$loop_dev" 2>/dev/null || true
		loop_dev=""
	fi
	if [ -n "$dev_links" ]; then
		rm -rf "$dev_links" 2>/dev/null || true
		dev_links=""
	fi
}

# Because the images get executed in place, from an unpredictable file system
# layout, we don't encode the relative or absolute path to the qcow2 backing
# file and set it to the empty string. We invoke qemu or qemu-nbd with special
# arguments to assemble the chain at runtime. Here, we do the inverse and
# materialize the chain, such that we can mount it. `chain_head` is left naming
# the relinked head, which a delta is computed against.
chain_head=""
flatten_chain() { # <out-raw> <tag> <blob, base first>...
	local out="$1" tag="$2"
	shift 2
	local i=0 prev="" blob copy
	for blob in "$@"; do
		if [ "$i" = 0 ]; then
			prev="$blob"
		else
			copy="$work/chain-$tag-$i.qcow2"
			cp --reflink=auto "$blob" "$copy"
			chmod +w "$copy"
			qemu-img rebase -u -b "$prev" -F qcow2 -f qcow2 "$copy"
			prev="$copy"
		fi
		i=$((i + 1))
	done
	chain_head="$prev"
	qemu-img convert -f qcow2 -O raw "$prev" "$out"
}

grow_raw() { # <raw> <extra-bytes>
	local raw="$1" extra="$2" size
	size="$(stat -c%s "$raw")"
	truncate -s "$((size + extra))" "$raw"
}

attach_loop() { # <raw> <partitioned: yes|no>
	local raw="$1" partitioned="$2" args=(--find --show)
	[ "$partitioned" = yes ] && args+=(--partscan)
	loop_dev="$($SUDO losetup "${args[@]}" "$raw")"
	[ -b "$loop_dev" ] || die "losetup did not yield a block device for $raw"
}

resize_root() { # <partitioned: yes|no>
	local target="$loop_dev"
	if [ "$1" = yes ]; then
		$SUDO growpart "$loop_dev" 1
		$SUDO partx -u "$loop_dev"
		target="${loop_dev}p1"
	fi
	$SUDO e2fsck -fy "$target" >/dev/null 2>&1 || true
	$SUDO resize2fs "$target"
}

root_partition() {
	if [ "$1" = yes ]; then
		echo "${loop_dev}p1"
	else
		echo "$loop_dev"
	fi
}

# Every device lookup is scoped to this loop device's own partitions.
#
# The build host may be (or is, on GH actions) itself an Ubuntu cloud image
# carrying the same `cloudimg-rootfs` label, and udev keeps one `by-label` link,
# so binding the host's real /dev/disk could resolve to the host's disk. We must
# definitely avoid that.
resolve_loop_part() { # <fstab-spec>
	local spec="$1" tag val part
	case "$spec" in
	LABEL=*) tag=LABEL val="${spec#LABEL=}" ;;
	UUID=*) tag=UUID val="${spec#UUID=}" ;;
	PARTUUID=*) tag=PARTUUID val="${spec#PARTUUID=}" ;;
	PARTLABEL=*) tag=PARTLABEL val="${spec#PARTLABEL=}" ;;
	/dev/*)
		echo "$spec"
		return 0
		;;
	*) return 1 ;;
	esac
	for part in "${loop_dev}"p*; do
		[ -b "$part" ] || continue
		if [ "$($SUDO blkid -s "$tag" -o value "$part" 2>/dev/null)" = "$val" ]; then
			echo "$part"
			return 0
		fi
	done
	return 1
}

mount_fstab_parts() { # <root-mnt>
	local root="$1" fstab="$1/etc/fstab" spec mp fstype rest slashes dev _
	[ -f "$fstab" ] || return 0
	while read -r spec mp fstype rest; do
		case "$spec" in "" | \#*) continue ;; esac
		[ "$mp" != / ] || continue
		case "$mp" in /*) ;; *) continue ;; esac
		case "$fstype" in swap | proc | sysfs | tmpfs | devpts | devtmpfs | none) continue ;; esac
		slashes="${mp//[!\/]/}"
		printf '%s\t%s\t%s\n' "${#slashes}" "$mp" "$spec"
	done <"$fstab" | sort -n -k1,1 | while IFS="$(printf '\t')" read -r _ mp spec; do
		dev="$(resolve_loop_part "$spec")" ||
			die "cannot resolve fstab spec '$spec' (for $mp) to a $loop_dev partition"
		$SUDO mkdir -p "$root$mp"
		$SUDO mount "$dev" "$root$mp"
	done
}

build_dev_links() {
	dev_links="$(mktemp -d)"
	local part tag val dir
	for part in "${loop_dev}"p*; do
		[ -b "$part" ] || continue
		for tag in UUID:by-uuid PARTUUID:by-partuuid LABEL:by-label PARTLABEL:by-partlabel; do
			val="$($SUDO blkid -s "${tag%%:*}" -o value "$part" 2>/dev/null || true)"
			[ -n "$val" ] || continue
			dir="$dev_links/${tag#*:}"
			mkdir -p "$dir"
			ln -sf "../../$(basename "$part")" "$dir/$val"
		done
	done
	echo "$dev_links"
}

split_sd_image() { # <img> <out-fat> <out-root-raw>
	local img="$1" out_fat="$2" out_root="$3"
	attach_loop "$img" yes
	[ -b "${loop_dev}p1" ] || die "$img has no partition 1 (expected a FAT boot partition)"
	[ -b "${loop_dev}p2" ] || die "$img has no partition 2 (expected an ext4 root partition)"
	$SUDO dd if="${loop_dev}p1" of="$out_fat" bs=4M status=none
	$SUDO dd if="${loop_dev}p2" of="$out_root" bs=4M status=none
	$SUDO chown "$(id -u):$(id -g)" "$out_fat" "$out_root"
	$SUDO losetup -d "$loop_dev"
	loop_dev=""
}
