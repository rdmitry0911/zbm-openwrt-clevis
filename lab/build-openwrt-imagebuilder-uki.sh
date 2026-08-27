#!/usr/bin/env bash
set -Eeuo pipefail

TOPDIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.4}"
OPENWRT_BASE_URL="${OPENWRT_BASE_URL:-https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64}"
OPENWRT_IB_TARBALL="${OPENWRT_IB_TARBALL:-openwrt-imagebuilder-${OPENWRT_VERSION}-x86-64.Linux-x86_64.tar.zst}"
OPENWRT_SDK_TARBALL="${OPENWRT_SDK_TARBALL:-openwrt-sdk-${OPENWRT_VERSION}-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"

ZFSBOOTMENU_REF="${ZFSBOOTMENU_REF:-v3.1.0}"
ZFSBOOTMENU_REPO="${ZFSBOOTMENU_REPO:-https://github.com/zbm-dev/zfsbootmenu.git}"
ZFSBOOTMENU_DIR="${ZFSBOOTMENU_DIR:-}"

CLEVIS_REF="${CLEVIS_REF:-v23}"
CLEVIS_REPO="${CLEVIS_REPO:-https://github.com/latchset/clevis.git}"
CLEVIS_DIR="${CLEVIS_DIR:-}"

OPENZFS_REF="${OPENZFS_REF:-zfs-2.4.3}"
OPENZFS_REPO="${OPENZFS_REPO:-https://github.com/openzfs/zfs.git}"
OPENZFS_DIR="${OPENZFS_DIR:-}"

DEFAULT_JOBS="$(nproc)"
if [ "${DEFAULT_JOBS}" -gt 6 ]; then
  DEFAULT_JOBS=6
fi
JOBS="${JOBS:-${DEFAULT_JOBS}}"

BUILDDIR="${BUILDDIR:-${TOPDIR}/dist/openwrt-imagebuilder-uki-build}"
SRCDIR="${SRCDIR:-${BUILDDIR}/src}"
OUTDIR="${OUTDIR:-${TOPDIR}/dist}"
UKI="${UKI:-${OUTDIR}/vmlinuz-openwrt-${OPENWRT_VERSION}-x86-64-generic-zbm-clevis-imagebuilder.efi}"
STUB="${STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
WORLD_REF="${WORLD_REF:-${TOPDIR}/lab/openwrt-current-world.txt}"
OVERLAY_DIR="${OVERLAY_DIR:-${TOPDIR}/overlay}"
HOST_TOOL_ROOTFS="${HOST_TOOL_ROOTFS:-/tmp/openwrt-zbm-rootfs}"
TPM_CRB_KO="${TPM_CRB_KO:-}"
KEXEC_TOOLS_PATCH_DIR="${KEXEC_TOOLS_PATCH_DIR:-${TOPDIR}/patches/kexec-tools}"
KEXEC_TOOLS_VERSION="${KEXEC_TOOLS_VERSION:-2.0.28}"
KEXEC_TOOLS_URL="${KEXEC_TOOLS_URL:-https://cdn.kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-${KEXEC_TOOLS_VERSION}.tar.xz}"
KEXEC_TOOLS_HASH="${KEXEC_TOOLS_HASH:-d2f0ef872f39e2fe4b1b01feb62b0001383207239b9f8041f98a95564161d053}"
PATCHED_KEXEC="${PATCHED_KEXEC:-${BUILDDIR}/kexec-tools-${KEXEC_TOOLS_VERSION}-patched/install/usr/sbin/kexec}"
ZBM_SETFONT_SRC="${ZBM_SETFONT_SRC:-${TOPDIR}/tools/zbm-setfont.c}"
ZBM_SETFONT="${ZBM_SETFONT:-${BUILDDIR}/zbm-setfont/setfont}"
EXTRA_IWLWIFI_FIRMWARE_NAME="${EXTRA_IWLWIFI_FIRMWARE_NAME:-iwlwifi-so-a0-gf-a0-89.ucode}"
EXTRA_IWLWIFI_FIRMWARE_URL="${EXTRA_IWLWIFI_FIRMWARE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/iwlwifi/${EXTRA_IWLWIFI_FIRMWARE_NAME}?h=20260221}"
EXTRA_IWLWIFI_FIRMWARE_HASH="${EXTRA_IWLWIFI_FIRMWARE_HASH:-a68167801e24ac5c03f594f23ca7c0c1b151c7cfbe97da45ee22206dc2d970bf}"
EXTRA_IWLWIFI_FIRMWARE="${EXTRA_IWLWIFI_FIRMWARE:-${BUILDDIR}/downloads/${EXTRA_IWLWIFI_FIRMWARE_NAME}}"
EXTRA_IWLWIFI_PNVM_NAME="${EXTRA_IWLWIFI_PNVM_NAME:-iwlwifi-so-a0-gf-a0.pnvm}"
EXTRA_IWLWIFI_PNVM_URL="${EXTRA_IWLWIFI_PNVM_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/iwlwifi/${EXTRA_IWLWIFI_PNVM_NAME}?h=20260221}"
EXTRA_IWLWIFI_PNVM_HASH="${EXTRA_IWLWIFI_PNVM_HASH:-e855e1e545e76a62b2314dfbcdaf36fe12ca5e798b7d00c5e9a1d4740732ff09}"
EXTRA_IWLWIFI_PNVM="${EXTRA_IWLWIFI_PNVM:-${BUILDDIR}/downloads/${EXTRA_IWLWIFI_PNVM_NAME}}"

IB_DIR="${IB_DIR:-${BUILDDIR}/imagebuilder}"
SDK_DIR="${SDK_DIR:-${BUILDDIR}/sdk}"
FILES_DIR="${FILES_DIR:-${BUILDDIR}/files}"
INITRD="${INITRD:-${BUILDDIR}/openwrt-zbm-initramfs.cpio.gz}"

log() {
  printf '[build-openwrt-imagebuilder-uki] %s\n' "$*"
}

die() {
  printf '[build-openwrt-imagebuilder-uki] ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

run() {
  log "+ $*"
  "$@"
}

clone_ref() {
  local repo ref dir

  repo="${1}"
  ref="${2}"
  dir="${3}"

  if [ -d "${dir}/.git" ]; then
    log "using existing checkout: ${dir}"
    git -C "${dir}" fetch --tags --depth 1 origin "${ref}" >/dev/null 2>&1 || true
    git -C "${dir}" checkout -q "${ref}"
    return
  fi

  rm -rf "${dir}"
  mkdir -p "$(dirname "${dir}")"
  run git clone --depth 1 --branch "${ref}" "${repo}" "${dir}"
}

download() {
  local url out

  url="${1}"
  out="${2}"

  if [ -s "${out}" ]; then
    log "using cached download: ${out}"
    return
  fi

  mkdir -p "$(dirname "${out}")"
  run curl -fL --retry 3 -o "${out}.tmp" "${url}"
  mv "${out}.tmp" "${out}"
}

download_checked() {
  local url out want have

  url="${1}"
  out="${2}"
  want="${3}"

  download "${url}" "${out}"
  have="$(sha256sum "${out}" | awk '{print $1}')"
  [ "${have}" = "${want}" ] || die "download hash mismatch for ${out}: ${have}"
}

extract_single_dir_tarball() {
  local tarball dest top

  tarball="${1}"
  dest="${2}"

  if [ -d "${dest}" ]; then
    log "using existing extracted tree: ${dest}"
    return
  fi

  rm -rf "${dest}.tmp"
  mkdir -p "${dest}.tmp"
  run tar -I zstd -xf "${tarball}" -C "${dest}.tmp"
  top="$(find "${dest}.tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "${top}" ] || die "tarball did not contain a top-level directory: ${tarball}"
  mv "${top}" "${dest}"
  rm -rf "${dest}.tmp"
}

prepare_openwrt_tools() {
  local dl

  dl="${BUILDDIR}/downloads"
  download "${OPENWRT_BASE_URL}/${OPENWRT_IB_TARBALL}" "${dl}/${OPENWRT_IB_TARBALL}"
  download "${OPENWRT_BASE_URL}/${OPENWRT_SDK_TARBALL}" "${dl}/${OPENWRT_SDK_TARBALL}"
  extract_single_dir_tarball "${dl}/${OPENWRT_IB_TARBALL}" "${IB_DIR}"
  extract_single_dir_tarball "${dl}/${OPENWRT_SDK_TARBALL}" "${SDK_DIR}"
}

sdk_write_config() {
  log "writing SDK config for OpenZFS build dependencies"
  cat > "${SDK_DIR}/.config" <<'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
CONFIG_DEVEL=y
CONFIG_PACKAGE_attr=y
CONFIG_PACKAGE_libaio=y
CONFIG_PACKAGE_libtirpc=y
CONFIG_PACKAGE_libatomic=y
CONFIG_PACKAGE_libblkid=y
CONFIG_PACKAGE_libuuid=y
CONFIG_PACKAGE_zlib=y
CONFIG_PACKAGE_libopenssl=y
# CONFIG_PACKAGE_libopenssl-afalg is not set
# CONFIG_PACKAGE_libopenssl-conf is not set
# CONFIG_PACKAGE_libopenssl-devcrypto is not set
# CONFIG_PACKAGE_libopenssl-legacy is not set
# CONFIG_PACKAGE_libopenssl-padlock is not set
# CONFIG_OPENSSL_ENGINE is not set
# CONFIG_OPENSSL_ENGINE_BUILTIN is not set
# CONFIG_OPENSSL_ENGINE_BUILTIN_AFALG is not set
# CONFIG_OPENSSL_ENGINE_BUILTIN_DEVCRYPTO is not set
# CONFIG_OPENSSL_ENGINE_BUILTIN_PADLOCK is not set
# CONFIG_PACKAGE_util-linux is not set
EOF
  run make -C "${SDK_DIR}" defconfig
}

prepare_sdk_staging() {
  local kbuild target toolchain

  if [ "${SDK_FORCE_REBUILD:-0}" != "1" ]; then
    kbuild="$(find_sdk_kernel_dir || true)"
    target="$(find_sdk_target_dir || true)"
    toolchain="$(find_sdk_toolchain_dir || true)"
    if [ -n "${kbuild}" ] && [ -n "${target}" ] && [ -n "${toolchain}" ] && [ -r "${kbuild}/Module.symvers" ]; then
      log "using existing SDK staging/kernel build outputs"
      return 0
    fi
  fi

  log "updating SDK feeds"
  run "${SDK_DIR}/scripts/feeds" update base packages
  run "${SDK_DIR}/scripts/feeds" install libtirpc libaio attr zlib openssl util-linux
  sdk_write_config

  log "building SDK staging dependencies for OpenZFS"
  run make -C "${SDK_DIR}" -j"${JOBS}" \
    package/feeds/packages/libtirpc/compile \
    package/feeds/packages/libaio/compile \
    package/feeds/packages/attr/compile \
    package/feeds/base/zlib/compile \
    package/feeds/base/openssl/compile \
    package/feeds/base/util-linux/compile
}

find_sdk_target_dir() {
  find "${SDK_DIR}/staging_dir" -maxdepth 1 -type d -name 'target-x86_64_*' | sort | tail -n 1
}

find_sdk_toolchain_dir() {
  find "${SDK_DIR}/staging_dir" -maxdepth 1 -type d -name 'toolchain-x86_64_*' | sort | tail -n 1
}

find_sdk_kernel_dir() {
  find "${SDK_DIR}/build_dir" -path '*/linux-x86_64/linux-*/Module.symvers' -type f -printf '%h\n' | sort -V | tail -n 1
}

sdk_cross_prefix() {
  local toolchain gcc

  toolchain="$(find_sdk_toolchain_dir)"
  [ -n "${toolchain}" ] || die "cannot locate SDK toolchain staging dir"
  gcc="$(find "${toolchain}/bin" -maxdepth 1 -type f -name '*-openwrt-linux-musl-gcc' | sort | head -n 1)"
  [ -n "${gcc}" ] || die "cannot locate SDK cross gcc"
  printf '%s' "${gcc%gcc}"
}

kernel_release() {
  local kbuild rel

  kbuild="$(find_sdk_kernel_dir)"
  [ -n "${kbuild}" ] || die "cannot locate SDK kernel build dir"
  if [ -r "${kbuild}/include/config/kernel.release" ]; then
    rel="$(cat "${kbuild}/include/config/kernel.release")"
  else
    rel="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "${kbuild}/include/generated/utsrelease.h")"
  fi
  [ -n "${rel}" ] || die "cannot determine kernel release"
  printf '%s' "${rel}"
}

find_tpm_crb_ko() {
  local ko

  if [ -n "${TPM_CRB_KO}" ]; then
    [ -f "${TPM_CRB_KO}" ] || die "TPM_CRB_KO does not exist: ${TPM_CRB_KO}"
    printf '%s' "${TPM_CRB_KO}"
    return 0
  fi

  ko="$(find "${TOPDIR}/dist/openwrt-release-build/src/openwrt-${OPENWRT_VERSION}" \
      -path '*/linux-x86_64/linux-*/drivers/char/tpm/tpm_crb.ko' \
      -type f 2>/dev/null | sort -V | tail -n 1)"
  [ -n "${ko}" ] || return 1
  printf '%s' "${ko}"
}

install_extra_kernel_modules() {
  local krel ko dest

  krel="$(kernel_release)"
  if ! ko="$(find_tpm_crb_ko)"; then
    die "missing tpm_crb.ko; build it with CONFIG_TCG_CRB=m or set TPM_CRB_KO=/path/to/tpm_crb.ko"
  fi

  dest="${FILES_DIR}/lib/modules/${krel}"
  mkdir -p "${dest}"
  log "installing extra kernel module tpm_crb.ko from ${ko}"
  install -m 0644 "${ko}" "${dest}/tpm_crb.ko"
  install -m 0644 "${ko}" "${dest}/tpm_crb.good.ko"
}

build_patched_kexec() {
  local tarball builddir install_dir patch_file hash

  if [ "${KEXEC_TOOLS_FORCE_REBUILD:-0}" != "1" ] && [ -x "${PATCHED_KEXEC}" ]; then
    log "using existing patched kexec: ${PATCHED_KEXEC}"
    return 0
  fi

  [ -d "${KEXEC_TOOLS_PATCH_DIR}" ] || die "missing kexec-tools patch directory: ${KEXEC_TOOLS_PATCH_DIR}"

  tarball="${BUILDDIR}/downloads/kexec-tools-${KEXEC_TOOLS_VERSION}.tar.xz"
  builddir="${BUILDDIR}/kexec-tools-${KEXEC_TOOLS_VERSION}-patched/src"
  install_dir="${BUILDDIR}/kexec-tools-${KEXEC_TOOLS_VERSION}-patched/install"

  download "${KEXEC_TOOLS_URL}" "${tarball}"
  hash="$(sha256sum "${tarball}" | awk '{print $1}')"
  [ "${hash}" = "${KEXEC_TOOLS_HASH}" ] || die "kexec-tools tarball hash mismatch: ${hash}"

  rm -rf "${builddir}" "${install_dir}"
  mkdir -p "${builddir}" "${install_dir}"
  run tar -xf "${tarball}" -C "${builddir}" --strip-components=1

  for patch_file in "${KEXEC_TOOLS_PATCH_DIR}"/*.patch; do
    [ -f "${patch_file}" ] || continue
    log "applying kexec-tools patch: ${patch_file}"
    ( cd "${builddir}" && patch -p1 < "${patch_file}" )
  done

  log "building patched kexec-tools ${KEXEC_TOOLS_VERSION}"
  (
    set -Eeuo pipefail
    cd "${builddir}"
    ./configure \
      --prefix=/usr \
      --sbindir=/usr/sbin \
      --without-zlib \
      --without-lzma
    make -j"${JOBS}"
    make DESTDIR="${install_dir}" install
  )

  [ -x "${PATCHED_KEXEC}" ] || die "patched kexec build did not produce ${PATCHED_KEXEC}"
  strip --strip-unneeded "${PATCHED_KEXEC}"
}

install_patched_kexec() {
  [ -x "${PATCHED_KEXEC}" ] || die "missing patched kexec binary: ${PATCHED_KEXEC}"

  log "installing patched kexec from ${PATCHED_KEXEC}"
  install -d "${FILES_DIR}/usr/sbin" "${FILES_DIR}/sbin"
  install -m 0755 "${PATCHED_KEXEC}" "${FILES_DIR}/usr/sbin/kexec"
  ln -snf ../usr/sbin/kexec "${FILES_DIR}/sbin/kexec"
}

build_zbm_setfont() {
  local cross

  [ -f "${ZBM_SETFONT_SRC}" ] || die "missing setfont source: ${ZBM_SETFONT_SRC}"

  if [ "${ZBM_SETFONT_FORCE_REBUILD:-0}" != "1" ] &&
     [ -x "${ZBM_SETFONT}" ] &&
     [ "${ZBM_SETFONT}" -nt "${ZBM_SETFONT_SRC}" ]; then
    log "using existing setfont helper: ${ZBM_SETFONT}"
    return 0
  fi

  cross="$(sdk_cross_prefix)"
  mkdir -p "$(dirname "${ZBM_SETFONT}")"
  log "building setfont helper"
  run env STAGING_DIR="${SDK_DIR}/staging_dir" \
    "${cross}gcc" -Os -Wall -Wextra -std=c99 -o "${ZBM_SETFONT}" "${ZBM_SETFONT_SRC}"
  "${cross}strip" --strip-unneeded "${ZBM_SETFONT}" || true
}

install_zbm_setfont() {
  build_zbm_setfont
  install -d "${FILES_DIR}/usr/bin"
  install -m 0755 "${ZBM_SETFONT}" "${FILES_DIR}/usr/bin/setfont"
}

install_extra_iwlwifi_firmware() {
  [ "${INSTALL_EXTRA_IWLWIFI_FIRMWARE:-1}" = "1" ] || return 0

  download_checked \
    "${EXTRA_IWLWIFI_FIRMWARE_URL}" \
    "${EXTRA_IWLWIFI_FIRMWARE}" \
    "${EXTRA_IWLWIFI_FIRMWARE_HASH}"
  download_checked \
    "${EXTRA_IWLWIFI_PNVM_URL}" \
    "${EXTRA_IWLWIFI_PNVM}" \
    "${EXTRA_IWLWIFI_PNVM_HASH}"

  log "installing extra iwlwifi firmware ${EXTRA_IWLWIFI_FIRMWARE_NAME} ${EXTRA_IWLWIFI_PNVM_NAME}"
  install -d "${FILES_DIR}/lib/firmware"
  install -m 0644 "${EXTRA_IWLWIFI_FIRMWARE}" \
    "${FILES_DIR}/lib/firmware/${EXTRA_IWLWIFI_FIRMWARE_NAME}"
  install -m 0644 "${EXTRA_IWLWIFI_PNVM}" \
    "${FILES_DIR}/lib/firmware/${EXTRA_IWLWIFI_PNVM_NAME}"
}

module_this_module_size() {
  readelf -S --wide "$1" | awk '
    $0 ~ /\.gnu\.linkonce\.this_module/ {
      for (i = 1; i <= NF; i++) {
        if ($i == ".gnu.linkonce.this_module") {
          print $(i + 4)
          found = 1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  '
}

install_cached_openzfs() {
  local install_root

  install_root="${1}"
  rsync -a "${install_root}/" "${FILES_DIR}/"
}

build_openzfs() {
  local src builddir kbuild target toolchain cross build_triplet krel install_root tmp_install

  if [ -n "${OPENZFS_DIR}" ]; then
    src="${OPENZFS_DIR}"
    [ -d "${src}" ] || die "OPENZFS_DIR does not exist: ${src}"
  else
    src="${SRCDIR}/zfs-${OPENZFS_REF}"
    clone_ref "${OPENZFS_REPO}" "${OPENZFS_REF}" "${src}"
  fi

  builddir="${src}"
  kbuild="$(find_sdk_kernel_dir)"
  target="$(find_sdk_target_dir)"
  toolchain="$(find_sdk_toolchain_dir)"
  cross="$(sdk_cross_prefix)"
  build_triplet="$(gcc -dumpmachine)"
  krel="$(kernel_release)"
  install_root="${OPENZFS_INSTALL_ROOT:-${BUILDDIR}/openzfs-${OPENZFS_REF}-${krel}/install}"

  [ -n "${kbuild}" ] || die "cannot locate SDK kernel build dir"
  [ -n "${target}" ] || die "cannot locate SDK target staging dir"
  [ -n "${toolchain}" ] || die "cannot locate SDK toolchain staging dir"
  [ -r "${kbuild}/Module.symvers" ] || die "SDK kernel lacks Module.symvers"

  if [ "${OPENZFS_FORCE_REBUILD:-0}" != "1" ] &&
     [ -x "${install_root}/usr/sbin/zfs" ] &&
     [ -e "${install_root}/lib/modules/${krel}/zfs.ko" ]; then
    log "using cached OpenZFS install tree: ${install_root}"
    install_cached_openzfs "${install_root}"
    return 0
  fi

  if [ -f "${builddir}/Makefile" ] && [ "${OPENZFS_FORCE_REBUILD:-0}" = "1" ]; then
    log "cleaning previous in-tree OpenZFS build artifacts"
    ( cd "${builddir}" && make distclean || make clean || true )
  fi

  tmp_install="${install_root}.tmp"
  rm -rf "${tmp_install}"
  mkdir -p "${tmp_install}"

  log "building OpenZFS ${OPENZFS_REF} for SDK kernel ${krel}"
  ( cd "${src}" && [ -x ./configure ] || ./autogen.sh )
  (
    set -Eeuo pipefail
    export STAGING_DIR="${SDK_DIR}/staging_dir"
    export PATH="${toolchain}/bin:${PATH}"
    export PKG_CONFIG_LIBDIR="${target}/usr/lib/pkgconfig:${target}/usr/share/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
    export CPPFLAGS="-I${target}/usr/include -I${target}/usr/include/tirpc"
    export CFLAGS="-Os -pipe -I${target}/usr/include -I${target}/usr/include/tirpc"
    export LDFLAGS="-L${target}/usr/lib -Wl,-rpath-link,${target}/usr/lib -Wl,-rpath-link,${builddir}/.libs"
    export KERNEL_CC="${cross}gcc"
    export KERNEL_LD="${cross}ld"
    export KERNEL_CROSS_COMPILE="${cross}"
    export KERNEL_ARCH="x86"
    cd "${builddir}"
    if [ ! -f Makefile ]; then
      "${src}/configure" \
        --build="${build_triplet}" \
        --host=x86_64-openwrt-linux-musl \
        --prefix=/usr \
        --sbindir=/usr/sbin \
        --libdir=/usr/lib \
        --with-config=all \
        --with-linux="${kbuild}" \
        --with-linux-obj="${kbuild}" \
        --disable-nls \
        --disable-pyzfs \
        --without-python \
        --without-dracutdir \
        --without-systemdunitdir \
        --without-systemdpresetdir \
        CC="${cross}gcc" \
        LD="${cross}ld" \
        AR="${cross}ar" \
        NM="${cross}nm" \
        OBJCOPY="${cross}objcopy" \
        RANLIB="${cross}ranlib" \
        STRIP="${cross}strip"
    else
      log "using existing OpenZFS configure output; set OPENZFS_FORCE_REBUILD=1 to force distclean"
    fi
    make -j"${JOBS}"
    make DESTDIR="${tmp_install}" install
  )

  rm -rf \
    "${tmp_install}/usr/include" \
    "${tmp_install}/usr/lib/pkgconfig" \
    "${tmp_install}/usr/share/doc" \
    "${tmp_install}/usr/share/man" \
    "${tmp_install}/usr/share/zfs/zfs-tests" \
    "${tmp_install}/usr/src" \
    "${tmp_install}no"

  mkdir -p "${tmp_install}/lib/modules/${krel}"
  for module in spl.ko zfs.ko; do
    local src rel dest

    src="$(find "${tmp_install}/lib/modules/${krel}" -mindepth 2 -type f -name "${module}" | sort | head -n 1)"
    [ -n "${src}" ] || continue
    rel="${src#"${tmp_install}/lib/modules/${krel}/"}"
    dest="${tmp_install}/lib/modules/${krel}/${module}"
    rm -f "${dest}"
    ln -snf "${rel}" "${dest}"
  done

  rm -rf "${install_root}"
  mkdir -p "$(dirname "${install_root}")"
  mv "${tmp_install}" "${install_root}"
  install_cached_openzfs "${install_root}"
}

install_zfsbootmenu() {
  local src

  if [ -n "${ZFSBOOTMENU_DIR}" ]; then
    src="${ZFSBOOTMENU_DIR}"
    [ -d "${src}/zfsbootmenu" ] || die "ZFSBOOTMENU_DIR lacks zfsbootmenu tree: ${src}"
  else
    src="${SRCDIR}/zfsbootmenu-${ZFSBOOTMENU_REF}"
    clone_ref "${ZFSBOOTMENU_REPO}" "${ZFSBOOTMENU_REF}" "${src}"
  fi

  log "installing ZFSBootMenu runtime from ${src}"
  run "${src}/install-tree.sh" "${src}/zfsbootmenu" "${FILES_DIR}"

  mkdir -p \
    "${FILES_DIR}/etc" \
    "${FILES_DIR}/lib" \
    "${FILES_DIR}/libexec/init.d" \
    "${FILES_DIR}/libexec/hooks" \
    "${FILES_DIR}/usr/share/docs/help-files" \
    "${FILES_DIR}/usr/share/zfsbootmenu/fonts"
  printf 'return 0\n' > "${FILES_DIR}/lib/profiling-lib.sh"
  chmod 0644 "${FILES_DIR}/lib/profiling-lib.sh"
  rsync -a "${src}/zfsbootmenu/init.d/" "${FILES_DIR}/libexec/init.d/"
  rsync -a "${src}/zfsbootmenu/hooks/" "${FILES_DIR}/libexec/hooks/"
  rsync -a "${src}/zfsbootmenu/help-files/" "${FILES_DIR}/usr/share/docs/help-files/"
  rsync -a "${src}/zfsbootmenu/fonts/" "${FILES_DIR}/usr/share/zfsbootmenu/fonts/"
  if [ -r "${src}/zfsbootmenu/zbm-release" ]; then
    install -m 0644 "${src}/zfsbootmenu/zbm-release" "${FILES_DIR}/etc/zbm-release"
  fi
}

install_clevis_scripts() {
  local src f

  if [ -n "${CLEVIS_DIR}" ]; then
    src="${CLEVIS_DIR}"
    [ -d "${src}/src" ] || die "CLEVIS_DIR lacks src tree: ${src}"
  else
    src="${SRCDIR}/clevis-${CLEVIS_REF}"
    clone_ref "${CLEVIS_REPO}" "${CLEVIS_REF}" "${src}"
  fi

  mkdir -p "${FILES_DIR}/usr/bin"

  log "installing Clevis shell runtime from ${src}"
  for f in \
    src/clevis \
    src/clevis-decrypt \
    src/pins/tpm2/clevis-decrypt-tpm2 \
    src/pins/tpm2/clevis-encrypt-tpm2 \
    src/pins/sss/clevis-decrypt-null \
    src/pins/sss/clevis-encrypt-null \
    src/pins/tang/clevis-decrypt-tang \
    src/pins/tang/clevis-encrypt-tang \
    src/pins/file/clevis-decrypt-file \
    src/pins/file/clevis-encrypt-file; do
    [ -f "${src}/${f}" ] || continue
    install -m 0755 "${src}/${f}" "${FILES_DIR}/usr/bin/${f##*/}"
  done
}

copy_donor_path() {
  local path src dst

  path="${1}"
  src="${HOST_TOOL_ROOTFS}${path}"
  [ -e "${src}" ] || return 0
  dst="${FILES_DIR}${path}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

install_donor_glibc_tools() {
  local tool fallback_root

  if [ ! -d "${HOST_TOOL_ROOTFS}" ]; then
    fallback_root="$(find_ib_rootfs_dir || true)"
    if [ -n "${fallback_root}" ] && [ -d "${fallback_root}/lib/x86_64-linux-gnu" ]; then
      log "HOST_TOOL_ROOTFS is missing; using previous ImageBuilder rootfs donor: ${fallback_root}"
      HOST_TOOL_ROOTFS="${fallback_root}"
    else
      die "missing HOST_TOOL_ROOTFS donor: ${HOST_TOOL_ROOTFS}"
    fi
  fi

  log "installing donor glibc tools required by Clevis/ZBM from ${HOST_TOOL_ROOTFS}"
  for tool in tpm2 fzf mawk head tail sort hostname nohup less; do
    copy_donor_path "/usr/bin/${tool}"
  done

  if [ -x "${FILES_DIR}/usr/bin/tpm2" ]; then
    find "${HOST_TOOL_ROOTFS}/usr/bin" -maxdepth 1 \( -type f -o -type l \) -name 'tpm2_*' -printf '%f\n' \
      | while read -r tool; do
          ln -snf tpm2 "${FILES_DIR}/usr/bin/${tool}"
        done
  fi

  if [ -d "${HOST_TOOL_ROOTFS}/lib/x86_64-linux-gnu" ]; then
    mkdir -p "${FILES_DIR}/lib"
    rm -rf "${FILES_DIR}/lib/x86_64-linux-gnu"
    cp -a "${HOST_TOOL_ROOTFS}/lib/x86_64-linux-gnu" "${FILES_DIR}/lib/"
  fi
  if [ -e "${HOST_TOOL_ROOTFS}/lib64/ld-linux-x86-64.so.2" ]; then
    mkdir -p "${FILES_DIR}/lib64"
    cp -a "${HOST_TOOL_ROOTFS}/lib64/ld-linux-x86-64.so.2" "${FILES_DIR}/lib64/"
  fi
}

install_repo_overlay() {
  [ -d "${OVERLAY_DIR}" ] || die "missing overlay directory: ${OVERLAY_DIR}"

  log "copying repository runtime overlay"
  rsync -a "${OVERLAY_DIR}/" "${FILES_DIR}/"

  mkdir -p "${FILES_DIR}/libexec/load_key.d" "${FILES_DIR}/etc/rc.d"
  install -m 0755 "${TOPDIR}/hooks/load_key_zfs_clevis_hook.sh" \
    "${FILES_DIR}/libexec/load_key.d/10-clevis-tpm2"
  ln -snf ../init.d/zbm-kcl-setup "${FILES_DIR}/etc/rc.d/S19zbm-kcl-setup"
}

prepare_files_overlay() {
  rm -rf "${FILES_DIR}"
  mkdir -p "${FILES_DIR}"

  install_zfsbootmenu
  install_clevis_scripts
  install_donor_glibc_tools
  install_repo_overlay
  install_extra_iwlwifi_firmware
  install_extra_kernel_modules
  install_patched_kexec
  install_zbm_setfont
}

sanitize_package_name() {
  sed 's/=.*//' | sed '/^$/d'
}

imagebuilder_packages() {
  {
    sanitize_package_name < "${WORLD_REF}" \
      | grep -Ev '^(base-files|kernel|libc|fzf|mawk|tpm2|tpm2-tools|kmod-tpm-crb|mwan3)$' \
      | grep -Ev '^(i915-firmware-dmc|kmod-acpi-video|kmod-backlight|kmod-dma-buf|kmod-drm.*)$' \
      | grep -Ev '(amdgpu|i915|nouveau|nvidia)'
    printf '%s\n' \
      apk-mbedtls \
      bash \
      bind-dig \
      blkid \
      conntrack \
      cryptsetup \
      ethtool \
      ip-full \
      iperf3 \
      iputils-arping \
      iputils-ping \
      iputils-tracepath \
      jose \
      jq \
      libatomic \
      libtirpc \
      mtr-nojson \
      netcat \
      pciutils \
      socat \
      ss \
      tcpdump \
      usbutils \
      -i915-firmware-dmc \
      -kmod-acpi-video \
      -kmod-backlight \
      -kmod-dma-buf \
      -kmod-drm \
      -kmod-drm-buddy \
      -kmod-drm-display-helper \
      -kmod-drm-exec \
      -kmod-drm-i915 \
      -kmod-drm-kms-helper \
      -kmod-drm-suballoc-helper \
      -kmod-drm-ttm \
      -kmod-drm-ttm-helper
  } | sort -u | tr '\n' ' '
}

build_imagebuilder_rootfs() {
  local packages rootfs_partsize

  [ -f "${WORLD_REF}" ] || die "missing package reference list: ${WORLD_REF}"
  packages="$(imagebuilder_packages)"
  rootfs_partsize="${ROOTFS_PARTSIZE:-512}"

  if [ "${IMAGEBUILDER_FULL_IMAGE:-0}" = "1" ]; then
    log "building Image Builder full image set"
    run make -C "${IB_DIR}" image PROFILE=generic ROOTFS_PARTSIZE="${rootfs_partsize}" PACKAGES="${packages}" FILES="${FILES_DIR}"
    return 0
  fi

  log "building Image Builder rootfs only"
  find "${IB_DIR}/build_dir" -maxdepth 2 -type d -name 'root-*' -prune -exec rm -rf {} +
  run env STAGING_DIR_HOST="${IB_DIR}/staging_dir/host" make -C "${IB_DIR}" \
    USER_PROFILE=generic \
    USER_PACKAGES="${packages}" \
    USER_FILES="${FILES_DIR}" \
    CONFIG_TARGET_ROOTFS_PARTSIZE="${rootfs_partsize}" \
    package_reload package_install prepare_rootfs
}

find_ib_rootfs_dir() {
  find "${IB_DIR}/build_dir" -maxdepth 2 -type d -name 'root-*' | sort | tail -n 1
}

create_initramfs() {
  local rootdir initfile

  rootdir="$(find_ib_rootfs_dir)"
  [ -n "${rootdir}" ] || die "cannot locate Image Builder rootfs"
  initfile="${IB_DIR}/target/linux/generic/other-files/init"
  [ -f "${initfile}" ] || die "missing OpenWrt initramfs init: ${initfile}"

  log "creating external initramfs from ${rootdir}"
  install -m 0755 "${initfile}" "${rootdir}/init"
  fakeroot -- sh -c "
    set -eu
    cd '${rootdir}'
    mkdir -p dev
    mknod -m 600 dev/console c 5 1 2>/dev/null || true
    mknod -m 666 dev/null c 1 3 2>/dev/null || true
    mknod -m 666 dev/zero c 1 5 2>/dev/null || true
    mknod -m 666 dev/tty c 5 0 2>/dev/null || true
    mknod -m 660 dev/tty0 c 4 0 2>/dev/null || true
    mknod -m 660 dev/tty1 c 4 1 2>/dev/null || true
    mknod -m 666 dev/random c 1 8 2>/dev/null || true
    mknod -m 666 dev/urandom c 1 9 2>/dev/null || true
    mkdir -p dev/pts
    find . -print0 | cpio --null -o -H newc --owner=0:0 | gzip -9n > '${INITRD}'
  "
}

validate_rootfs() {
  local rootdir krel missing path tpm_mod crb_mod tpm_module_size crb_module_size

  rootdir="$(find_ib_rootfs_dir)"
  [ -n "${rootdir}" ] || die "cannot locate Image Builder rootfs"
  krel="$(kernel_release)"
  missing=0

  log "validating rootfs at ${rootdir}"
  for path in \
    "/init" \
    "/bin/zfsbootmenu" \
    "/lib/profiling-lib.sh" \
    "/lib/zfsbootmenu-core.sh" \
    "/libexec/init.d/50-import-pools" \
    "/libexec/hooks/early-setup.d/30-console-autosize.sh" \
    "/libexec/load_key.d/10-clevis-tpm2" \
    "/etc/profile.d/zbm-autostart.sh" \
    "/usr/bin/zbm-kcl-apply" \
    "/usr/bin/zbm-auto-boot" \
    "/usr/bin/zbm-network-up" \
    "/etc/hotplug.d/iface/95-zbm-source-routes" \
    "/usr/bin/tput" \
    "/usr/bin/stty" \
    "/usr/bin/udevadm" \
    "/usr/bin/clevis" \
    "/usr/bin/clevis-decrypt-tpm2" \
    "/usr/bin/clevis-encrypt-tpm2" \
    "/usr/bin/tpm2" \
    "/usr/bin/fzf" \
    "/usr/bin/jose" \
    "/usr/bin/jq" \
    "/usr/bin/apk" \
    "/usr/bin/lspci" \
    "/usr/bin/lsusb" \
    "/usr/bin/tcpdump" \
    "/usr/bin/setfont" \
    "/usr/sbin/ss" \
    "/usr/bin/socat" \
    "/usr/bin/nc" \
    "/usr/bin/iperf3" \
    "/usr/sbin/mtr" \
    "/usr/bin/dig" \
    "/usr/bin/arping" \
    "/usr/bin/tracepath" \
    "/usr/bin/ping" \
    "/sbin/ip" \
    "/usr/sbin/ethtool" \
    "/usr/sbin/conntrack" \
    "/usr/sbin/blkid" \
    "/usr/sbin/wpad" \
    "/usr/sbin/wpa_supplicant" \
    "/usr/sbin/kexec" \
    "/usr/sbin/zfs" \
    "/usr/sbin/zpool" \
    "/lib/modules/${krel}/cfg80211.ko" \
    "/lib/modules/${krel}/mac80211.ko" \
    "/lib/modules/${krel}/iwlwifi.ko" \
    "/lib/modules/${krel}/iwldvm.ko" \
    "/lib/modules/${krel}/iwlmvm.ko" \
    "/lib/firmware/${EXTRA_IWLWIFI_FIRMWARE_NAME}" \
    "/lib/firmware/${EXTRA_IWLWIFI_PNVM_NAME}" \
    "/lib/modules/${krel}/atlantic.ko" \
    "/lib/modules/${krel}/i40e.ko" \
    "/lib/modules/${krel}/iavf.ko" \
    "/lib/modules/${krel}/ice.ko" \
    "/lib/modules/${krel}/ixgbe.ko" \
    "/lib/modules/${krel}/ixgbevf.ko" \
    "/lib/firmware/intel/ice/ddp/ice.pkg" \
    "/lib/modules/${krel}/usbnet.ko" \
    "/lib/modules/${krel}/asix.ko" \
    "/lib/modules/${krel}/ax88179_178a.ko" \
    "/lib/modules/${krel}/cdc_ether.ko" \
    "/lib/modules/${krel}/cdc_ncm.ko" \
    "/lib/modules/${krel}/rtl8150.ko" \
    "/lib/modules/${krel}/r8152.ko" \
    "/lib/modules/${krel}/spl.ko" \
    "/lib/modules/${krel}/zfs.ko" \
    "/lib/modules/${krel}/tpm_crb.ko" \
    "/lib/modules/${krel}/tpm_crb.good.ko"; do
    if [ ! -e "${rootdir}${path}" ] && [ ! -L "${rootdir}${path}" ]; then
      printf 'missing rootfs path: %s\n' "${path}" >&2
      missing=1
    fi
  done

  if ! grep -Rqs 'owrt.target_kcl_append' "${rootdir}/usr/bin/zbm-kcl-apply"; then
    printf 'missing target KCL support in zbm-kcl-apply\n' >&2
    missing=1
  fi

  if ! grep -Rqs 'owrt.autostart' "${rootdir}/usr/bin/zbm-kcl-apply"; then
    printf 'missing login autostart KCL support in zbm-kcl-apply\n' >&2
    missing=1
  fi

  if ! grep -Rqs 'zbm-autoboot.failed' "${rootdir}/usr/bin/zbm-auto-boot" ||
     ! grep -Rqs 'zbm-autoboot.failed' "${rootdir}/etc/profile.d/zbm-autostart.sh"; then
    printf 'missing auto-failure gated login autostart support\n' >&2
    missing=1
  fi

  if ! grep -Rqs 'is_zfs_filesystem()' "${rootdir}/lib/zfsbootmenu-core.sh"; then
    printf 'missing is_zfs_filesystem helper in zfsbootmenu-core.sh\n' >&2
    missing=1
  fi

  if ! grep -Rqs 'auto boot failed to load key' "${rootdir}/libexec/zfsbootmenu-init"; then
    printf 'missing auto-boot failure guard in zfsbootmenu-init\n' >&2
    missing=1
  fi

  if grep -Rqs 'exit 0' "${rootdir}/lib/profiling-lib.sh"; then
    printf 'profiling-lib.sh must not exit sourced callers\n' >&2
    missing=1
  fi

  tpm_mod="${rootdir}/lib/modules/${krel}/tpm.ko"
  crb_mod="${rootdir}/lib/modules/${krel}/tpm_crb.ko"
  if [ -e "${tpm_mod}" ] && [ -e "${crb_mod}" ]; then
    if ! tpm_module_size="$(module_this_module_size "${tpm_mod}")"; then
      printf 'cannot read .gnu.linkonce.this_module size from %s\n' "${tpm_mod}" >&2
      missing=1
    elif ! crb_module_size="$(module_this_module_size "${crb_mod}")"; then
      printf 'cannot read .gnu.linkonce.this_module size from %s\n' "${crb_mod}" >&2
      missing=1
    elif [ "${tpm_module_size}" != "${crb_module_size}" ]; then
      printf 'tpm_crb.ko ABI mismatch: this_module size %s, expected %s from tpm.ko\n' \
        "${crb_module_size}" "${tpm_module_size}" >&2
      missing=1
    fi
  fi

  [ "${missing}" = "0" ] || die "rootfs validation failed"
}

build_uki() {
  local kernel osrel cmdline krel

  kernel="${IB_DIR}/bin/targets/x86/64/openwrt-${OPENWRT_VERSION}-x86-64-generic-kernel.bin"
  [ -f "${kernel}" ] || die "missing Image Builder kernel: ${kernel}"
  [ -f "${INITRD}" ] || die "missing initramfs: ${INITRD}"
  [ -f "${STUB}" ] || die "missing systemd EFI stub: ${STUB}"

  mkdir -p "${OUTDIR}" "${BUILDDIR}"
  osrel="${BUILDDIR}/openwrt-zbm.os-release"
  cmdline="${BUILDDIR}/empty-cmdline"
  krel="$(kernel_release)"
  : > "${cmdline}"

  cat > "${osrel}" <<EOF
ID=openwrt
NAME="OpenWrt ZBM Clevis Lab"
PRETTY_NAME="OpenWrt ${OPENWRT_VERSION} ZBM Clevis Lab"
VERSION_ID="${OPENWRT_VERSION}"
EOF

  log "building UKI ${UKI}"
  run ukify build \
    --linux "${kernel}" \
    --initrd "${INITRD}" \
    --cmdline "@${cmdline}" \
    --os-release "@${osrel}" \
    --uname "${krel}" \
    --stub "${STUB}" \
    --efi-arch x64 \
    --output "${UKI}"

  run ukify inspect "${UKI}"
}

validate_uki_initrd() {
  local rootdir krel work path root_path uki_path root_hash uki_hash
  local -a required_paths

  rootdir="$(find_ib_rootfs_dir)"
  [ -n "${rootdir}" ] || die "cannot locate Image Builder rootfs"
  krel="$(kernel_release)"

  work="${BUILDDIR}/validate-uki-initrd"
  rm -rf "${work}"
  mkdir -p "${work}/extract"

  required_paths=(
    "lib/modules/${krel}/tpm_crb.ko"
    "lib/modules/${krel}/tpm_crb.good.ko"
    "lib/modules/${krel}/atlantic.ko"
    "lib/modules/${krel}/i40e.ko"
    "lib/modules/${krel}/iavf.ko"
    "lib/modules/${krel}/ice.ko"
    "lib/modules/${krel}/ixgbe.ko"
    "lib/modules/${krel}/ixgbevf.ko"
    "lib/firmware/intel/ice/ddp/ice.pkg"
  )

  cp -f "${UKI}" "${work}/uki.efi"
  run objcopy --dump-section ".initrd=${work}/initrd.gz" "${work}/uki.efi"
  (
    cd "${work}/extract"
    gzip -dc "${work}/initrd.gz" | cpio -id --quiet "${required_paths[@]}"
  )

  for path in "${required_paths[@]}"; do
    root_path="${rootdir}/${path}"
    uki_path="${work}/extract/${path}"
    [ -f "${root_path}" ] || die "missing rootfs path: ${root_path}"
    [ -f "${uki_path}" ] || die "missing ${path} in UKI initrd"
    root_hash="$(sha256sum "${root_path}" | awk '{print $1}')"
    uki_hash="$(sha256sum "${uki_path}" | awk '{print $1}')"
    if [ "${root_hash}" != "${uki_hash}" ]; then
      die "UKI initrd ${path} mismatch: ${uki_hash}, expected ${root_hash}"
    fi
  done
}

main() {
  for tool in git curl make gcc g++ python3 perl awk sed tar cpio gzip xz rsync zstd patch strip objcopy readelf ukify autoconf automake libtoolize pkg-config bison flex fakeroot; do
    need "${tool}"
  done

  mkdir -p "${BUILDDIR}" "${SRCDIR}" "${OUTDIR}"

  log "versions: OpenWrt=${OPENWRT_VERSION} ZFSBootMenu=${ZFSBOOTMENU_REF} Clevis=${CLEVIS_REF} OpenZFS=${OPENZFS_REF}"
  prepare_openwrt_tools
  prepare_sdk_staging
  build_patched_kexec
  prepare_files_overlay
  build_openzfs
  build_imagebuilder_rootfs
  create_initramfs
  validate_rootfs
  build_uki
  validate_uki_initrd

  log "UKI=${UKI}"
}

main "$@"
