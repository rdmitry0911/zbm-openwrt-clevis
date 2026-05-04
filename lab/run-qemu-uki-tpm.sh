#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUTDIR="${TOPDIR}/bin/targets/x86/64"
UKI="${UKI:-${OUTDIR}/openwrt-x86-64-generic-zbm.efi}"
ESP_IMG="${ESP_IMG:-${TOPDIR}/refind-openwrt-uki.img}"
UBUNTU_ZFS_DISK="${UBUNTU_ZFS_DISK:-/home/dima/projects/zfsbootmenu/lab.ubuntu-iso/ubuntu-zfs-target.raw}"
UBUNTU_ZFS_DISK_FORMAT="${UBUNTU_ZFS_DISK_FORMAT:-raw}"
MEMORY="${MEMORY:-4096}"
SMP="${SMP:-2}"
SSH_FWD_PORT="${SSH_FWD_PORT:-10039}"
TPM_DIR="${TPM_DIR:-${TOPDIR}/swtpm-zbm-ubuntu-uki}"
TPM_SOCK="${TPM_DIR}/swtpm.sock"
TPM_PID="${TPM_DIR}/swtpm.pid"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
OVMF_VARS="${OVMF_VARS:-${TPM_DIR}/OVMF_VARS.fd}"
QEMU_MACHINE="${QEMU_MACHINE:-q35}"
QEMU_CPU="${QEMU_CPU:-host}"
REFIND_OPTIONS="${REFIND_OPTIONS:-rd.shell=0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clevis.decrypt=yes clevis.store=zfs clevis.pcr_ids=1,4,5,7,9 owrt.auto_bootfs=rpool/ROOT/ubuntu_iu2exh}"

if [ ! -f "${UKI}" ]; then
  echo "missing UKI: ${UKI}" >&2
  exit 1
fi

if [ ! -f "${UBUNTU_ZFS_DISK}" ]; then
  echo "missing Ubuntu ZFS disk: ${UBUNTU_ZFS_DISK}" >&2
  exit 1
fi

if [ ! -f "${OVMF_CODE}" ] || [ ! -f "${OVMF_VARS_TEMPLATE}" ]; then
  echo "missing OVMF firmware" >&2
  exit 1
fi

mkdir -p "${TPM_DIR}"
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
  "${TOPDIR}/zbm-openwrt-refind-esp.sh" "${ESP_IMG}"

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

exec qemu-system-x86_64 \
  -enable-kvm \
  -machine "${QEMU_MACHINE}",accel=kvm \
  -cpu "${QEMU_CPU}" \
  -m "${MEMORY}" \
  -smp "${SMP}" \
  -nographic \
  -serial mon:stdio \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
  -drive if=pflash,format=raw,file="${OVMF_VARS}" \
  -drive file="${ESP_IMG}",format=raw,if=virtio \
  -drive file="${UBUNTU_ZFS_DISK}",format="${UBUNTU_ZFS_DISK_FORMAT}",if=virtio \
  -chardev socket,id=chrtpm,path="${TPM_SOCK}" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -nic user,model=virtio-net-pci,hostfwd=tcp::"${SSH_FWD_PORT}"-:22
