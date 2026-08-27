# Build and install

## Build prerequisites

The current release image is built from this repository with the OpenWrt
ImageBuilder helper. The host needs:

- `qemu-system-x86_64`
- `OVMF`
- `swtpm` and `swtpm_setup`
- `ukify`
- `refind`
- normal build tools: `git`, `curl`, `make`, `gcc`, `g++`, `python3`, `perl`,
  `awk`, `sed`, `tar`, `cpio`, `gzip`, `xz`, `rsync`, `zstd`, `patch`,
  `objcopy`, `readelf`, `autoconf`, `automake`, `libtoolize`, `pkg-config`,
  `bison`, `flex`, `fakeroot`
- donor glibc tools under `/tmp/openwrt-zbm-rootfs`, or `HOST_TOOL_ROOTFS`
  pointing at an equivalent rootfs
- `tpm_crb.ko` from the matching OpenWrt release build under
  `dist/openwrt-release-build`, or `TPM_CRB_KO=/path/to/tpm_crb.ko`
- the target Ubuntu ZFS disk image used for the lab

## ImageBuilder build flow

The current release image is built with the OpenWrt ImageBuilder helper:

```bash
./lab/build-openwrt-imagebuilder-uki.sh
```

Default output:

- `dist/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis-imagebuilder.efi`

The `vmlinuz-` prefix is intentional. It lets `rEFInd` apply the matching
`refind_linux.conf` stanza when the image is used through rEFInd's Linux
loader path.

Do not leave backup files whose names also start with `vmlinuz-` in the same
directory. `rEFInd` can treat them as bootable Linux images and boot the stale
backup instead of the intended image. Put backups under a subdirectory or rename
them with a non-`vmlinuz-` prefix such as `backup-vmlinuz-...`.

The script downloads the matching OpenWrt release ImageBuilder and SDK, builds
OpenZFS for the SDK kernel, installs the repository overlay, embeds the Clevis
runtime, and produces an unsigned UKI with an empty built-in command line.

The output path can still be overridden explicitly:

```bash
UKI=/path/to/vmlinuz-custom-openwrt-zbm-clevis.efi ./lab/build-openwrt-imagebuilder-uki.sh
```

## Legacy build flow

The legacy full-source OpenWrt builder is still available for reference:

```bash
./lab/build-openwrt-release-uki.sh
```

Default output:

- `dist/openwrt-25.12.4-x86-64-generic-zbm-clevis.efi`

## What is inside the UKI

The UKI contains:

- OpenWrt kernel
- embedded initramfs
- empty built-in cmdline
- OpenWrt OS release metadata
- recovery networking and repair tools, including `apk`, `tcpdump`, `ip`,
  `ss`, `conntrack`, `ethtool`, `iperf3`, `mtr`, `dig`, `nc`, `socat`,
  `arping`, `tracepath`, and `ping`
- wired 10GbE support: Marvell AQtion AQN-107 (`atlantic`, including the
  ThinkStation P620 onboard NIC); Intel `ixgbe`/`ixgbevf` (82598/82599,
  X520/X540/X550), `i40e`/`iavf` (X710/XL710/X722), and `ice` (E810, with
  its DDP firmware)

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
    options "rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.autostart=n owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh"
}
```

Important:

- a manual `menuentry` takes runtime policy from its `options` line in
  `refind.conf`
- a `vmlinuz-*` image loaded through rEFInd's Linux loader path can take
  runtime policy from the adjacent `refind_linux.conf`
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
running `./lab/build-openwrt-imagebuilder-uki.sh`.

## Installation on a real machine

The minimal installation steps are:

1. Copy the built UKI to the machine ESP, for example:

```text
/EFI/OPENWRT/vmlinuz-openwrt-25.12.4-x86-64-generic-zbm-clevis.efi
```

2. Either add a manual `rEFInd` menu entry pointing to that file, or put a
   matching `refind_linux.conf` next to the `vmlinuz-*` image.
3. Put the required runtime parameters into the selected rEFInd policy source.
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
