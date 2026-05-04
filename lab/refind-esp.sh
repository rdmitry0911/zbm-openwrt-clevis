#!/bin/sh
set -eu
PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ESP_IMG="${1:-${TOPDIR}/refind-esp.img}"
ESP_SIZE_MB="${ESP_SIZE_MB:-256}"
MMD_FLAGS="-i ${ESP_IMG}"
MCOPY_FLAGS="-i ${ESP_IMG} -s"

REFIND_ROOT="/usr/share/refind/refind"
REFIND_EFI="${REFIND_ROOT}/refind_x64.efi"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT INT TERM

ZBM_EFI="${ZBM_EFI:-}"
OPENWRT_EFI="${OPENWRT_EFI:-}"
OPENWRT_UKI="${OPENWRT_UKI:-}"
OPENWRT_KERNEL="${OPENWRT_KERNEL:-}"
OPENWRT_INITRD="${OPENWRT_INITRD:-}"
OPENWRT_CMDLINE="${OPENWRT_CMDLINE:-console=ttyS0,115200n8}"
OPENWRT_REFIND_OPTIONS="${OPENWRT_REFIND_OPTIONS:-}"

truncate -s "${ESP_SIZE_MB}M" "${ESP_IMG}"
mkfs.fat -F 32 "${ESP_IMG}" >/dev/null

mmd ${MMD_FLAGS} ::/EFI ::/EFI/BOOT ::/EFI/tools
mcopy ${MCOPY_FLAGS} "${REFIND_EFI}" ::/EFI/BOOT/BOOTX64.EFI
mcopy ${MCOPY_FLAGS} "${REFIND_ROOT}/drivers_x64" ::/EFI/BOOT/
mcopy ${MCOPY_FLAGS} "${REFIND_ROOT}/icons" ::/EFI/BOOT/

cat > "${TMPDIR}/refind.conf" <<'EOF'
timeout 5
use_nvram false
scanfor manual,external,internal
scan_delay 1
textonly false
showtools shell,reboot,shutdown,about
banner icons/os_refind.png
EOF

if [ -n "${ZBM_EFI}" ]; then
  mmd ${MMD_FLAGS} ::/EFI/ZBM
  mcopy ${MCOPY_FLAGS} "${ZBM_EFI}" ::/EFI/ZBM/VMLINUZ.EFI
fi

if [ -n "${OPENWRT_EFI}" ]; then
  mmd ${MMD_FLAGS} ::/EFI/OPENWRT
  mcopy ${MCOPY_FLAGS} "${OPENWRT_EFI}" ::/EFI/OPENWRT/OPENWRT.EFI
fi

if [ -n "${OPENWRT_UKI}" ]; then
  mmd ${MMD_FLAGS} ::/EFI/OPENWRT
  mcopy ${MCOPY_FLAGS} "${OPENWRT_UKI}" ::/EFI/OPENWRT/OPENWRT.EFI
  cat >> "${TMPDIR}/refind.conf" <<EOF

menuentry "OpenWrt ZBM UKI" {
    ostype Linux
    loader /EFI/OPENWRT/OPENWRT.EFI
    options "${OPENWRT_REFIND_OPTIONS}"
}
EOF
fi

if [ -n "${OPENWRT_KERNEL}" ] && [ -n "${OPENWRT_INITRD}" ]; then
  mmd ${MMD_FLAGS} ::/EFI/OPENWRT
  mcopy ${MCOPY_FLAGS} "${OPENWRT_KERNEL}" ::/EFI/OPENWRT/
  mcopy ${MCOPY_FLAGS} "${OPENWRT_INITRD}" ::/EFI/OPENWRT/
  cat > "${TMPDIR}/refind_linux.conf" <<EOF
"OpenWrt Lab" "${OPENWRT_CMDLINE} initrd=\\EFI\\OPENWRT\\$(basename "${OPENWRT_INITRD}")"
EOF
  mcopy ${MCOPY_FLAGS} "${TMPDIR}/refind_linux.conf" ::/EFI/OPENWRT/refind_linux.conf
fi

mcopy ${MCOPY_FLAGS} "${TMPDIR}/refind.conf" ::/EFI/BOOT/refind.conf
