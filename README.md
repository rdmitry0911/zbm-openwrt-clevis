# zbm-openwrt-clevis

OpenWrt-based boot runtime for unlocking an encrypted ZFS root with `clevis` and then booting the target Linux system through a donor `ZFSBootMenu` runtime.

Current validated lab chain:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> load-key hook / clevis -> donor ZBM runtime -> kexec -> Ubuntu on encrypted ZFS`

This repository contains:

- reference QEMU and UKI helper scripts from the working lab
- the current `load_key` hook used for `clevis`
- documentation for the boot model, threat model, kernel command line contract, operator interaction, build flow, installation, and self-test

The `lab/` scripts are snapshots from the validated OpenWrt build tree. They are kept here for reference and reuse, but the validated execution still happened inside the OpenWrt source tree with its `build_dir`, `staging_dir`, kernel, and package outputs present.

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
- [docs/threat-model.md](docs/threat-model.md): assumptions, protected assets, defended and non-defended threats
- [docs/kcl-options.md](docs/kcl-options.md): full list of `kcl` options consumed by the package
- [docs/build-and-install.md](docs/build-and-install.md): build flow, UKI generation, `rEFInd` setup, installation notes
- [docs/operation-and-selftest.md](docs/operation-and-selftest.md): exact QEMU test procedure and expected operator actions
- [docs/jwe-backends.md](docs/jwe-backends.md): validated `JWE` storage backends: `zfs`, `efi`, `vfat`
- [lab/build-uki.sh](lab/build-uki.sh): UKI build helper
- [lab/refind-esp.sh](lab/refind-esp.sh): `rEFInd` ESP generator for the lab
- [lab/run-qemu-uki-tpm.sh](lab/run-qemu-uki-tpm.sh): QEMU + OVMF + swtpm harness
- [hooks/load_key_zfs_clevis_hook.sh](hooks/load_key_zfs_clevis_hook.sh): current `clevis` load-key hook

## Quick start

The reference lab assumes:

- an OpenWrt build tree at `/home/dima/projects/openwrt`
- a target Ubuntu disk image at `/home/dima/projects/zfsbootmenu/lab.ubuntu-iso/ubuntu-zfs-target.raw`
- `OVMF`, `swtpm`, `qemu-system-x86_64`, `ukify`, `refind`, and the OpenZFS build outputs already available on the host

Build the current UKI:

```bash
cd /home/dima/projects/openwrt
./zbm-openwrt-refresh-runtime.sh
./zbm-openwrt-build-uki.sh
```

Boot the lab with the `zfs` backend:

```bash
cd /home/dima/projects/openwrt
rm -rf swtpm-zbm-ubuntu-uki
REFIND_OPTIONS='rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh' \
  ./zbm-openwrt-qemu-run-zbm-ubuntu-uki-tpm.sh
```

On the first boot after a rebuild:

1. Auto boot falls back to OpenWrt because the old TPM-sealed secret no longer matches the new PCR state.
2. Log in over SSH and run manual `zbm-start`:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

3. Inside the hook answer `yes` to reseal and enter the ZFS passphrase.
4. In the `ZBM` TUI press `Enter` to boot Ubuntu.
5. Reboot without deleting `swtpm-zbm-ubuntu-uki`.

On the next cold boot, the same path should go to Ubuntu automatically.

The full procedure, including `efi` and `vfat` backends, is documented in [docs/operation-and-selftest.md](docs/operation-and-selftest.md).

For real machines, use a manual `rEFInd` `menuentry` with an `options` line in
`refind.conf`. The current UKI flow does not consume `refind_linux.conf`.

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
