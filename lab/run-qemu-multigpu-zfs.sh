#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTDIR="${OUTDIR:-${TOPDIR}/dist}"
UKI="${UKI:-${OUTDIR}/openwrt-x86-64-generic-zbm-clevis-overlay.efi}"
ESP_IMG="${ESP_IMG:-${OUTDIR}/refind-openwrt-multigpu-zfs.img}"
TARGET_DIR="${TARGET_DIR:-${TOPDIR}/lab/qemu-zfs-target}"
TARGET_POOL="${TARGET_POOL:-zbmtest}"
TARGET_DISK="${TARGET_DISK:-${TARGET_DIR}/${TARGET_POOL}-pool.img}"
MEMORY="${MEMORY:-4096}"
SMP="${SMP:-2}"
SSH_FWD_PORT="${SSH_FWD_PORT:-10039}"
TPM_DIR="${TPM_DIR:-${OUTDIR}/swtpm-multigpu-zfs}"
TPM_SOCK="${TPM_DIR}/swtpm.sock"
TPM_PID="${TPM_DIR}/swtpm.pid"
RESEAL_KEY_FILE="${RESEAL_KEY_FILE:-}"
RESEAL_KEY_DRIVE_FILE="${RESEAL_KEY_DRIVE_FILE:-${RESEAL_KEY_FILE}}"
RESEAL_KEY_APPEND_KCL="${RESEAL_KEY_APPEND_KCL:-}"
RESEAL_KEY_BLOCKDEV="${RESEAL_KEY_BLOCKDEV:-/dev/vdc}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
OVMF_VARS="${OVMF_VARS:-${TPM_DIR}/OVMF_VARS.fd}"
QEMU_MACHINE="${QEMU_MACHINE:-q35}"
QEMU_CPU="${QEMU_CPU:-host}"
VNC_DISPLAY="${VNC_DISPLAY:-59}"

TARGET_APPEND_DEFAULT='console=tty0 console=ttyS0,115200n8 loglevel=7 ignore_loglevel video=Virtual-1:1280x800@60 video=Virtual-2:1280x800@60 video=Virtual-3:768x1024@60'
TARGET_APPEND="${TARGET_APPEND:-${TARGET_APPEND_DEFAULT}}"
REFIND_OPTIONS="${REFIND_OPTIONS:-rd.shell=0 console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.host=zbm-lab owrt.ttylogin=0 owrt.auto_bootfs=${TARGET_POOL}/ROOT/ubuntu owrt.console_rotate=right owrt.target_console_rotate=right owrt.target_fbcon_map=0 owrt.target_kcl_append=\"\"${TARGET_APPEND}\"\"}"
RESEAL_KEY_DRIVE_ARGS=""

if [ -n "${RESEAL_KEY_DRIVE_FILE}" ]; then
  if [ ! -f "${RESEAL_KEY_DRIVE_FILE}" ]; then
    echo "missing reseal key drive file: ${RESEAL_KEY_DRIVE_FILE}" >&2
    exit 1
  fi
  RESEAL_KEY_DRIVE_ARGS="-drive file=${RESEAL_KEY_DRIVE_FILE},format=raw,if=virtio,readonly=on"
fi

if [ -n "${RESEAL_KEY_FILE}" ] || [ "${RESEAL_KEY_APPEND_KCL}" = "1" ]; then
  REFIND_OPTIONS="${REFIND_OPTIONS} clevis.reseal_key_blockdev=${RESEAL_KEY_BLOCKDEV}"
fi

if [ ! -f "${UKI}" ]; then
  echo "missing UKI: ${UKI}" >&2
  exit 1
fi

if [ ! -f "${TARGET_DISK}" ]; then
  echo "missing target disk: ${TARGET_DISK}" >&2
  exit 1
fi

if [ ! -f "${OVMF_CODE}" ] || [ ! -f "${OVMF_VARS_TEMPLATE}" ]; then
  echo "missing OVMF firmware" >&2
  exit 1
fi

mkdir -p "${OUTDIR}" "${TPM_DIR}"
if [ ! -f "${TPM_DIR}/.initialized" ]; then
  rm -rf "${TPM_DIR}/state"
  mkdir -p "${TPM_DIR}/state"
  swtpm_setup --tpm2 --tpmstate "dir://${TPM_DIR}/state" --createek --create-spk --lock-nvram >/dev/null
  : > "${TPM_DIR}/.initialized"
fi

if [ ! -f "${OVMF_VARS}" ]; then
  cp -f "${OVMF_VARS_TEMPLATE}" "${OVMF_VARS}"
fi

OPENWRT_UKI="${UKI}" OPENWRT_REFIND_OPTIONS="${REFIND_OPTIONS}" \
  "${TOPDIR}/lab/refind-esp.sh" "${ESP_IMG}"

rm -f "${TPM_SOCK}" "${TPM_PID}"
swtpm socket \
  --tpmstate "dir=${TPM_DIR}/state" \
  --ctrl "type=unixio,path=${TPM_SOCK}" \
  --tpm2 \
  --flags startup-clear \
  --daemon \
  --pid file="${TPM_PID}" \
  --log level=20

cleanup() {
  set +e
  if [ -f "${TPM_PID}" ]; then
    kill "$(cat "${TPM_PID}")" 2>/dev/null || true
    rm -f "${TPM_PID}"
  fi
  rm -f "${TPM_SOCK}"
}
trap cleanup EXIT INT TERM

DISPLAY_ARGS="${DISPLAY_ARGS:-}"
if [ -z "${DISPLAY_ARGS}" ]; then
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    DISPLAY_ARGS="-display gtk,show-tabs=on"
  else
    DISPLAY_ARGS="-display none -vnc 127.0.0.1:${VNC_DISPLAY}"
    printf 'QEMU VNC display: 127.0.0.1:%s\n' "${VNC_DISPLAY}"
  fi
fi

# shellcheck disable=SC2086
exec qemu-system-x86_64 \
  -enable-kvm \
  -machine "${QEMU_MACHINE}",accel=kvm \
  -cpu "${QEMU_CPU}" \
  -m "${MEMORY}" \
  -smp "${SMP}" \
  -serial mon:stdio \
  ${DISPLAY_ARGS} \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
  -drive if=pflash,format=raw,file="${OVMF_VARS}" \
  -drive file="${ESP_IMG}",format=raw,if=virtio \
  -drive file="${TARGET_DISK}",format=raw,if=virtio \
  ${RESEAL_KEY_DRIVE_ARGS} \
  -device virtio-vga,max_outputs=2,xres=1280,yres=800 \
  -device virtio-gpu-pci,max_outputs=1,xres=768,yres=1024 \
  -chardev socket,id=chrtpm,path="${TPM_SOCK}" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -nic user,model=virtio-net-pci,hostfwd=tcp::"${SSH_FWD_PORT}"-:22
