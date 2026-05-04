# Threat model

## Scope

This package is a measured pre-boot runtime for unlocking an encrypted ZFS
root and then booting the target operating system through a donor
`ZFSBootMenu` runtime.

Validated chain:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> zbm-start -> load-key hook / clevis -> donor ZBM runtime -> kexec -> target OS`

## Protected assets

The design tries to protect:

- the clear-text ZFS passphrase or key material
- the decision whether the target system is allowed to boot automatically
- the integrity of the measured OpenWrt UKI used as the policy runtime
- the integrity of the TPM-sealed `JWE` used for later automatic boots
- operator access to the fallback OpenWrt runtime

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

### Unauthorized access to fallback OpenWrt

The image now defaults to:

- `ttylogin=1`
- locked `root` in the static image

Access becomes possible only after a valid password hash or SSH key is applied
from `kcl`.

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
