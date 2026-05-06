# Architecture

## Motivation

The target problem is not just "boot encrypted ZFS" but "boot encrypted ZFS
without giving up trust in the environment that receives the decryption key."

`ZFSBootMenu` already handles encrypted ZFS roots well, but it normally relies
on a human to type the key. For a remote system that is insufficient: the
operator still needs confidence that the place where the key is entered is
trusted. This project adds that trust decision through TPM measurements and
`clevis`.

`ZFSBootMenu` is also not a full operating system. Even when the measured
state is trusted, it does not provide a hardened multi-user runtime that can
enforce normal login boundaries before the operator types the key. OpenWrt is
used as a minimal complete system that can require password-protected entry
before the manual fallback path is available.

## Goal

The design keeps the clear-text ZFS key out of persistent storage and uses a small OpenWrt runtime as the policy and orchestration layer before the real operating system is started.

The target system itself, including `vmlinuz`, `initramfs/initrd`, and the
target-side decryption material needed after handoff, lives on a fully
encrypted ZFS root. The target system is not unlocked directly by firmware or
by the target initramfs. Instead, a separate boot runtime does the following:

1. starts in a measured UKI
2. receives policy from the kernel command line provided by `rEFInd`
3. attempts `clevis`-based key recovery
4. feeds the recovered key into the donor `ZFSBootMenu` runtime
5. reads the target kernel and `initramfs/initrd` from the encrypted ZFS root
6. boots the target system by `kexec`

Once control reaches the target `initramfs/initrd`, that environment already
has what it needs for its own side of the boot, so the remaining encrypted
root handling is not blocked on another human interaction.

## Boot chain

The validated chain is:

`UEFI -> rEFInd -> OpenWrt UKI -> zbm-auto-boot -> zbm-start -> load-key hook / clevis -> donor ZBM runtime -> kexec -> target kernel + initramfs -> target OS`

Visual flow:

```text
+--------+      +--------+      +---------------------+
|  UEFI  | ---> | rEFInd | ---> | zbm-openwrt-clevis  |
+--------+      +--------+      | OpenWrt UKI runtime |
                                +----------+----------+
                                           |
                                           | kcl policy
                                           v
                                +----------+----------+
                                | zbm-auto-boot /     |
                                | zbm-start           |
                                +----------+----------+
                                           |
                                           | load-key hook
                                           v
                                +----------+----------+
                                | clevis + TPM policy |
                                +----+-----------+----+
                                     |           |
                      trusted state   |           | untrusted / changed state
                        auto unlock   |           | notify operator, wait for
                                     v           | manual decision
                                +----+-----------+----+
                                | donor ZFSBootMenu   |
                                | runtime             |
                                +----------+----------+
                                           |
                                           | reads kernel + initramfs
                                           | from encrypted ZFS root
                                           v
                                +----------+----------+
                                | kexec into target   |
                                | kernel + initramfs  |
                                +----------+----------+
                                           |
                                           v
                                +----------+----------+
                                | target OS on        |
                                | encrypted ZFS root  |
                                +---------------------+
```

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
- in the currently validated project configuration, `clevis.pcr_ids=1,4,5,7,9`
  is the policy set that covers the relevant external `kcl`
- changing `rEFInd` arguments therefore changes the measured state and must
  stop automatic boot until a new reseal is performed
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

## Guarded perimeter

The guarded perimeter is the OpenWrt UKI runtime itself plus the environment
that measures and launches it.

Its job is narrow:

- boot as a measured EFI application
- decide whether the current state is still trusted
- recover the ZFS key automatically only in that trusted state
- otherwise stop automatic boot, notify the operator, and wait for a manual
  decision

The runtime can access the encrypted form of the key material, but it must not
be able to turn that into the clear-text ZFS key unless the measured state
still matches the state that was manually approved by the operator during the
last reseal.

## Runtime components

The OpenWrt runtime contains:

- donor `ZFSBootMenu` shell runtime
- OpenZFS kernel modules and userspace
- `clevis`, `tpm2-tools`, `jose`, `jq`
- `dropbear`
- helper wrappers for boot lifecycle, locking, and command-line processing
- `efivar` and `efivarfs` support
- `vfat` support for file-backed `JWE` storage
- `mc`
- `nano-plus`

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
- `Ctrl-C` in the donor `ZBM` TUI exits back to the protected OpenWrt system
- the old shell-escape and direct chroot shortcuts are disabled in the validated image

The hook distinguishes auto vs manual mode by the presence of `/run/zbm-autoboot.done`:

- before `.done` exists, auto mode is active and interactive prompts are forbidden
- after `.done` exists, manual mode is allowed to ask for passphrase and to reseal

## Why target OS updates do not force a new manual unlock

The measured gate is the OpenWrt boot runtime, not the target kernel or target
`initramfs/initrd` stored inside the encrypted root.

Practical consequence:

- updating the target system may replace `vmlinuz`, `initramfs`, or embedded
  target-side decryption content
- automatic boot can continue to work without a new manual password entry
- a new manual reseal is needed only when the measured OpenWrt runtime or its
  trusted boot context changes

## Read-only and read-write policy

The normal boot path stays read-only as much as possible.

Only one narrow path flips to read-write:

- when `clevis.store=zfs`
- when the hook has already switched to manual mode
- when a reseal has been explicitly approved
- only for the short write of refreshed `latchset.clevis:*` properties

After the write, the pool is returned to read-only import mode.

## Naming of `efi` and `vfat` JWE storage

The `zfs` backend naturally stores properties on the current encryption root,
so multiple encrypted roots do not collide there.

For the `efi` and `vfat` backends, the current implementation now derives a
storage tag from the active encryption root by replacing non
`[A-Za-z0-9_.-]` characters with `_`.

Example:

- encryption root: `rpool/ROOT/ubuntu`
- tag: `rpool_ROOT_ubuntu`

That tag is then used in the stored object names:

- `efi`: `ClevisJWE_<tag>`, `ClevisJWE_<tag>_1`, ...
- `vfat`: `Clevis.<tag>.JWE`, `Clevis.<tag>.JWE_1`, ...

Read path compatibility is preserved:

- dataset-specific names are tried first
- legacy generic names are still accepted as fallback
