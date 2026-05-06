# Threat model

## Scope

This package is a measured pre-boot runtime for unlocking an encrypted ZFS
root and then booting the target operating system through a donor
`ZFSBootMenu` runtime.

Validated chain:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> zbm-start -> load-key hook / clevis -> donor ZBM runtime -> kexec -> target OS`

## Motivation for the trust boundary

The key design problem is not only how to boot encrypted ZFS, but how to avoid
typing the decryption key into an environment whose trust level is unknown.

`ZFSBootMenu` already knows how to boot encrypted ZFS systems, but by itself it
expects a human to provide the passphrase. On a remote machine that is not a
sufficient trust model. The operator first needs confidence that the current
boot environment is still the same environment that was previously inspected
and trusted.

That is why `clevis` and TPM measurements are introduced. They provide the
automatic trust check before the clear-text key is released.

That is also why OpenWrt is placed in front of donor `ZFSBootMenu`. `ZFSBootMenu`
is not a full operating system and does not try to prevent a person at the
console from interfering while the operator is typing the key. OpenWrt is used
as the minimal complete runtime that can require normal authenticated access
before the manual fallback path is exposed.

## Protected assets

The design tries to protect:

- the clear-text ZFS passphrase or key material
- the decision whether the target system is allowed to boot automatically
- the integrity of the measured OpenWrt UKI used as the policy runtime
- the integrity of the TPM-sealed `JWE` used for later automatic boots
- operator access to the fallback OpenWrt runtime

## Guarded perimeter

The guarded perimeter is the measured `zbm-openwrt-clevis` runtime itself and
the boot context that launches it.

Its responsibility is limited and explicit:

- obtain the key that unlocks the encrypted ZFS root
- obtain it automatically only if the measured environment is still trusted
- refuse automatic unlock when that trust decision no longer holds
- notify the operator and wait for a manual decision whether to continue

The runtime is allowed to see the encrypted form of the key material, but not
to turn it into clear-text key material unless the current measured state still
matches the manually approved state from the last successful reseal.

## Trusted components and assumptions

The current model trusts:

- firmware, TPM, and the PCR event chain
- `rEFInd` as the top-level loader
- the OpenWrt UKI image itself
- the donor `ZFSBootMenu` runtime shipped inside the UKI
- the OpenZFS userspace and kernel modules staged into the UKI
- the local operator during the manual reseal path

It also assumes:

- the target root is really encrypted with ZFS native encryption
- the encryption root has a valid `keylocation=file://...`
- the selected `JWE` backend is persistent across boots
- the TPM state is preserved across boots after the first successful reseal

## Security goals

The intended goals are:

- automatic boot should succeed only when the expected measured boot state is present
- after any relevant boot-image change, the old sealed secret should stop working
- fallback to OpenWrt must not expose a passwordless shell
- manual and automatic `ZBM` entry must not run concurrently
- normal boot should stay read-only except for the narrow reseal write path

## Threats the design tries to resist

### Modified UKI or boot path

If the UKI or other measured boot components change, the old TPM-sealed secret
should stop decrypting. This is the normal reason for the first fallback to
OpenWrt after a rebuild.

### Tampered `JWE` storage

The `JWE` may be stored in:

- ZFS properties
- EFI variables
- a VFAT filesystem

These locations are not trusted by themselves. The actual gate is still TPM
policy. A modified stored `JWE` should fail `clevis decrypt` or fail `zfs
load-key -n` verification.

### Replay of stale secrets

An old secret bound to old PCR values should stop working after relevant boot
changes, forcing a manual reseal.

### Modified external `rEFInd` arguments

In the current validated configuration, `clevis.pcr_ids=1,4,5,7,9` covers the
relevant external `rEFInd` `kcl` used to configure `zbm-openwrt-clevis`.

That means:

- changing those arguments changes the measured state
- automatic boot must stop
- the operator must decide whether to enter the key manually and reseal again

### Unauthorized access to fallback OpenWrt

The image now defaults to:

- `ttylogin=1`
- locked `root` in the static image

Access becomes possible only after a valid password hash or SSH key is applied
from `kcl`.

In the validated image, leaving the donor `ZBM` TUI by `Ctrl-C` returns to the
protected OpenWrt system rather than exposing a recovery shell.

### Manual/automatic race

`zbm-auto-boot` and manual `zbm-start` share the same lock. Manual `zbm-start`
refuses to start while the automatic phase is still active.

## Threats not solved by this package

The package does not try to solve:

- compromise of firmware or the TPM itself
- kernel-level compromise inside OpenWrt or the target OS after boot
- physical attacks with full control of RAM while the machine is already running
- operator compromise after the operator has valid root password or valid SSH key
- confidentiality of Telegram notifications
- secure delivery of secrets if they are intentionally placed in insecure `kcl`
- compromise of the target operating system after control has already passed to
  the target kernel and `initramfs/initrd`

## Important `kcl` caveat

This package takes a large part of its policy from external `rEFInd` kernel
command line parameters. Examples:

- root password hash
- SSH public key
- network mode
- `clevis` backend selection
- Telegram notification settings

That means the protection of these values depends on the PCR set you bind in
`clevis.pcr_ids`.

The validated lab often used:

`clevis.pcr_ids=1,4,5,7,9`

For the currently validated chain in this repository, that set is the intended
and validated policy set. In this configuration it covers the relevant measured
surface, including the external `rEFInd` command line used to configure the
OpenWrt UKI runtime.

Practical consequence:

- changing the arguments passed by `rEFInd` changes the measured state
- after such a change, the previously sealed secret must stop decrypting
- automatic boot must stop working until a manual reseal is performed

This is the expected protection model for the current project.

## Why target OS updates do not force a manual unlock

The target kernel, target `initramfs/initrd`, and target-side decryption
content all live inside the encrypted ZFS root.

As long as the measured OpenWrt runtime and its trusted launch context do not
change, updating the target operating system does not by itself require another
manual password entry. Automatic boot can continue because the trust gate is
the measured `zbm-openwrt-clevis` runtime, not the changing contents inside
the already protected encrypted root.

## Read-only vs read-write boundary

The normal path is intended to stay read-only.

The package flips to read-write only in a narrow manual reseal case:

- backend is `clevis.store=zfs`
- the hook is already in manual phase
- the operator explicitly approved reseal
- only the refreshed `latchset.clevis:*` properties are written

After that write, the pool is returned to read-only import mode.

## Telegram notifications

If `clevis.CHAT_ID` and `clevis.API_TOKEN` are present, the hook sends a
Telegram message only on automatic unlock failure, with:

- failure reason
- hostname
- current IP address
- configured PCR set
- per-PCR status
- failed PCR list

This is operational telemetry, not a security boundary. Anyone with access to
the target chat can observe those messages.

## Recommended operational policy

- Keep `owrt.ttylogin=1`.
- Keep `root` locked in the base image and set `owrt.root_password_hash` only
  when you actually want console access.
- Use a single trusted SSH key through `owrt.ssh_pubkey`.
- Treat `owrt.ttylogin=0` as an insecure debug mode.
- Keep `clevis.pcr_ids=1,4,5,7,9` unless you are intentionally redesigning the
  measured-boot policy and understand the consequences.
- Rebuild, clear TPM state, do one manual reseal, and only then expect
  automatic boot to succeed.
