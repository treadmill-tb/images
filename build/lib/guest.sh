# shellcheck shell=bash

# nspawn overmounts /tmp with a fresh tmpfs, so staged scripts live under
# /var/tmp or the container cannot exec them.
guest_build_dir=/var/tmp/tml-build

nspawn_binds=()

guest_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

build_nspawn_binds() { # <partitioned: yes|no>
	nspawn_binds=(--bind="$loop_dev")
	[ "$1" = yes ] || return 0
	local part
	for part in "${loop_dev}"p*; do
		[ -b "$part" ] && nspawn_binds+=(--bind="$part")
	done
	nspawn_binds+=(--bind="$(build_dev_links):/dev/disk")
}

nspawn_run() { # <mnt> <command>...
	local mnt="$1"
	shift
	$SUDO systemd-nspawn --quiet --register=no --setenv="PATH=$guest_path" \
		"${nspawn_binds[@]}" -D "$mnt" -- "$@"
}

# -L: an image directory reaches shared/ through relative symlinks, which would
# dangle once staged.
stage_image() { # <mnt> <image-dir> <payload-dir> <inputs-env>
	local mnt="$1" image_dir="$2" payload_dir="$3" inputs_env="$4"
	local staged="$mnt$guest_build_dir"

	$SUDO rm -rf "$staged"
	$SUDO mkdir -p "$staged"
	$SUDO cp -aLT "$image_dir" "$staged/image"
	$SUDO cp -aLT "$payload_dir" "$staged/payload"
	$SUDO install -m 0644 "$inputs_env" "$staged/inputs.env"

	$SUDO tee "$staged/run.sh" >/dev/null <<-RUNNER
		#!/bin/sh
		set -eu
		TML_IMAGE_DIR=$guest_build_dir/image
		TML_PAYLOAD_DIR=$guest_build_dir/payload
		TML_ARCH='$img_arch'
		TML_TYPE='$img_type'
		DEBIAN_FRONTEND=noninteractive
		export TML_IMAGE_DIR TML_PAYLOAD_DIR TML_ARCH TML_TYPE DEBIAN_FRONTEND
		set -a
		. $guest_build_dir/inputs.env
		set +a
		exec "\$TML_IMAGE_DIR/provision.sh"
	RUNNER
	$SUDO chmod 0755 "$staged/run.sh" "$staged/image/provision.sh"
}

# A cloud image ships /etc/resolv.conf as a symlink to the resolved stub, which
# dangles in the container. nspawn's --resolv-conf=copy-host cannot write
# through the dangling symlink and replace-host bakes the host's file into the
# shipped image, so the swap is done here and undone after.
resolv_conf_backup=""
resolv_conf_borrow() { # <mnt>
	local resolv="$1/etc/resolv.conf"
	resolv_conf_backup=""
	if [ -e "$resolv" ] || [ -L "$resolv" ]; then
		resolv_conf_backup="$resolv.tml-orig"
		$SUDO mv "$resolv" "$resolv_conf_backup"
	fi
	$SUDO cp -fL /etc/resolv.conf "$resolv"
}
resolv_conf_restore() { # <mnt>
	local resolv="$1/etc/resolv.conf"
	$SUDO rm -f "$resolv"
	if [ -n "$resolv_conf_backup" ]; then
		$SUDO mv "$resolv_conf_backup" "$resolv"
		resolv_conf_backup=""
	fi
}

provision() { # <mnt> <image-dir> <payload-dir> <inputs-env>
	local mnt="$1"
	stage_image "$@"
	resolv_conf_borrow "$mnt"
	nspawn_run "$mnt" /bin/sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update'
	nspawn_run "$mnt" "$guest_build_dir/run.sh"
	resolv_conf_restore "$mnt"
	$SUDO rm -rf "$mnt$guest_build_dir"
}
