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

## Common QEMU preparation

All examples below assume:

```bash
cd /home/dima/projects/openwrt
./zbm-openwrt-refresh-runtime.sh
./zbm-openwrt-build-uki.sh
```

To start with a fresh TPM and fresh `OVMF_VARS`:

```bash
rm -rf /home/dima/projects/openwrt/swtpm-zbm-ubuntu-uki
```

The QEMU harness is:

```bash
./zbm-openwrt-qemu-run-zbm-ubuntu-uki-tpm.sh
```

SSH during the OpenWrt phase:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
```

## Test: zfs backend

First boot:

```bash
REFIND_OPTIONS='rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh' \
  ./zbm-openwrt-qemu-run-zbm-ubuntu-uki-tpm.sh
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
- do not remove `swtpm-zbm-ubuntu-uki`
- run the same command again

Success criteria:

- serial log shows `kexec_core: Starting new kernel`
- Ubuntu comes up
- SSH on port `10039` reaches Ubuntu

## Test: efi backend

First boot:

```bash
REFIND_OPTIONS='rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=efi clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh' \
  ./zbm-openwrt-qemu-run-zbm-ubuntu-uki-tpm.sh
```

Manual reseal is the same:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

After reseal, confirm that `efivar` storage exists:

```bash
efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE -p
efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_1 -p
```

Second boot:

- stop QEMU
- keep `swtpm-zbm-ubuntu-uki`
- start the same command again

Success criteria:

- no manual interaction
- automatic handoff to Ubuntu
- SSH on port `10039` reaches Ubuntu

## Test: vfat backend

The validated lab location is the Ubuntu ESP:

```text
clevis.file_location=/dev/vdb1:/clevis
```

First boot:

```bash
REFIND_OPTIONS='rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=vfat clevis.file_location=/dev/vdb1:/clevis clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh' \
  ./zbm-openwrt-qemu-run-zbm-ubuntu-uki-tpm.sh
```

Manual reseal:

```bash
ssh -i /home/dima/.ssh/id_ed25519 -p 10039 root@127.0.0.1
zbm-start
```

After reseal, confirm files on the chosen VFAT filesystem:

```bash
mkdir -p /mnt/testvfat
mount /dev/vdb1 /mnt/testvfat
ls -l /mnt/testvfat/clevis
umount /mnt/testvfat
```

Expected files:

- `Clevis.JWE`
- `Clevis.JWE_1`
- `Clevis.JWE_4`
- `Clevis.JWE_5`
- `Clevis.JWE_7`
- `Clevis.JWE_9`

Second boot:

- stop QEMU
- keep `swtpm-zbm-ubuntu-uki`
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
