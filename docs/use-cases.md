# Use cases

This page describes practical situations where `zbm-openwrt-clevis` is useful.
It is intentionally operational: the threat model and exact `kcl` contract are
documented separately in [threat-model.md](threat-model.md) and
[kcl-options.md](kcl-options.md).

## Remote dedicated server

A typical example is a dedicated host in a provider environment such as
Hetzner.

Important constraints:

- the physical machine is not directly accessible to the owner
- physical access is mediated by the provider's operators
- firmware setup and BIOS/UEFI console access may require a support request
- after an unplanned reboot, the owner may only see a remote pre-boot console

With a conventional encrypted-root setup, the operator is often asked to type
the ZFS passphrase into an `initramfs/initrd` prompt. That is operationally
convenient, but it does not by itself prove that the prompt belongs to the
same boot environment that the owner previously inspected and trusted.

The purpose of this project is to move that trust decision earlier. The
measured OpenWrt boot runtime decides whether automatic unlock is allowed. If
the measured state no longer matches the manually approved state, automatic
unlock stops and the system remains in the controlled OpenWrt runtime instead
of blindly proceeding to the target operating system.

### Suspicion of compromise

If there is a reason to suspect that the provider console, boot path, or
pre-boot environment may have been tampered with, the operator can use a
pre-built trusted recovery variant of the boot runtime.

One practical procedure is:

1. Prepare a known-good `zbm-openwrt-clevis` image in advance.
2. Give that image a deliberately unusual `kcl` profile.
3. Disable passwordless login in that profile.
4. Add a tiny verification program or boot-time message that prints a secret
   word known only to the owner.
5. From the existing boot environment, download or install that trusted
   variant.
6. Reboot into it.
7. Confirm through the remote console that the expected secret word is shown.
8. Confirm that passwordless access is disabled.
9. Only then enter the ZFS passphrase and continue the manual boot path.

This does not make the provider's firmware, console service, or hardware fully
trusted. It gives the owner a concrete way to verify that the environment
asking for the ZFS passphrase is the expected measured boot runtime, not an
unknown `initramfs/initrd` prompt.

Operational notes:

- keep `owrt.ttylogin=1`
- keep the base image's `root` account locked unless access is intentionally
  enabled through `kcl`
- use `owrt.ssh_pubkey` for SSH access to the fallback runtime
- treat the recovery image and its expected verification word as part of the
  operator's out-of-band runbook
- reseal only after the operator has intentionally accepted the new measured
  state

## Unattended laptop at home

Another use case is a laptop left at home to run long-lived jobs. The machine
may occasionally reboot because of power events, kernel updates, hardware
issues, or a scheduled task.

If the ZFS root key is TPM-sealed, a reboot can leave the machine in a state
where automatic unlock no longer works. This is expected when the measured
state changed: the old sealed secret should not be released into an unapproved
boot environment.

For a laptop, the practical problem is reachability. There may be no wired
network, and the only available path to the boot runtime is Wi-Fi.

The OpenWrt runtime can include the required Wi-Fi drivers and userspace. The
operator can pass Wi-Fi configuration through `kcl`, for example:

```conf
owrt.wifi_ssid="home-ssid"
owrt.wifi_psk="home-passphrase"
```

With networking available in the boot runtime, the operator can connect to
OpenWrt remotely, run the manual unlock path, enter the ZFS passphrase, and
then decide whether to reseal for the new measured state.

This turns an otherwise stranded encrypted laptop into a recoverable system:
it still refuses to release the ZFS key automatically after an unexpected
measurement change, but it exposes a controlled, authenticated recovery
environment with enough networking to let the owner finish the boot.

Operational notes:

- include the actual laptop Wi-Fi driver and firmware in the OpenWrt image
- test the Wi-Fi path before leaving the laptop unattended
- prefer SSH key access with `owrt.ssh_pubkey`
- avoid putting long-term secrets into unprotected `kcl` unless the PCR policy
  intentionally covers that command line
- after a legitimate update, boot manually once and reseal the key for the new
  measured state
