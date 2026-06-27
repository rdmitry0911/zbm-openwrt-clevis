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

build_openzfs() {
  local src builddir kbuild target toolchain cross build_triplet krel

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

  [ -n "${kbuild}" ] || die "cannot locate SDK kernel build dir"
  [ -n "${target}" ] || die "cannot locate SDK target staging dir"
  [ -n "${toolchain}" ] || die "cannot locate SDK toolchain staging dir"
  [ -r "${kbuild}/Module.symvers" ] || die "SDK kernel lacks Module.symvers"

  if [ -f "${builddir}/Makefile" ] && [ "${OPENZFS_FORCE_REBUILD:-0}" = "1" ]; then
    log "cleaning previous in-tree OpenZFS build artifacts"
    ( cd "${builddir}" && make distclean || make clean || true )
  fi

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
    make DESTDIR="${FILES_DIR}" install
  )

  rm -rf \
    "${FILES_DIR}/usr/include" \
    "${FILES_DIR}/usr/lib/pkgconfig" \
    "${FILES_DIR}/usr/share/doc" \
    "${FILES_DIR}/usr/share/man" \
    "${FILES_DIR}/usr/share/zfs/zfs-tests" \
    "${FILES_DIR}/usr/src" \
    "${FILES_DIR}no"

  mkdir -p "${FILES_DIR}/lib/modules/${krel}"
  for module in spl.ko zfs.ko; do
    local src rel dest

    src="$(find "${FILES_DIR}/lib/modules/${krel}" -mindepth 2 -type f -name "${module}" | sort | head -n 1)"
    [ -n "${src}" ] || continue
    rel="${src#"${FILES_DIR}/lib/modules/${krel}/"}"
    dest="${FILES_DIR}/lib/modules/${krel}/${module}"
    rm -f "${dest}"
    ln -snf "${rel}" "${dest}"
  done
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
  local tool

  [ -d "${HOST_TOOL_ROOTFS}" ] || die "missing HOST_TOOL_ROOTFS donor: ${HOST_TOOL_ROOTFS}"

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
}

sanitize_package_name() {
  sed 's/=.*//' | sed '/^$/d'
}

imagebuilder_packages() {
  {
    sanitize_package_name < "${WORLD_REF}" \
      | grep -Ev '^(base-files|kernel|libc|fzf|mawk|tpm2|tpm2-tools|kmod-tpm-crb)$'
    printf '%s\n' \
      bash \
      cryptsetup \
      jose \
      jq \
      libatomic \
      libtirpc \
      coreutils \
      gawk \
      less
  } | sort -u | tr '\n' ' '
}

build_imagebuilder_rootfs() {
  local packages rootfs_partsize

  [ -f "${WORLD_REF}" ] || die "missing package reference list: ${WORLD_REF}"
  packages="$(imagebuilder_packages)"
  rootfs_partsize="${ROOTFS_PARTSIZE:-512}"

  log "building Image Builder rootfs"
  run make -C "${IB_DIR}" image PROFILE=generic ROOTFS_PARTSIZE="${rootfs_partsize}" PACKAGES="${packages}" FILES="${FILES_DIR}"
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
  local rootdir krel missing path

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
    "/usr/bin/zbm-kcl-apply" \
    "/usr/bin/zbm-auto-boot" \
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
    "/usr/sbin/zfs" \
    "/usr/sbin/zpool" \
    "/lib/modules/${krel}/spl.ko" \
    "/lib/modules/${krel}/zfs.ko"; do
    if [ ! -e "${rootdir}${path}" ]; then
      printf 'missing rootfs path: %s\n' "${path}" >&2
      missing=1
    fi
  done

  if ! grep -Rqs 'owrt.target_kcl_append' "${rootdir}/usr/bin/zbm-kcl-apply"; then
    printf 'missing target KCL support in zbm-kcl-apply\n' >&2
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

main() {
  for tool in git curl make gcc g++ python3 perl awk sed tar cpio gzip rsync zstd patch objcopy readelf ukify autoconf automake libtoolize pkg-config bison flex fakeroot; do
    need "${tool}"
  done

  mkdir -p "${BUILDDIR}" "${SRCDIR}" "${OUTDIR}"

  log "versions: OpenWrt=${OPENWRT_VERSION} ZFSBootMenu=${ZFSBOOTMENU_REF} Clevis=${CLEVIS_REF} OpenZFS=${OPENZFS_REF}"
  prepare_openwrt_tools
  prepare_sdk_staging
  prepare_files_overlay
  build_openzfs
  build_imagebuilder_rootfs
  create_initramfs
  validate_rootfs
  build_uki

  log "UKI=${UKI}"
}

main "$@"
