#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUTDIR="${TOPDIR}/bin/targets/x86/64"
KERNEL="${KERNEL:-${OUTDIR}/openwrt-x86-64-generic-initramfs-kernel.bin}"
STUB="${STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
UKI="${UKI:-${OUTDIR}/openwrt-x86-64-generic-zbm.efi}"
CMDLINE_FILE="${CMDLINE_FILE:-}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-${TOPDIR}/tmp/openwrt-uki.os-release}"

if [ ! -f "${KERNEL}" ]; then
  echo "missing initramfs kernel: ${KERNEL}" >&2
  exit 1
fi

if [ ! -f "${STUB}" ]; then
  echo "missing systemd stub: ${STUB}" >&2
  exit 1
fi

INITRD="${INITRD:-$(find "${TOPDIR}/build_dir/target-x86_64_musl" -type f -name 'initrd*.cpio*' | sort | tail -n 1)}"

if [ -z "${CMDLINE_FILE}" ]; then
  CMDLINE_FILE="$(mktemp)"
  trap 'rm -f "${CMDLINE_FILE}"' EXIT INT TERM
  : > "${CMDLINE_FILE}"
fi

mkdir -p "$(dirname "${OS_RELEASE_FILE}")"
cat > "${OS_RELEASE_FILE}" <<'EOF'
ID=openwrt
NAME="OpenWrt ZBM Lab"
PRETTY_NAME="OpenWrt ZBM Lab"
EOF

set -- build \
  --linux "${KERNEL}" \
  --cmdline "@${CMDLINE_FILE}" \
  --os-release "@${OS_RELEASE_FILE}" \
  --stub "${STUB}" \
  --efi-arch x64 \
  --output "${UKI}"

if [ -n "${INITRD}" ] && [ -f "${INITRD}" ]; then
  set -- "$@" --initrd "${INITRD}"
fi

ukify "$@"

ukify inspect "${UKI}"
printf '\nUKI=%s\n' "${UKI}"
if [ -n "${INITRD}" ] && [ -f "${INITRD}" ]; then
  printf 'INITRD=%s\n' "${INITRD}"
else
  printf 'INITRD=<embedded in kernel>\n'
fi
