#!/bin/sh
set -eu

# Distribution OpenOCD releases lag far behind trunk, which is where support
# for new targets and probes lands. Build a pinned upstream commit instead.

: "${openocd_version:?}"
: "${openocd_url:?}"
: "${openocd_sha256:?}"
: "${TML_ARCH:?}"

build_deps='
	autoconf
	automake
	build-essential
	ca-certificates
	curl
	libcapstone-dev
	libftdi1-dev
	libgpiod-dev
	libhidapi-dev
	libjaylink-dev
	libjim-dev
	libtool
	libusb-1.0-0-dev
	pkg-config
	texinfo
'

# Remove the build deps this script installed
new_deps=''
for pkg in $build_deps; do
	dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed ||
		new_deps="$new_deps $pkg"
done
# shellcheck disable=SC2086
apt-get install -y $build_deps

src=/var/tmp/openocd-src
rm -rf "$src"
mkdir -p "$src"
curl -fL --retry 3 "$openocd_url" -o "$src.tar.gz"
echo "$openocd_sha256  $src.tar.gz" | sha256sum -c -
tar -xzf "$src.tar.gz" -C "$src" --strip-components=1
rm -f "$src.tar.gz"

cd "$src"
# Without a git checkout, guess-rev.sh would report a bare "-snapshot".
printf '#!/bin/sh\necho "-g%s"\n' "$(echo "$openocd_version" | cut -c1-10)" >guess-rev.sh
./bootstrap nosubmodule
# Direct-register GPIO bitbanging on a Raspberry Pi's header; the driver only
# builds for ARM hosts.
arch_flags=''
[ "$TML_ARCH" = aarch64 ] && arch_flags='--enable-bcm2835gpio'
# shellcheck disable=SC2086
./configure --prefix=/usr/local --disable-werror $arch_flags
make -j"$(nproc)"
make install
install -m 0644 contrib/60-openocd.rules /etc/udev/rules.d/60-openocd.rules
cd /
rm -rf "$src"

# Keep the shared libraries openocd links against, then drop the build deps.
ldd /usr/local/bin/openocd | awk '$3 ~ /^\// { print $3 }' |
	while read -r lib; do
		dpkg-query -S "$lib" 2>/dev/null ||
			dpkg-query -S "$(realpath "$lib")" 2>/dev/null || true
	done | cut -d: -f1 | sort -u | xargs -r apt-mark manual
if [ -n "$new_deps" ]; then
	# shellcheck disable=SC2086
	apt-mark auto $new_deps
	apt-get autoremove --purge -y
fi

/usr/local/bin/openocd --version
