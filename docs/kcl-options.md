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

This is a global enable switch, not a dataset wildcard. When it is `yes`, the
hook will handle only:

- the encryption root of `owrt.auto_bootfs` or current `BOOTFS`
- encryption roots explicitly marked with a local
  `latchset.clevis:decrypt=yes` property

Other locked encryption roots are skipped without falling through to the normal
password prompt during this Clevis-controlled boot path. This prevents unrelated
pools from asking for reseal or passphrases while the selected boot environment
is being recovered.

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
- Meaning: preferred boot environment and primary Clevis unlock target

When this is set, the Clevis hook treats the encryption root of this boot
environment as the primary automatic unlock/reseal target. Other encrypted
datasets are ignored unless they carry their own local
`latchset.clevis:decrypt=yes` property.

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

### `owrt.target_console_font`

- Alias: `owrt.target_fbcon_font`
- Value format: Linux `fbcon=font:` font name, for example `TER16x32`
- Default: empty
- Consumer: `zbm-kcl-apply`, donor `ZFSBootMenu` runtime
- Meaning: appends `fbcon=font:<value>` to the target Linux command line when
  donor `ZFSBootMenu` loads the selected kernel and `initramfs` with `kexec`

This depends on the target Linux kernel having the requested font built in.
Ubuntu's generic kernel on the current host includes `TER16x32`.

### `owrt.console_font`

- Alias: `owrt.fbcon_font`
- Values: `auto`, `largest`, `none`, a bundled font name such as `ter-v32b`,
  or an absolute `.psf` path
- Default: `auto`
- Consumer: `zbm-kcl-apply`
- Meaning: loads a Terminus console font for the OpenWrt framebuffer console

`auto` tries the bundled fonts from largest to smallest and keeps the largest
font that leaves at least 110 text columns. On a 3840px-wide framebuffer this
selects `ter-v32b.psf`, the largest bundled font. Use `largest` to force that
font regardless of console width.

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

### `owrt.autostart`

- Values: `y`, `n` (`yes/no`, `1/0`, `true/false`, and `on/off` are also accepted)
- Default: `n`
- Consumer: `zbm-kcl-apply`, `/etc/profile.d/zbm-autostart.sh`
- Meaning:
  - `y`: after the automatic decrypt/start attempt fails and an operator logs
    in interactively, automatically calls `zbm-start`
  - `n`: after login, leave the operator at the OpenWrt shell

This does not bypass login. Use `owrt.ttylogin=0` separately only for
debug-only local console autologin. If the background `zbm-auto-boot` pass is
still running when the shell profile is loaded, the autostart hook waits up to
60 seconds. It calls `zbm-start` only when that pass has left the
`/run/zbm-autoboot.failed` marker.

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
- Meaning: primary wired OpenWrt `wan` network mode

### `owrt.net_ifname`

- Default: interface matched by `owrt.net_macaddr`, first wired Ethernet
  interface discovered at runtime, then `eth0` as fallback
- Consumer: `zbm-kcl-apply`
- Meaning: primary wired interface name for the generated OpenWrt `wan`
  interface

### `owrt.net_macaddr`

- Aliases: `owrt.wan_macaddr`
- Default: empty
- Consumer: `zbm-kcl-apply`, `zbm-network-up`
- Meaning: primary wired `wan` interface MAC address

When this option is set, the runtime selects the wired Ethernet interface with
the matching MAC address for `wan`. This is preferred over automatic
first-interface discovery and is useful on systems with multiple Ethernet
adapters whose `ethN` names can change across boots.

The parser accepts lower-case or upper-case colon-separated MAC addresses and
hyphen-separated MAC addresses.

The recovery image does not expose a `lan` interface or `br-lan` bridge. A
single wired adapter is still treated as `wan`; DHCP service is disabled on
both `wan` and `wwan`.

When both uplinks have IPv4 addresses, `zbm-network-up` also installs
source-based routing rules for the local OpenWrt runtime. This keeps SSH
replies sourced from the Wi-Fi address on `wwan` going back out through Wi-Fi
instead of following the primary Ethernet default route. No multi-WAN daemon is
required for this recovery behavior.

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
- Consumer: `zbm-kcl-apply`, `zbm-network-up`
- Meaning: preferred STA interface name

If OpenWrt `netifd` does not create the STA interface, `zbm-network-up` uses
this name for its manual `iw phy ... interface add ... type managed` fallback.

### `owrt.wifi_encryption`

- Default: `psk2`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt Wi-Fi encryption mode

### `owrt.wifi_band`

- Default: `2g`
- Values: `2g`, `5g`, `6g`, `60g`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt radio band for the generated STA radio

### `owrt.wifi_channel`

- Default: `auto`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt radio channel

### `owrt.wifi_htmode`

- Default: `HT20`
- Consumer: `zbm-kcl-apply`
- Meaning: OpenWrt radio HT mode

### `owrt.wifi_country`

- Default: empty
- Consumer: `zbm-kcl-apply`, `zbm-network-up` fallback
- Meaning: optional regulatory country code for OpenWrt and manual
  `wpa_supplicant` fallback

## Common non-package kernel arguments

The validated lab also commonly used:

- `rd.shell=0`
- `console=tty0`
- `console=ttyS0,115200n8`
- `loglevel=8`
- `ignore_loglevel`

These are not package-specific policy keys. They influence the kernel,
initramfs, and console behavior rather than the package contract itself.
