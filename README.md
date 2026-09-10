# Treadmill Images

This repository contains instructions and scripts to build disk images
(specialized OCI images) for use with the Treadmill distributed hardware
testbed. It contains a few pre-defined images, like:

- Ubuntu Server 26.04 (in a base, Web IDE, and GH actions runner variant)
- Raspberry Pi OS 13 (in a base, Web IDE, and GH actions runner variant)

Images are a custom OCI-based format defining stacks of layered QCOW2 images
(which enables efficient deduplication and extension). Each image's `base`
variant defines the root of this stack, and the other layers on top simply
extend it, sharing this base layer.

Building these images requires a privileged Linux host: the scripts use
`losetup`, `mount` and `systemd-nspawn`, escalating through `sudo` per
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
pre-built injected payload files (like in this case, the Treadmill puppet binary
and the Caddy web server).

```bash
./build/build-chain.sh --image images/ubuntu-server-2604/webide \
    --payload "$(nix build --no-link --print-out-paths .#tml-puppet-x86_64)/bin/tml-puppet" \
    --payload "$(nix build --no-link --print-out-paths .#tml-caddy-x86_64)/bin/caddy" \
    -o out/ubuntu-webide
```

Or build just a single image:

```bash
./build/build-image.sh --image images/ubuntu-server-2604/base -o out/base
./build/build-image.sh --image images/ubuntu-server-2604/webide \
    --lower out/base -o out/webide
```

You can also extend an existing image that is fetched from an OCI registry:

```bash
./build/build-image.sh --image images/ubuntu-server-2604/webide \
    --lower-ref ghcr.io/treadmill-tb/ubuntu-server-2604@sha256:… \
    -o out/webide
```

You can use this command to verify that your image works, by booting it in the
QEMU supervisor. This only works for images that are compatible with the QEMU
supervisor (e.g., not Raspberry Pi OS, that one's an `nbd-netboot` image).

```bash
nix run 'github:treadmill-tb/treadmill#qemu-supervisor-local' -- --image <ref>
```

## Add an image

Create `images/<family>/<name>/` with an `image.json` and a `provision.sh`.

`image.json`:

| Key                      | Meaning                                                           |
|--------------------------|-------------------------------------------------------------------|
| `title`                  | required for the OCI manifest                                     |
| `arch`, `type`           | required; `x86_64`/`aarch64`, `disk`/`sd`                         |
| `base`                   | `../<name>`, a registry reference, or none                        |
| `grow`                   | the size of the new image layer                                   |
| `version`, `description` | OCI manifest metadata; inherited from `base` if unset             |
| `publish`                | ghcr repository name; defaults to `<family>-<name>`, `""` to skip |

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
automatically bump these inputs.

To check the repo layout and image definitions, run `./tools/ci/plan.sh
--check`. Use `--matrix` to emit the CI job matrix.
