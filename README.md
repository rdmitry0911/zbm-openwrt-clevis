# zbm-openwrt-clevis

OpenWrt-based boot runtime for unlocking an encrypted ZFS root with `clevis` and then booting the target Linux system through a donor `ZFSBootMenu` runtime.

Current validated lab chain:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> zbm-start -> load-key hook / clevis -> donor ZBM runtime -> kexec -> Ubuntu on encrypted ZFS`

This repository contains:

- the current ImageBuilder-based OpenWrt UKI build helper
- reference QEMU and ESP helper scripts from the working lab
- the current `load_key` hook used for `clevis`
- documentation for the boot model, threat model, kernel command line contract, operator interaction, build flow, installation, and self-test

The default build flow now runs from this repository with OpenWrt
ImageBuilder. Legacy scripts that assume a full OpenWrt source tree are kept
only as reference material.

## Motivation

The original need was a bootloader that could autonomously boot a system from
an encrypted ZFS root while still preserving a meaningful trust decision about
when it is safe to release the decryption key.

`ZFSBootMenu` already solves the ZFS boot problem well, but by itself it
expects a human to type the key. For a remote machine that is not enough: it
does not guarantee that the operator is typing the key into a trusted
environment. A measured trust decision is needed first. That is where
`clevis` enters the design.

At the same time, `ZFSBootMenu` is a boot environment, not a full operating
system. Even if `clevis` says the measured state is trusted, a hostile person
at the console could still interfere while the operator is typing the key.
`ZFSBootMenu` does not try to prevent that. The project therefore places a
minimal but complete OpenWrt system in front of it: OpenWrt can require a real
password-protected login before the operator reaches the manual unlock path.

The result is a split design:

- `rEFInd` configures the boot runtime through `kcl`
- `zbm-openwrt-clevis` decides whether the key may be recovered automatically
- if automatic recovery is not trusted anymore, the operator is notified and
  can choose whether to log in and reseal manually
- the target OS is booted only after the encrypted ZFS root has been unlocked

## Repo layout

- [docs/architecture.md](docs/architecture.md): boot model, relation to `rEFInd`, runtime components, user interaction
- [docs/use-cases.md](docs/use-cases.md): practical remote-server and unattended-laptop scenarios
- [docs/threat-model.md](docs/threat-model.md): assumptions, protected assets, defended and non-defended threats
- [docs/kcl-options.md](docs/kcl-options.md): full list of `kcl` options consumed by the package
- [docs/build-and-install.md](docs/build-and-install.md): build flow, UKI generation, `rEFInd` setup, installation notes
- [docs/operation-and-selftest.md](docs/operation-and-selftest.md): exact QEMU test procedure and expected operator actions
- [docs/jwe-backends.md](docs/jwe-backends.md): validated `JWE` storage backends: `zfs`, `efi`, `vfat`
- [lab/build-openwrt-imagebuilder-uki.sh](lab/build-openwrt-imagebuilder-uki.sh): current release UKI build helper
- [lab/build-overlay-uki.sh](lab/build-overlay-uki.sh): fast overlay rebuild helper for lab iterations
- [lab/refind-esp.sh](lab/refind-esp.sh): `rEFInd` ESP generator for the lab
- [lab/create-ubuntu-zfs-target.sh](lab/create-ubuntu-zfs-target.sh): local encrypted ZFS target disk creator
- [lab/run-qemu-multigpu-zfs.sh](lab/run-qemu-multigpu-zfs.sh): current QEMU + OVMF + swtpm harness
- [hooks/load_key_zfs_clevis_hook.sh](hooks/load_key_zfs_clevis_hook.sh): current `clevis` load-key hook

## Quick start

The reference lab assumes:

- this repository is the working directory
- `OVMF`, `swtpm`, `qemu-system-x86_64`, `ukify`, `refind`, and normal build tools are installed on the host
- donor glibc tools are available under `/tmp/openwrt-zbm-rootfs`, or `HOST_TOOL_ROOTFS` points at an equivalent rootfs
- `tpm_crb.ko` is available from the matching OpenWrt release build under `dist/openwrt-release-build`, or `TPM_CRB_KO` points at it

Build the current UKI:

```bash
./lab/build-openwrt-imagebuilder-uki.sh
```

Default output:

```text
dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi
```

Create the local QEMU target disk once:

```bash
./lab/create-ubuntu-zfs-target.sh
```

Boot the lab with the `zfs` backend:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
  ./lab/run-qemu-multigpu-zfs.sh
```

On the first boot after a UKI or `rEFInd` option change, automatic boot is
expected to fall back to OpenWrt because the old TPM-sealed secret no longer
matches the new PCR state.

With the default `owrt.autostart=n`, log in over SSH or console and run:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

With `owrt.autostart=y`, a successful interactive login automatically calls
`zbm-start` only after the background automatic decrypt/start attempt has
finished and left `/run/zbm-autoboot.failed`. It does not bypass login and it
does not run while `zbm-auto-boot` is still active.

Inside the hook, answer `yes` to reseal and enter the ZFS passphrase. In the
`ZBM` TUI, press `Enter` to boot Ubuntu. On the next cold boot with the same
TPM state and `rEFInd` options, the path should go to Ubuntu automatically.

For unattended first-boot reseal in the QEMU lab:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
RESEAL_KEY_FILE=lab/qemu-zfs-target/zbmtest.key \
  ./lab/run-qemu-multigpu-zfs.sh
```

The full procedure, including `efi` and `vfat` backends, is documented in [docs/operation-and-selftest.md](docs/operation-and-selftest.md).

Current runtime quality-of-life additions in the validated image:

- `blkid`, `blockdev`, `losetup`, `mount-utils`, `wipefs`
- `fdisk`, `sfdisk`, `cfdisk`, `parted`, `partx`
- `dosfstools`, `e2fsprogs`, `f2fs-tools`, `btrfs-progs`, `lvm2`
- `nvme-cli`, `smartmontools`, `hdparm`, `swap-utils`
- `mc`
- `nano-plus`

Current operator interaction in the donor `ZBM` runtime:

- `Ctrl-C` exits the TUI back to the protected OpenWrt system
- the old shell escape and direct chroot shortcuts are intentionally disabled

For real machines, put runtime policy in the `rEFInd` path that actually loads
the image:

- for a manual `menuentry`, use the `options` line in `refind.conf`
- for a `vmlinuz-*` image loaded through rEFInd's Linux loader path, use the
  adjacent `refind_linux.conf`

Do not leave backup files whose names also start with `vmlinuz-` next to the
active image. `rEFInd` can treat them as bootable Linux images.

If you put security-relevant policy into external `rEFInd` kernel command line
parameters, read [docs/threat-model.md](docs/threat-model.md) and
[docs/kcl-options.md](docs/kcl-options.md) first. In the currently validated
configuration, `clevis.pcr_ids=1,4,5,7,9` covers the relevant external
`rEFInd` `kcl`, so changing those arguments is expected to stop automatic boot
until a new reseal is performed.

One practical bonus of this split model is that the target kernel,
`initramfs/initrd`, and the embedded target-side decryption material all live
inside the encrypted ZFS root. Updating the target system can therefore change
`vmlinuz` or `initramfs` without forcing a new manual unlock, as long as the
measured OpenWrt boot runtime itself did not change.
