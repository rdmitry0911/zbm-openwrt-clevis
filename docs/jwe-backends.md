# JWE backends

This implementation supports three storage backends for the TPM-sealed `JWE`.

## zfs

Location:

- ZFS user properties on the encryption root

Properties:

- `latchset.clevis:jwe`
- `latchset.clevis:jwe_1`
- `latchset.clevis:jwe_4`
- `latchset.clevis:jwe_5`
- `latchset.clevis:jwe_7`
- `latchset.clevis:jwe_9`

Behavior:

- normal boot path stays read-only
- on manual reseal, the pool is temporarily flipped `ro -> rw -> ro`
- the write happens only around the property update

Validated result:

- manual reseal succeeded
- next cold boot automatically reached Ubuntu

## efi

Location:

- EFI variables in `efivarfs`

Naming rule:

- derive a tag from the current encryption root
- replace non `[A-Za-z0-9_.-]` characters with `_`

Example:

- encryption root: `rpool/ROOT/ubuntu`
- tag: `rpool_ROOT_ubuntu`

Variable names for that example:

- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu_1`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu_4`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu_5`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu_7`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_rpool_ROOT_ubuntu_9`

Compatibility:

- dataset-specific EFI variable names are tried first
- legacy generic `ClevisJWE*` EFI variables are still accepted as fallback

Requirements:

- `efivar` userspace
- `efivarfs.ko`
- persistent `OVMF_VARS.fd` in the QEMU lab

Validated result:

- manual reseal wrote the dataset-specific `ClevisJWE_<tag>*` EFI variables
- next cold boot automatically reached Ubuntu

## vfat

Location:

- files on a chosen FAT filesystem

Control parameter:

```text
clevis.file_location=DEVICE:SUBDIRECTORY
```

Validated lab example:

```text
clevis.file_location=/dev/vdb1:/clevis
```

Expected files:

- `Clevis.<tag>.JWE`
- `Clevis.<tag>.JWE_1`
- `Clevis.<tag>.JWE_4`
- `Clevis.<tag>.JWE_5`
- `Clevis.<tag>.JWE_7`
- `Clevis.<tag>.JWE_9`

Example for encryption root `rpool/ROOT/ubuntu`:

- `Clevis.rpool_ROOT_ubuntu.JWE`
- `Clevis.rpool_ROOT_ubuntu.JWE_1`
- `Clevis.rpool_ROOT_ubuntu.JWE_4`
- `Clevis.rpool_ROOT_ubuntu.JWE_5`
- `Clevis.rpool_ROOT_ubuntu.JWE_7`
- `Clevis.rpool_ROOT_ubuntu.JWE_9`

Compatibility:

- dataset-specific file names are tried first
- legacy generic `Clevis.JWE*` file names are still accepted as fallback

Requirements:

- `vfat`
- `fat`
- `nls_cp437`
- `nls_iso8859_1`

Validated result:

- manual reseal created the files on the VFAT filesystem
- next cold boot automatically reached Ubuntu
