#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ZFSBOOTMENU_DIR="${ZFSBOOTMENU_DIR:-${TOPDIR}/../zfsbootmenu}"
TESTDIR="${TESTDIR:-${TOPDIR}/lab/qemu-zfs-target}"
POOL="${POOL:-zbmtest}"
SIZE="${SIZE:-8G}"
RELEASE="${RELEASE:-jammy}"

if [ ! -d "${ZFSBOOTMENU_DIR}/testing" ]; then
  echo "missing ZFSBootMenu checkout: ${ZFSBOOTMENU_DIR}" >&2
  exit 1
fi

mkdir -p "${TESTDIR}"

if [ -f "${TESTDIR}/${POOL}-pool.img" ]; then
  printf 'target image already exists: %s\n' "${TESTDIR}/${POOL}-pool.img"
  printf 'key file: %s\n' "${TESTDIR}/${POOL}.key"
  exit 0
fi

for tool in debootstrap kpartx qemu-img zpool zfs; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "missing required tool: ${tool}" >&2
    exit 1
  fi
done

(
  cd "${ZFSBOOTMENU_DIR}/testing"
  ./setup.sh \
    -i \
    -e \
    -D "${TESTDIR}" \
    -s "${SIZE}" \
    -o ubuntu \
    -p "${POOL}" \
    -E "RELEASE=${RELEASE}" \
    -E "POOL_COMPAT=openzfs-2.0-linux"
)

printf 'target image: %s\n' "${TESTDIR}/${POOL}-pool.img"
printf 'key file: %s\n' "${TESTDIR}/${POOL}.key"
