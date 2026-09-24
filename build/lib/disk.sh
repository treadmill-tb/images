# shellcheck shell=bash

root_dev=""
nbd_devs=()
mount_root=""
dev_links=""

disk_cleanup() {
	if [ -n "$mount_root" ]; then
		$SUDO umount -R "$mount_root" 2>/dev/null || true
		rmdir "$mount_root" 2>/dev/null || true
		mount_root=""
	fi
	local dev
	for dev in ${nbd_devs[@]+"${nbd_devs[@]}"}; do
		nbd_detach "$dev"
	done
	nbd_devs=()
	root_dev=""
	if [ -n "$dev_links" ]; then
		rm -rf "$dev_links" 2>/dev/null || true
		dev_links=""
	fi
}

# Because the images get executed in place, from an unpredictable file system
# layout, we don't encode the relative or absolute path to the qcow2 backing
# file and set it to the empty string. We invoke qemu or qemu-nbd with special
# arguments to assemble the chain at runtime. Here, we do the inverse and relink
# the chain, such that an overlay can be put on top of it. `chain_head` is left
# naming the relinked head.
chain_head=""
link_chain() { # <tag> <blob, base first>...
	local tag="$1"
	shift
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
}

create_overlay() { # <out> <lower-head>
	qemu-img create -q -f qcow2 -b "$2" -F qcow2 "$1"
}

grow_overlay() { # <overlay> <extra-bytes>
	qemu-img resize -q -f qcow2 "$1" "+$2"
}

nbd_dev=""
nbd_attach() { # <qcow2> <partitioned: yes|no>
	local image="$1" partitioned="$2" sys dev i
	[ -e /sys/module/nbd ] || $SUDO modprobe nbd max_part=16 ||
		die "cannot load the nbd kernel module"
	nbd_dev=""
	for sys in /sys/block/nbd*; do
		[ -e "$sys/pid" ] && continue
		dev="/dev/${sys##*/}"
		if $SUDO "$qemu_nbd" --connect="$dev" --format=qcow2 \
			--discard=unmap --detect-zeroes=unmap \
			--pid-file="$work/${dev##*/}.pid" "$image" 2>/dev/null; then
			nbd_dev="$dev"
			break
		fi
	done
	[ -n "$nbd_dev" ] || die "found no free nbd device for $image"
	nbd_devs+=("$nbd_dev")
	[ "$partitioned" = yes ] || return 0
	for i in $(seq 50); do
		[ -b "${nbd_dev}p1" ] && return 0
		sleep 0.1
	done
	die "$nbd_dev shows no partitions; is nbd loaded with max_part > 0?"
}

nbd_detach() { # <dev>
	local dev="$1" pidfile="$work/${1##*/}.pid" pid="" i
	[ -f "$pidfile" ] && pid="$(cat "$pidfile")"
	$SUDO "$qemu_nbd" --disconnect "$dev" >/dev/null 2>&1 || true
	[ -n "$pid" ] || return 0
	for i in $(seq 100); do
		[ -d "/proc/$pid" ] || return 0
		sleep 0.1
	done
	die "qemu-nbd serving $dev did not exit"
}

resize_root() { # <partitioned: yes|no>
	local target="$root_dev"
	if [ "$1" = yes ]; then
		$SUDO growpart "$root_dev" 1
		$SUDO partx -u "$root_dev"
		target="${root_dev}p1"
	fi
	$SUDO e2fsck -fy "$target" >/dev/null 2>&1 || true
	$SUDO resize2fs "$target"
}

root_partition() {
	if [ "$1" = yes ]; then
		echo "${root_dev}p1"
	else
		echo "$root_dev"
	fi
}

# Every device lookup is scoped to the root device's own partitions.
#
# The build host may be (or is, on GH actions) itself an Ubuntu cloud image
# carrying the same `cloudimg-rootfs` label, and udev keeps one `by-label` link,
# so binding the host's real /dev/disk could resolve to the host's disk. We must
# definitely avoid that.
resolve_root_part() { # <fstab-spec>
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
	for part in "${root_dev}"p*; do
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
		dev="$(resolve_root_part "$spec")" ||
			die "cannot resolve fstab spec '$spec' (for $mp) to a $root_dev partition"
		$SUDO mkdir -p "$root$mp"
		$SUDO mount "$dev" "$root$mp"
	done
}

build_dev_links() {
	dev_links="$(mktemp -d)"
	local part tag val dir
	for part in "${root_dev}"p*; do
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

convert_partition() { # <img> <number> <out-qcow2> <qemu-img convert args>...
	local img="$1" number="$2" out="$3" offset size
	shift 3
	read -r offset size < <(sfdisk -J "$img" | jq -er --argjson n "$number" '
		.partitiontable | (.sectorsize // 512) as $ss | .partitions[$n - 1] | select(.)
		| "\(.start * $ss) \(.size * $ss)"') ||
		die "$img has no partition $number"
	qemu-img convert "$@" --image-opts \
		"driver=raw,offset=$offset,size=$size,file.driver=file,file.filename=${img//,/,,}" \
		-O qcow2 "$out"
}
