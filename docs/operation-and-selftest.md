# Operation and self-test

## Normal operator model

There are two important rules:

1. Any code or UKI change invalidates the old TPM-sealed secret.
2. The first boot after such a change is expected to fall back to OpenWrt.

That first fallback is not a bug. It is the point where the operator performs a manual reseal inside the normal `ZBM` lifecycle.

## Manual lifecycle

The correct manual sequence is:

`login -> zbm-start -> keyload-hook / clevis -> zbm-end`

If reseal is needed, it happens inside the hook during this same pass.

## Automatic lifecycle

The automatic lifecycle is the same path without human interaction:

`boot -> zbm-auto-boot -> zbm-start -> keyload-hook / clevis -> zbm-end`

If automatic unlock works, the donor runtime proceeds directly to `kexec` and the target OS boots.

Before entering `zbm-start`, `zbm-auto-boot` reapplies the runtime network
configuration and waits for an IPv4 address, a default route, link readiness,
and gateway reachability when a gateway is configured. This keeps SSH recovery
available when automatic unlock fails. If the LAN bridge does not become ready,
the runtime can fall back to a physical interface.

`owrt.autostart=y` is only a fallback convenience after this automatic pass has
failed. It does not bypass login, and it calls `zbm-start` only when
`zbm-auto-boot` has left `/run/zbm-autoboot.failed`.

## Common QEMU preparation

All examples below assume:

```bash
./lab/build-openwrt-imagebuilder-uki.sh
./lab/create-ubuntu-zfs-target.sh
```

To start with a fresh TPM and fresh `OVMF_VARS`:

```bash
rm -rf dist/swtpm-multigpu-zfs
```

The QEMU harness is:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
  ./lab/run-qemu-multigpu-zfs.sh
```

SSH during the OpenWrt phase:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
```

## Test: zfs backend

First boot:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
  ./lab/run-qemu-multigpu-zfs.sh
```

Expected behavior:

- automatic unlock fails
- OpenWrt remains reachable over SSH

Manual reseal:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

Inside the hook:

1. answer `yes`
2. enter the ZFS passphrase
3. continue to the `ZBM` TUI
4. press `Enter` to boot Ubuntu

Second boot:

- stop QEMU
- do not remove `dist/swtpm-multigpu-zfs`
- run the same command again

Success criteria:

- serial log shows `kexec_core: Starting new kernel`
- Ubuntu comes up
- SSH on port `10039` reaches Ubuntu

## Test: efi backend

First boot:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
REFIND_OPTIONS='rd.shell=0 console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=efi clevis.pcr_ids=1,4,5,7,9 owrt.host=zbm-lab owrt.ttylogin=0 owrt.autostart=n owrt.auto_bootfs=zbmtest/ROOT/ubuntu' \
  ./lab/run-qemu-multigpu-zfs.sh
```

Manual reseal is the same:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

After reseal, confirm that `efivar` storage exists:

```bash
efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_zbmtest_ROOT_ubuntu -p
efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_zbmtest_ROOT_ubuntu_1 -p
```

If the active encryption root differs, replace `zbmtest_ROOT_ubuntu`
with the sanitized encryption-root tag.

Second boot:

- stop QEMU
- keep `dist/swtpm-multigpu-zfs`
- start the same command again

Success criteria:

- no manual interaction
- automatic handoff to Ubuntu
- SSH on port `10039` reaches Ubuntu

## Test: vfat backend

The current lab can let `zbm-kcl-apply` derive the `vfat` JWE location from
the ESP that loaded the OpenWrt image. An explicit override is still possible;
for the generated lab ESP it is typically the first virtio VFAT disk:

```text
clevis.file_location=/dev/vda:/clevis
```

First boot:

```bash
UKI=dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi \
REFIND_OPTIONS='rd.shell=0 console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=vfat clevis.pcr_ids=1,4,5,7,9 owrt.host=zbm-lab owrt.ttylogin=0 owrt.autostart=n owrt.auto_bootfs=zbmtest/ROOT/ubuntu' \
  ./lab/run-qemu-multigpu-zfs.sh
```

Manual reseal:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

After reseal, confirm files on the chosen VFAT filesystem:

```bash
mkdir -p /mnt/testvfat
mount /dev/vda /mnt/testvfat
ls -l /mnt/testvfat/clevis
umount /mnt/testvfat
```

Expected files:

- `Clevis.zbmtest_ROOT_ubuntu.JWE`
- `Clevis.zbmtest_ROOT_ubuntu.JWE_1`
- `Clevis.zbmtest_ROOT_ubuntu.JWE_4`
- `Clevis.zbmtest_ROOT_ubuntu.JWE_5`
- `Clevis.zbmtest_ROOT_ubuntu.JWE_7`
- `Clevis.zbmtest_ROOT_ubuntu.JWE_9`

If the active encryption root differs, replace `zbmtest_ROOT_ubuntu`
with the sanitized encryption-root tag.

Second boot:

- stop QEMU
- keep `dist/swtpm-multigpu-zfs`
- start the same command again

Success criteria:

- automatic handoff to Ubuntu
- SSH on port `10039` reaches Ubuntu

## What to do if manual zbm-start is refused

If the operator gets:

```text
Automatic ZBM start has not finished yet. Please try again later.
```

then the automatic instance is still running. Wait until it exits and try again. This is expected and is enforced by the global `ZBM` lock.

## Exiting the TUI

In the validated image, `Ctrl-C` in the donor `ZBM` TUI exits back to the
protected OpenWrt system. It no longer drops into a recovery shell, and the
old direct chroot shortcuts are disabled.

## Test: multi-GPU console handoff lab

This repository also has a local QEMU harness for the console handoff problem:
two virtio GPU adapters, three scanouts, and a target Ubuntu root on encrypted
ZFS. The target kernel and `initramfs` are inside the encrypted ZFS root, and
the target-side key is embedded in the target `initramfs`.

Create the target disk once:

```bash
./lab/create-ubuntu-zfs-target.sh
```

Build an overlay UKI from the current installed OpenWrt UKI:

```bash
./lab/build-overlay-uki.sh
```

Boot the lab:

```bash
./lab/run-qemu-multigpu-zfs.sh
```

For an unattended first-boot reseal in the QEMU lab, pass the test key through
a read-only virtio block device instead of typing it on the serial console:

```bash
RESEAL_KEY_FILE=lab/qemu-zfs-target/zbmtest.key ./lab/run-qemu-multigpu-zfs.sh
```

The harness adds only `clevis.reseal_key_blockdev=/dev/vdc` to the `rEFInd`
options. The passphrase is read from the extra read-only virtio disk inside
the guest and is not placed on the kernel command line.

For a follow-up boot that should not expose the reseal key, keep the same
third virtio disk slot populated with a blank image and do not set
`RESEAL_KEY_FILE`:

```bash
truncate -s 512 dist/blank-reseal-key.img
RESEAL_KEY_DRIVE_FILE=dist/blank-reseal-key.img RESEAL_KEY_APPEND_KCL=1 ./lab/run-qemu-multigpu-zfs.sh
```

Keeping the placeholder drive and the same non-secret block-device pointer
preserves the TPM PCR profile created during the reseal boot, while omitting
`RESEAL_KEY_FILE` keeps the real passphrase out of the guest.

The default lab `rEFInd` options include:

```text
owrt.console_rotate=right
owrt.autostart=n
owrt.target_console_rotate=right
owrt.target_fbcon_map=0
owrt.target_kcl_append=""console=tty0 console=ttyS0,115200n8 loglevel=7 ignore_loglevel video=Virtual-1:1280x800@60 video=Virtual-2:1280x800@60 video=Virtual-3:768x1024@60""
```

On the first boot after a UKI or `rEFInd` option change, automatic unlock is
expected to fail because PCR state changed. Press `Enter` on the serial
console, run:

```bash
zbm-start
```

Then answer `yes` and enter the test ZFS passphrase:

```text
zfsbootmenu
```

Press `Enter` in the donor `ZBM` selector. The expected target kernel command
line includes:

```text
fbcon=rotate:1 fbcon=map:0 video=Virtual-1:1280x800@60 video=Virtual-2:1280x800@60 video=Virtual-3:768x1024@60
```

Preserve `dist/swtpm-multigpu-zfs` and boot again with the placeholder drive.
The second boot should automatically decrypt, `kexec` into Ubuntu, and reach
the Ubuntu login prompt without manual input.
