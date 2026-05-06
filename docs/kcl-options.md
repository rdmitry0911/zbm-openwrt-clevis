# Kernel command line options

This page lists the `kcl` parameters currently consumed by the package.

The current validated path reads them from the `options` string of a manual
`rEFInd` `menuentry` in `refind.conf`, not from `refind_linux.conf`.

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
- Default: empty
- Consumer: `zbm-kcl-apply`, `load_key` hook
- Meaning: location of `JWE` files for the `vfat` backend

This is required only for `clevis.store=vfat`.

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

### `owrt.auto_bootfs`

- Value format: ZFS dataset name
- Example: `rpool/ROOT/ubuntu_iu2exh`
- Default: empty
- Consumer: `zbm-kcl-apply`
- Current status: exported into the runtime env but not enforced as a hard
  selector in the current `zbm-auto-boot` implementation

Treat this as reserved future policy, not as a currently guaranteed boot filter.

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
