#!/bin/bash
set -euxo pipefail

# The trailing $q1 makes sed exit non-zero when the root source is not a
# plain /dev/<name> block device (a btrfs subvolume, a ZFS dataset), aborting
# under set -e rather than growing the wrong thing.
#
# shellcheck disable=SC2016
ROOTDEV="$(findmnt -n -o SOURCE / | sed -E '/^\/dev\/([[:alnum:]]+)$/{s//\1/;b};$q1')"
echo "Identified root file system device as /dev/$ROOTDEV" >&2

ROOTDEV_SYSFS="/sys/class/block/$ROOTDEV"
if [ -f "$ROOTDEV_SYSFS/partition" ]; then
	ROOTDEV_PARTNUM="$(cat "$ROOTDEV_SYSFS/partition")"
	ROOTDEV_BASEDEV_SYSFS="$(readlink -f "$ROOTDEV_SYSFS/..")"
	ROOTDEV_BASEDEV="$(basename "$ROOTDEV_BASEDEV_SYSFS")"
	echo "Root filesystem device is partition $ROOTDEV_PARTNUM of device /dev/$ROOTDEV_BASEDEV" >&2

	if [ -f "$ROOTDEV_BASEDEV_SYSFS/partition" ]; then
		echo "Device $ROOTDEV_BASEDEV is itself a partition. This is not supported." >&2
		exit 1
	fi

	echo "Expanding partition $ROOTDEV_PARTNUM of device /dev/$ROOTDEV_BASEDEV..." >&2
	if command -v growpart >/dev/null; then
		# growpart exits non-zero when there is nothing to grow, which is not an
		# error here.
		growpart -u force "/dev/$ROOTDEV_BASEDEV" "$ROOTDEV_PARTNUM" || true
	elif command -v parted >/dev/null; then
		parted -s "/dev/$ROOTDEV_BASEDEV" resizepart "$ROOTDEV_PARTNUM" 100%
	else
		echo "Cannot find any supported tool to grow root partition!" >&2
		exit 1
	fi
fi

echo "Resizing root file system on /dev/$ROOTDEV to partition size..." >&2
resize2fs "/dev/$ROOTDEV"

echo "Successfully expanded root disk!" >&2
