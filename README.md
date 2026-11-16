# Treadmill Images

This repository contains instructions and scripts to build disk images
(specialized OCI images) for use with the Treadmill distributed hardware
testbed.

An image is the combination of a **host kind** and a stack of **layers**. A host
kind (`images/<host>/`) is the root of the stack: it starts from a vendor image,
wires the guest up to the Treadmill API, and knows how that class of machine
boots. A layer (`layers/<layer>/`) is a functional addition — a toolchain, an
IDE, a CI runner — defined exactly once and applied to every host kind. The
pre-defined host kinds are:

- Ubuntu Server 26.04, for Treadmill virtual machines (`x86_64`, a `disk`)
- Raspberry Pi OS 13, for NBD-netbooted boards (`aarch64`, an `sd` card)

and the pre-defined layers are:

- `tock`, the embedded development toolchain: ARM and RISC-V GCC, OpenOCD built
  from a pinned upstream commit, `rustup`, and the usual debugging and flashing
  tools
- `webide`, the code-server Web IDE
- `gha-runner`, a self-registering GitHub Actions runner

A host kind's root image carries only what the Treadmill API needs to drive a
guest, so it is a usable starting point for an image that wants none of the
above. It publishes as `<host>-minimal`; `<host>` is the `tock` image, which is
what that repository has always held.

Images are addressed by a **coordinate**: `<host>` for a host kind's root image,
`<host>/<layer>` for a layer applied to it — `ubuntu-server-2604`,
`raspberrypios-13/webide`. A layer names the layer it stacks on, so a coordinate
never has to spell out the whole stack.

Images are a custom OCI-based format. An image provides one or more roles, each
a stack of layered QCOW2 images (which enables efficient deduplication and
extension): a `disk` image provides a `disk` for VMs, and an `sd` image provides
the `rootfs` and `bootfs` file systems of an NBD-netbooted board. A host kind's
root image defines the root of these stacks, and each layer adds a layer on top
of each stack it changes, sharing the layers below.

Building these images requires a privileged Linux host: the scripts use
`qemu-nbd`, `mount` and `systemd-nspawn`, escalating through `sudo` per
operation. Building an image for a foreign architecture requires `binfmt_misc`
and `qemu-user-static` registered for it.

## Build

You can get all the build dependencies through Nix. This is not necessary, but
pretty convenient.

```bash
nix develop
```

Use a command like the following to build an "image chain", which will build
missing intermediate layers automatically. You need to supply the paths to
pre-built injected payload files (like in this case, the Treadmill `tml` binary
and the Caddy web server).

```bash
./build/build-chain.sh --image ubuntu-server-2604/webide \
    --payload "$(nix build --no-link --print-out-paths .#tml-x86_64)/bin/tml" \
    --payload "$(nix build --no-link --print-out-paths .#tml-caddy-x86_64)/bin/caddy" \
    -o out/ubuntu-webide
```

Or build just a single image. `build-image.sh` builds from a single directory
and knows nothing about layers, so resolve the coordinate into one first:

```bash
./tools/images.sh resolve ubuntu-server-2604 --out /tmp/image
./build/build-image.sh --image /tmp/image -o out/base

./tools/images.sh resolve ubuntu-server-2604/webide --out /tmp/image
./build/build-image.sh --image /tmp/image --lower out/base -o out/webide
```

You can also extend an existing image that is fetched from an OCI registry:

```bash
./build/build-image.sh --image /tmp/image \
    --lower-ref ghcr.io/treadmill-tb/ubuntu-server-2604@sha256:… \
    -o out/webide
```

You can use this command to verify that your image works, by booting it in the
QEMU supervisor. This only works for images that are compatible with the QEMU
supervisor (e.g., not Raspberry Pi OS, that one's an `nbd-netboot` image).

```bash
nix run 'github:treadmill-tb/treadmill#qemu-supervisor-local' -- --image <ref>
```

## Add a host kind

Create `images/<host>/` with an `image.json`, a `description.txt`, an
`inputs.json` carrying a `vendor_image`, and a `provision.sh`. Every layer that
does not restrict itself applies to it automatically.

`image.json`:

| Key              | Meaning                                                                |
|------------------|------------------------------------------------------------------------|
| `title`          | required for the OCI manifest                                          |
| `arch`, `type`   | required; `x86_64`/`aarch64`, `disk`/`sd`                              |
| `grow`           | the size of the new image layer                                        |
| `version`        | optional OCI metadata                                                  |
| `publish`        | ghcr repository name; defaults to `<host>`, `""` to skip               |
| `include`        | shared component directories to provision from, e.g. `shared/openocd`  |

## Add a layer

Create `layers/<layer>/` with a `layer.json` and a `provision.sh`. It is built
on top of every host kind it applies to, with no per-host-kind file anywhere.

`layer.json`:

| Key           | Meaning                                                                       |
|---------------|--------------------------------------------------------------------------------|
| `title`       | required; a template (see below)                                               |
| `description` | required; a template                                                           |
| `base`        | the layer this stacks on, a registry reference, or none for the root image     |
| `publish`     | a template; defaults to `{host}-{layer}`, `""` to skip                         |
| `grow`        | grow the image further, for a layer that needs more room than the root took    |
| `include`     | shared component directories to provision from                                 |
| `hosts`       | the host kinds this applies to; omit for all of them                           |

`title`, `description` and `publish` are templates over `{host}`, `{host_title}`,
`{host_description}` (the host kind's `description.txt` without its trailing
period) and `{layer}`. They render against the **host kind**, never the layer
below, so a layer stacked on another does not inherit its prose.

## Provisioning

`provision.sh` runs in the context of the guest image. We use `systemd-nspawn`
for that. It runs with the host's network namespace, so you have access to the
internet. The driver exports:

| Variable          | Meaning                          |
|-------------------|----------------------------------|
| `TML_IMAGE_DIR`   | this image's directory           |
| `TML_PAYLOAD_DIR` | binaries passed with `--payload` |
| `TML_ARCH`        | `x86_64` or `aarch64`            |
| `TML_TYPE`        | `disk` or `sd`                   |

It also provides `<name>_version`, `<name>_url` and `<name>_sha256` per entry in
the image's `inputs.json`. The `inputs.json` tracks outside assets that can be
fetched in the image build process. It's a separate file such that we can
automatically bump these inputs. A key may be suffixed `__<arch>` to pin a
per-architecture asset; the suffix is dropped before the variables are exported.

A host kind or a layer may `include` component directories under `shared/`.
Their files are provisioned alongside the image's own (reachable through
`$TML_IMAGE_DIR`) and their `inputs.json` is merged into the image's, so a pin
several images share lives in exactly one file.

To check the repo layout and image definitions, run `./tools/ci/plan.sh
--check`. Use `--matrix` to emit the CI job matrix, `./tools/images.sh list` to
see every image coordinate, and `./tools/images.sh meta <coord>` to see what one
resolves to.
