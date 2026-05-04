# Architecture

## Goal

The design keeps the clear-text ZFS key out of persistent storage and uses a small OpenWrt runtime as the policy and orchestration layer before the real operating system is started.

The target system is not unlocked directly by firmware or by the target initramfs. Instead, a separate boot runtime does the following:

1. starts in a measured UKI
2. receives policy from the kernel command line provided by `rEFInd`
3. attempts `clevis`-based key recovery
4. feeds the recovered key into the donor `ZFSBootMenu` runtime
5. boots the target system by `kexec`

## Boot chain

The validated chain is:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> zbm-start -> load-key hook / clevis -> donor ZBM runtime -> Ubuntu kernel`

Notes:

- `rEFInd` loads a single OpenWrt UKI, not a split `kernel + initrd` entry.
- The UKI is built with an empty embedded `.cmdline`; operational policy comes from external `rEFInd` options.
- OpenWrt uses a donor `ZFSBootMenu` runtime instead of re-implementing the boot environment and kernel selection logic from scratch.

## Relation to rEFInd

`rEFInd` is responsible for:

- loading `OPENWRT.EFI`
- providing the operational kernel command line
- remaining the stable top-level boot manager

Important caveat:

- security-critical policy carried in external `rEFInd` options is protected
  only by the PCRs you actually bind in `clevis.pcr_ids`
- if you need external `kcl` itself to be part of the seal policy, include the
  PCR that measures it in your chosen PCR set
- see [threat-model.md](threat-model.md) for the exact security implication

Typical parameters passed from `rEFInd`:

- `clevis.decrypt=yes`
- `clevis.store=zfs|efi|vfat`
- `clevis.file_location=DEV:DIR`
- `clevis.pcr_ids=1,4,5,7,9`
- `owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh`
- network or Wi-Fi parameters
- OpenWrt SSH public key and root password hash
- optional Telegram notification parameters

The complete `kcl` contract is documented in [kcl-options.md](kcl-options.md).

## Runtime components

The OpenWrt runtime contains:

- donor `ZFSBootMenu` shell runtime
- OpenZFS kernel modules and userspace
- `clevis`, `tpm2-tools`, `jose`, `jq`
- `dropbear`
- helper wrappers for boot lifecycle, locking, and command-line processing
- `efivar` and `efivarfs` support
- `vfat` support for file-backed `JWE` storage

## Automatic and manual lifecycle

Two modes use the same `ZBM` entry path:

- automatic mode:
  `rc.local -> zbm-auto-boot -> zbm-start -> zfsbootmenu-init -> load-key hook`
- manual mode:
  `login/ssh -> zbm-start -> zfsbootmenu-init -> load-key hook`

The key point is that the hook sees the same environment and the same donor runtime in both modes.

The automatic instance is launched from `rc.local`. Normal OpenWrt service startup, local login, and `dropbear` startup are not reordered around it; concurrency is controlled by the shared `ZBM` lock instead.

## Operator interaction

The policy is intentionally strict:

- only one `ZBM` instance may run at a time
- automatic and manual entry share the same lock
- if the operator starts `zbm-start` while the automatic instance is still running, the operator gets a warning and must try again later
- auto mode must never stop to ask for human input
- manual reseal happens inside the same `zbm-start -> hook -> zbm-end` path, not as a separate maintenance mode

The hook distinguishes auto vs manual mode by the presence of `/run/zbm-autoboot.done`:

- before `.done` exists, auto mode is active and interactive prompts are forbidden
- after `.done` exists, manual mode is allowed to ask for passphrase and to reseal

## Read-only and read-write policy

The normal boot path stays read-only as much as possible.

Only one narrow path flips to read-write:

- when `clevis.store=zfs`
- when the hook has already switched to manual mode
- when a reseal has been explicitly approved
- only for the short write of refreshed `latchset.clevis:*` properties

After the write, the pool is returned to read-only import mode.
