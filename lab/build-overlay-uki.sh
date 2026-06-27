#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_UKI="${BASE_UKI:-/boot/efi/EFI/zbm-openwrt-clevis.last/vmlinuz-openwrt-x86-64-generic-zbm-clevis.efi}"
OVERLAY_DIR="${OVERLAY_DIR:-${TOPDIR}/overlay}"
EXTRA_OVERLAY_DIR="${EXTRA_OVERLAY_DIR:-}"
OUTDIR="${OUTDIR:-${TOPDIR}/dist}"
OUT="${OUT:-${OUTDIR}/openwrt-x86-64-generic-zbm-clevis-overlay.efi}"
STUB="${STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT INT TERM

[ -f "${BASE_UKI}" ] || {
  echo "missing base UKI: ${BASE_UKI}" >&2
  exit 1
}

[ -d "${OVERLAY_DIR}" ] || {
  echo "missing overlay directory: ${OVERLAY_DIR}" >&2
  exit 1
}

[ -f "${STUB}" ] || {
  echo "missing systemd stub: ${STUB}" >&2
  exit 1
}

mkdir -p "${OUTDIR}"
cp "${BASE_UKI}" "${WORKDIR}/base.efi"
objcopy --dump-section .linux="${WORKDIR}/linux" "${WORKDIR}/base.efi"
objcopy --dump-section .osrel="${WORKDIR}/os-release" "${WORKDIR}/base.efi"
objcopy --dump-section .uname="${WORKDIR}/uname" "${WORKDIR}/base.efi" 2>/dev/null || :
: > "${WORKDIR}/cmdline"

mkdir -p "${WORKDIR}/overlay"
cp -a "${OVERLAY_DIR}/." "${WORKDIR}/overlay/"

if [ -n "${EXTRA_OVERLAY_DIR}" ]; then
  [ -d "${EXTRA_OVERLAY_DIR}" ] || {
    echo "missing extra overlay directory: ${EXTRA_OVERLAY_DIR}" >&2
    exit 1
  }
  cp -a "${EXTRA_OVERLAY_DIR}/." "${WORKDIR}/overlay/"
fi

(
  cd "${WORKDIR}/overlay"
  find . -print0 | cpio --null -o -H newc --owner root:root 2>/dev/null
) | gzip -9 > "${WORKDIR}/overlay.cpio.gz"

set -- build \
  --linux "${WORKDIR}/linux" \
  --initrd "${WORKDIR}/overlay.cpio.gz" \
  --cmdline "@${WORKDIR}/cmdline" \
  --os-release "@${WORKDIR}/os-release" \
  --stub "${STUB}" \
  --efi-arch x64 \
  --output "${OUT}"

if [ -s "${WORKDIR}/uname" ]; then
  set -- "$@" --uname "$(tr -d '\000' < "${WORKDIR}/uname")"
fi

ukify "$@"
ukify inspect "${OUT}"
printf '\nUKI=%s\n' "${OUT}"
