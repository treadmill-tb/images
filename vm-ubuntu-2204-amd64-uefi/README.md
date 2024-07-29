# Building and Running a Custom Ubuntu VM Image with Nix

## Steps

Either build the Treadmill image:

```bash
$ nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix {}'
```

Or build a script to run the image in a QEMU VM (KVM-acceleration
enabled by default, pass `--arg enableKVM false` to `nix-build` to
disable):

```bash
$ nix-build run-qemu-vm.nix
$ ./result/bin/run-qemu-vm.sh
```

## Additional Notes

- To modify the image, edit `default.nix`
- To change VM runtime parameters, edit `run-qemu-vm.nix`
