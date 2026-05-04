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

Variable names:

- `55555555-5555-5555-5555-555555555555-ClevisJWE`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_1`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_4`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_5`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_7`
- `55555555-5555-5555-5555-555555555555-ClevisJWE_9`

Requirements:

- `efivar` userspace
- `efivarfs.ko`
- persistent `OVMF_VARS.fd` in the QEMU lab

Validated result:

- manual reseal wrote the `ClevisJWE*` EFI variables
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

- `Clevis.JWE`
- `Clevis.JWE_1`
- `Clevis.JWE_4`
- `Clevis.JWE_5`
- `Clevis.JWE_7`
- `Clevis.JWE_9`

Requirements:

- `vfat`
- `fat`
- `nls_cp437`
- `nls_iso8859_1`

Validated result:

- manual reseal created the files on the VFAT filesystem
- next cold boot automatically reached Ubuntu
