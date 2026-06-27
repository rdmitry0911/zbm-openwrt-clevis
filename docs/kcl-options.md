# Kernel command line options

This page lists the `kcl` parameters currently consumed by the package.

The current validated path reads them from `rEFInd`. When the OpenWrt image is
named with a `vmlinuz-` prefix, `rEFInd` applies the adjacent
`refind_linux.conf`; manual `menuentry` options in `refind.conf` are also
supported.

## Parsing and quoting

Rules:

- keep the final `options` string on one logical line
- values with spaces must be quoted for `rEFInd`
- when a value itself needs quotes inside `options`, double the quotes

Example for an SSH key:

```conf
owrt.ssh_pubkey=""ssh-ed25519 AAAAC3... comment""
```

## Boot and clevis policy

### `clevis.decrypt`

- Alias: `owrt.clevis_decrypt`
- Values: `yes`, `no`
- Default: `yes`
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: enables the `clevis`-based automatic unlock path

### `clevis.store`

- Alias: `owrt.clevis_store`
- Values: `zfs`, `efi`, `vfat`
- Default:
  - if unset and `latchset.clevis:jwe` exists on the encryption root, use `zfs`
  - otherwise fall back to `vfat`
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: selects where the sealed `JWE` is stored

Current backend naming behavior:

- `zfs`: properties are naturally scoped to the active encryption root
- `efi`: variable names are derived from the active encryption root
- `vfat`: file names are derived from the active encryption root

For `efi` and `vfat`, the active encryption-root name is sanitized by
replacing non `[A-Za-z0-9_.-]` characters with `_`.

### `clevis.file_location`

- Alias: `owrt.clevis_file_location`
- Value format: `DEVICE:SUBDIRECTORY`
- Example: `/dev/vdb1:/clevis`
- Default: for `clevis.store=vfat`, `./jwe` next to the loaded `vmlinuz-*`
  image, expressed as `DEVICE:/path/to/image-directory/jwe`
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: location of `JWE` files for the `vfat` backend

This is an override for `clevis.store=vfat`. If it is omitted,
`zbm-kcl-apply` uses `LoaderDevicePartUUID` to identify the ESP that loaded the
image and `LoaderImageIdentifier` to identify the loaded `vmlinuz-*` path, then
derives `DEVICE:<image-directory>/jwe`. If `LoaderImageIdentifier` is not
available, it falls back to the command-line `BOOT_IMAGE` value and finally to
the adjacent `refind_linux.conf` directory on the ESP.

### `clevis.pcr_ids`

- Alias: `owrt.clevis_pcr_ids`
- Value format: comma-separated PCR list
- Example: `1,4,5,7,9`
- Default: `1,4,5,7,9`
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: PCR set used when sealing or resealing the secret

For the currently validated project configuration, `1,4,5,7,9` is the intended
set. In this chain it covers the relevant external `rEFInd` `kcl`, so changing
those arguments must break automatic unlock until a new reseal is done.

### `clevis.reseal_key_fwcfg`

- Alias: `owrt.clevis_reseal_key_fwcfg`
- Value format: QEMU fw_cfg item name
- Example: `opt/zbm/reseal-key`
- Default: empty
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: lab-only unattended reseal source for QEMU tests

When this is set, the hook reads the passphrase from
`/sys/firmware/qemu_fw_cfg/by_name/<value>/raw`, verifies it with
`zfs load-key -n`, and only then reseals the Clevis JWE for the current PCR
state. The passphrase itself is not placed on the kernel command line.

Do not use this as a normal production secret-delivery mechanism. It exists so
the QEMU e2e lab can perform the expected first-boot reseal after a UKI or
`rEFInd` option change, then verify the following cold boot without manual
input.

### `clevis.reseal_key_blockdev`

- Alias: `owrt.clevis_reseal_key_blockdev`
- Value format: block device path
- Example: `/dev/vdc`
- Default: empty
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: lab-only unattended reseal source for QEMU tests

When this is set, the hook reads the first small block from the device, strips
zero padding, verifies the resulting passphrase with `zfs load-key -n`, and
only then reseals the Clevis JWE for the current PCR state. The passphrase
itself is not placed on the kernel command line.

This is the default unattended reseal path used by
`lab/run-qemu-multigpu-zfs.sh` when `RESEAL_KEY_FILE` is set.

### `owrt.auto_bootfs`

- Value format: ZFS dataset name
- Example: `rpool/ROOT/ubuntu_iu2exh`
- Default: empty
- Consumer: `zbm-kcl-apply`
- Current status: exported into the runtime env but not enforced as a hard
  selector in the current `zbm-auto-boot` implementation

Treat this as reserved future policy, not as a currently guaranteed boot filter.

### `owrt.console_rotate`

- Alias: `owrt.fbcon_rotate`
- Values: `normal`, `right`, `inverted`, `left`, or numeric `0`, `1`, `2`, `3`
- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: rotates the OpenWrt framebuffer console by writing the normalized
  value into `/sys/class/graphics/fbcon/rotate_all` when available, falling
  back to `/sys/class/graphics/fbcon/rotate`

The named values map to Linux fbcon rotation values:

- `normal`: `0`
- `right`: `1`
- `inverted`: `2`
- `left`: `3`

### `owrt.target_console_rotate`

- Alias: `owrt.target_fbcon_rotate`
- Values: `normal`, `right`, `inverted`, `left`, or numeric `0`, `1`, `2`, `3`
- Default: empty
- Consumer: `zbm-kcl-apply`, donor `ZFSBootMenu` runtime
- Meaning: appends `fbcon=rotate:<value>` to the target Linux command line
  when donor `ZFSBootMenu` loads the selected kernel and `initramfs` with
  `kexec`

This does not move the target kernel or `initramfs` out of the encrypted ZFS
root. It only alters the command line used for the final handoff.

### `owrt.target_fbcon_map`

- Value format: Linux `fbcon=map:` value
- Default: empty
- Consumer: `zbm-kcl-apply`, donor `ZFSBootMenu` runtime
- Meaning: appends `fbcon=map:<value>` to the target Linux command line

Use this when a multi-GPU system needs the Linux console bound to a specific
framebuffer after `kexec`.

### `owrt.target_kcl_append`

- Value format: quoted kernel command line fragment
- Default: empty
- Consumer: `zbm-kcl-apply`, donor `ZFSBootMenu` runtime
- Meaning: tokenizes and appends the supplied fragment to the target Linux
  command line after reading the selected boot environment's normal command
  line

Example:

```conf
owrt.target_kcl_append=""console=tty0 console=ttyS0,115200n8 video=DP-1:1920x1080@60""
```

### `owrt.target_kcl_override`

- Value format: quoted full kernel command line
- Default: empty
- Consumer: `zbm-kcl-apply`, donor `ZFSBootMenu` runtime
- Meaning: replaces the selected boot environment's normal command line before
  donor `ZFSBootMenu` appends required values such as `spl_hostid`,
  `noresume`, and the optional target console parameters above

Use this only as a debug escape hatch. For the multi-GPU console case,
`owrt.target_kcl_append`, `owrt.target_console_rotate`, and
`owrt.target_fbcon_map` are narrower and safer.

## Access control

### `owrt.root_password_hash`

- Value format: full crypt hash
- Example: `$6$...`
- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: replaces the locked default `root` password with the supplied hash

Without this option, `root` remains locked in the static image.

### `owrt.ssh_pubkey`

- Value format: one public key line
- Example: `ssh-ed25519 AAAA... comment`
- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: appends the key to:
  - `/etc/dropbear/authorized_keys`
  - `/root/.ssh/authorized_keys`

The current parser strips a single pair of wrapping double quotes after `rEFInd`
parsing.

### `owrt.ttylogin`

- Values: `1`, `0`
- Default: `1`
- Consumer: `zbm-kcl-apply`, `/usr/libexec/login.sh`
- Meaning:
  - `1`: normal password login on `ttyS0`, `tty1`, `hvc0`
  - `0`: `login -f root` autologin on local console

`owrt.ttylogin=0` is insecure and should be treated as a debug-only mode.

## Host identity and notifications

### `owrt.host`

- Fallback alias: `clevis.host`
- Default: `openwrt-zbm`
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning:
  - sets OpenWrt hostname
  - provides a host label for notifications

### `clevis.CHAT_ID`

- Default: empty
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: Telegram chat ID used for auto-failure notifications

### `clevis.API_TOKEN`

- Default: empty
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: Telegram bot token used for auto-failure notifications

Telegram messages are sent only when automatic unlock fails. They include:

- failure reason
- host name
- detected IP address
- configured PCR set
- per-PCR `OK/FAIL` status
- failed PCR list

## Networking

### `owrt.net_proto`

- Values: `dhcp`, `static`
- Default: `dhcp`
- Consumer: `zbm-kcl-apply`
- Meaning: primary OpenWrt network mode

### `owrt.net_ifname`

- Default: first non-loopback interface discovered at runtime, then `eth0` as fallback
- Consumer: `zbm-kcl-apply`
- Meaning: primary wired interface name for the generated OpenWrt `lan`
  interface

### `owrt.net_ipaddr`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: static IPv4 address

Used only when `owrt.net_proto=static`.

### `owrt.net_netmask`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: static netmask

Used only when `owrt.net_proto=static`.

### `owrt.net_gateway`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: static default gateway

Used only when `owrt.net_proto=static`.

### `owrt.net_dns`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: DNS list for static networking

The current parser accepts comma-separated or space-separated items.

## Wi-Fi

### `owrt.wifi_ssid`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: enables Wi-Fi client mode when set

If empty, generated Wi-Fi config stays disabled.

### `owrt.wifi_psk`

- Default: empty
- Consumer: `zbm-kcl-apply`
- Meaning: Wi-Fi PSK

### `owrt.wifi_device`

- Default: `radio0`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt `wifi-device` section name

### `owrt.wifi_ifname`

- Default: `wlan0`
- Consumer: `zbm-kcl-apply`
- Meaning: interface name label stored in runtime env

### `owrt.wifi_encryption`

- Default: `psk2`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt Wi-Fi encryption mode

## Common non-package kernel arguments

The validated lab also commonly used:

- `rd.shell=0`
- `console=tty0`
- `console=ttyS0,115200n8`
- `loglevel=8`
- `ignore_loglevel`

These are not package-specific policy keys. They influence the kernel,
initramfs, and console behavior rather than the package contract itself.
