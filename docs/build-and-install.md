# Build and install

## Build prerequisites

The reference implementation was built in an OpenWrt `x86_64` tree with:

- `qemu-system-x86_64`
- `OVMF`
- `swtpm` and `swtpm_setup`
- `ukify`
- `refind`
- an OpenZFS source tree and built userspace/kernel modules
- the target Ubuntu ZFS disk image used for the lab

The runtime also expects the local OpenWrt tree to contain:

- the donor `ZFSBootMenu` runtime
- the current `load_key_zfs_clevis_hook.sh`
- the OpenWrt staging tree and kernel build outputs

The helper scripts stored in this repository under `lab/` are reference copies. They assume the surrounding OpenWrt build tree exists, or that equivalent paths are supplied through environment variables.

## Build flow

Reference commands:

```bash
cd /home/dima/projects/openwrt
./zbm-openwrt-qemu-configure.sh
./zbm-openwrt-refresh-runtime.sh
./zbm-openwrt-build-uki.sh
```

Outputs:

- `bin/targets/x86/64/openwrt-x86-64-generic-initramfs-kernel.bin`
- `bin/targets/x86/64/openwrt-x86-64-generic-zbm.efi`

The UKI build is done by [lab/build-uki.sh](../lab/build-uki.sh).

## What is inside the UKI

The UKI contains:

- OpenWrt kernel
- embedded initramfs
- empty built-in cmdline
- OpenWrt OS release metadata

Operational policy is therefore carried by `rEFInd` options.

## rEFInd setup

The lab helper [lab/refind-esp.sh](../lab/refind-esp.sh) creates an ESP image with:

- `BOOTX64.EFI` from `rEFInd`
- `refind.conf`
- a manual entry for `OPENWRT.EFI`

Typical generated entry:

```conf
menuentry "OpenWrt ZBM UKI" {
    ostype Linux
    loader /EFI/OPENWRT/OPENWRT.EFI
    options "rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh"
}
```

Important:

- the validated UKI path uses a manual `menuentry` in `refind.conf`
- in that mode, `rEFInd` takes runtime policy from the `options` line in `refind.conf`
- `refind_linux.conf` is not used by this manual UKI entry
- keep the `options` string on a single logical line

If you want to pass a public SSH key through `rEFInd`, quote it inside the
`options` string, for example:

```conf
owrt.ssh_pubkey=""ssh-rsa AAAAB3... comment""
```

If you want a console and serial login password, pass a valid SHA-512 hash:

```conf
owrt.root_password_hash=$6$...
```

The current build no longer bakes in the builder host SSH key by default. If a
default key is desired at build time, set `DEFAULT_SSH_PUBKEY_FILE` before
running `zbm-openwrt-refresh-runtime.sh`.

## Installation on a real machine

The minimal installation steps are:

1. Copy `openwrt-x86-64-generic-zbm.efi` to the machine ESP, for example:

```text
/EFI/OPENWRT/OPENWRT.EFI
```

2. Add a manual `rEFInd` menu entry pointing to that file.
3. Put the required runtime parameters into the `options` line.
4. Ensure the target system layout matches the assumptions:
   - encrypted ZFS root
   - a valid keylocation on the encryption root
   - donor runtime able to see the boot environment and kernels

## Notes about the lab harness

For `efi`-backed `JWE` storage, preserving `OVMF_VARS.fd` between boots is mandatory. The reference QEMU harness does not overwrite `OVMF_VARS.fd` after the first initialization.

For `vfat`-backed storage, the file location is passed as:

```text
clevis.file_location=/dev/vdb1:/clevis
```

The syntax is:

```text
DEVICE:SUBDIRECTORY
```

where `SUBDIRECTORY` is relative to the root of the mounted filesystem.
