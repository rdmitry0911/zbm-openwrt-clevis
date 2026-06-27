#!/usr/bin/env bash
set -Eeuo pipefail

TOPDIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.4}"
OPENWRT_TAG="${OPENWRT_TAG:-v${OPENWRT_VERSION}}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"

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
BUILDDIR="${BUILDDIR:-${TOPDIR}/dist/openwrt-release-build}"
SRCDIR="${SRCDIR:-${BUILDDIR}/src}"
OPENWRT_DIR="${OPENWRT_DIR:-${SRCDIR}/openwrt-${OPENWRT_VERSION}}"
OPENZFS_BUILD_DIR="${OPENZFS_BUILD_DIR:-${BUILDDIR}/build/openzfs-${OPENZFS_REF}}"
OUTDIR="${OUTDIR:-${TOPDIR}/dist}"
UKI="${UKI:-${OUTDIR}/openwrt-${OPENWRT_VERSION}-x86-64-generic-zbm-clevis.efi}"
STUB="${STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
WORLD_REF="${WORLD_REF:-${TOPDIR}/lab/openwrt-current-world.txt}"
OVERLAY_DIR="${OVERLAY_DIR:-${TOPDIR}/overlay}"
HOST_TOOL_ROOTFS="${HOST_TOOL_ROOTFS:-/tmp/openwrt-zbm-rootfs}"
WITH_GLIBC_TOOLS="${WITH_GLIBC_TOOLS:-1}"
SKIP_OPENWRT_BUILD="${SKIP_OPENWRT_BUILD:-0}"
SKIP_OPENZFS_BUILD="${SKIP_OPENZFS_BUILD:-0}"
FORCE_OPENWRT_KERNEL_CLEAN="${FORCE_OPENWRT_KERNEL_CLEAN:-1}"

log() {
  printf '[build-openwrt-release-uki] %s\n' "$*"
}

die() {
  printf '[build-openwrt-release-uki] ERROR: %s\n' "$*" >&2
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

sanitize_package_name() {
	sed 's/=.*//' | sed '/^$/d'
}

set_kernel_config() {
	local file key value

	file="${1}"
	key="${2}"
	value="${3}"

	sed -i -E "/^(# )?${key}(=| is not set)/d" "${file}"
	if [ "${value}" = "n" ]; then
	  printf '# %s is not set\n' "${key}" >> "${file}"
	else
	  printf '%s=%s\n' "${key}" "${value}" >> "${file}"
	fi
}

patch_openwrt_kernel_config() {
	local config

	config="${OPENWRT_DIR}/target/linux/x86/config-6.12"
	[ -f "${config}" ] || die "missing OpenWrt x86 kernel config: ${config}"

	log "patching OpenWrt x86 kernel config for modular zlib runtime"
	set_kernel_config "${config}" CONFIG_DECOMPRESS_GZIP n
	set_kernel_config "${config}" CONFIG_RD_GZIP n
	set_kernel_config "${config}" CONFIG_ZLIB_INFLATE n
}

write_openwrt_config() {
	local config pkg

	[ -f "${WORLD_REF}" ] || die "missing package reference list: ${WORLD_REF}"
  config="${OPENWRT_DIR}/.config"

  log "writing OpenWrt x86/64 initramfs config"
  {
    printf '%s\n' \
      'CONFIG_TARGET_x86=y' \
      'CONFIG_TARGET_x86_64=y' \
      'CONFIG_TARGET_x86_64_DEVICE_generic=y' \
	      'CONFIG_TARGET_ROOTFS_INITRAMFS=y' \
	      'CONFIG_TARGET_ROOTFS_EXT4FS=n' \
	      'CONFIG_TARGET_ROOTFS_SQUASHFS=n' \
	      'CONFIG_BUILD_LOG=y' \
	      'CONFIG_DEVEL=y'

    sanitize_package_name < "${WORLD_REF}" \
      | grep -Ev '^(base-files|kernel|libc)$' \
      | sort -u \
      | while read -r pkg; do
          printf 'CONFIG_PACKAGE_%s=y\n' "${pkg}"
        done

	    for pkg in libtirpc libatomic kmod-lib-zlib-deflate kmod-lib-zlib-inflate; do
	      printf 'CONFIG_PACKAGE_%s=y\n' "${pkg}"
	    done
	  } > "${config}"

  run make -C "${OPENWRT_DIR}" defconfig
}

prepare_openwrt() {
  clone_ref "${OPENWRT_REPO}" "${OPENWRT_TAG}" "${OPENWRT_DIR}"

	log "updating OpenWrt feeds"
	run "${OPENWRT_DIR}/scripts/feeds" update -a
	run "${OPENWRT_DIR}/scripts/feeds" install -a

	patch_openwrt_kernel_config
	write_openwrt_config
}

build_openwrt_base() {
  if [ "${SKIP_OPENWRT_BUILD}" = "1" ]; then
    log "skipping OpenWrt base build by request"
    return
	fi

	log "building OpenWrt base image and staging tree"
	if [ "${FORCE_OPENWRT_KERNEL_CLEAN}" = "1" ]; then
	  log "cleaning OpenWrt target kernel before base build"
	  run make -C "${OPENWRT_DIR}" target/linux/clean
	fi
	run make -C "${OPENWRT_DIR}" -j"${JOBS}"
}

find_one_dir() {
  local pattern
  pattern="${1}"
  find "${OPENWRT_DIR}" -path "${pattern}" -type d | sort | tail -n 1
}

find_rootfs_dir() {
  find "${OPENWRT_DIR}/build_dir" -maxdepth 1 -type d -name 'target-x86_64_*' \
    -exec find {} -mindepth 1 -maxdepth 1 -type d -name 'root-*' \; \
    | sort \
    | tail -n 1
}

find_target_dir() {
  find "${OPENWRT_DIR}/staging_dir" -maxdepth 1 -type d -name 'target-x86_64_*' | sort | tail -n 1
}

find_toolchain_dir() {
  find "${OPENWRT_DIR}/staging_dir" -maxdepth 1 -type d -name 'toolchain-x86_64_*' | sort | tail -n 1
}

find_kernel_build_dir() {
  find "${OPENWRT_DIR}/build_dir" -path '*/linux-x86_64' -type d \
    -exec find {} -maxdepth 1 -type d -name 'linux-[0-9]*' \; \
    | sort -V \
    | tail -n 1
}

kernel_release() {
  local kbuild rel

  kbuild="$(find_kernel_build_dir)"
  [ -n "${kbuild}" ] || die "cannot locate OpenWrt kernel build directory"
  if [ -r "${kbuild}/include/config/kernel.release" ]; then
    rel="$(cat "${kbuild}/include/config/kernel.release")"
  elif [ -r "${kbuild}/include/generated/utsrelease.h" ]; then
    rel="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "${kbuild}/include/generated/utsrelease.h")"
  else
    rel="$(make -s -C "${kbuild}" ARCH=x86 kernelrelease)"
  fi
  [ -n "${rel}" ] || die "cannot determine OpenWrt kernel release"
  printf '%s' "${rel}"
}

cross_prefix() {
  local toolchain gcc

  toolchain="$(find_toolchain_dir)"
  [ -n "${toolchain}" ] || die "cannot locate OpenWrt toolchain staging dir"
  gcc="$(find "${toolchain}/bin" -maxdepth 1 -type f -name '*-openwrt-linux-musl-gcc' | sort | head -n 1)"
  [ -n "${gcc}" ] || die "cannot locate OpenWrt cross gcc"
  printf '%s' "${gcc%gcc}"
}

prepare_kernel_external_modules() {
  local kbuild="$1" cross="$2"

  if [ -f "${kbuild}/.config.modules.save" ]; then
    log "restoring OpenWrt module-build kernel config for external OpenZFS build"
    cp -p "${kbuild}/.config.modules.save" "${kbuild}/.config"
  fi

  run env STAGING_DIR="${OPENWRT_DIR}/staging_dir" \
    make -C "${kbuild}" ARCH=x86 CROSS_COMPILE="${cross}" olddefconfig prepare modules_prepare
}

prune_openzfs_runtime() {
  local files

  files="${1}"

  log "pruning OpenZFS non-runtime files from overlay"
  rm -rf \
    "${files}/usr/include" \
    "${files}/usr/lib/pkgconfig" \
    "${files}/usr/share/doc" \
    "${files}/usr/share/man" \
    "${files}/usr/share/zfs/zfs-tests" \
    "${files}/usr/src" \
    "${files}no"
}

build_openzfs() {
  local src builddir kbuild target toolchain cross build_triplet files krel

  if [ "${SKIP_OPENZFS_BUILD}" = "1" ]; then
    log "skipping OpenZFS build by request"
    return
  fi

  if [ -n "${OPENZFS_DIR}" ]; then
    src="${OPENZFS_DIR}"
    [ -d "${src}" ] || die "OPENZFS_DIR does not exist: ${src}"
  else
    src="${SRCDIR}/zfs-${OPENZFS_REF}"
    clone_ref "${OPENZFS_REPO}" "${OPENZFS_REF}" "${src}"
  fi

  builddir="${src}"
  kbuild="$(find_kernel_build_dir)"
  target="$(find_target_dir)"
  toolchain="$(find_toolchain_dir)"
  cross="$(cross_prefix)"
  build_triplet="$(gcc -dumpmachine)"
  files="${OPENWRT_DIR}/files"
  krel="$(kernel_release)"

  [ -n "${kbuild}" ] || die "cannot locate kernel build dir"
  [ -n "${target}" ] || die "cannot locate target staging dir"
  [ -n "${toolchain}" ] || die "cannot locate toolchain staging dir"

  prepare_kernel_external_modules "${kbuild}" "${cross}"

  if [ -f "${builddir}/Makefile" ]; then
    log "cleaning previous in-tree OpenZFS build artifacts"
    (
      set -Eeuo pipefail
      cd "${builddir}"
      make distclean || make clean || true
    )
  fi

  log "building OpenZFS ${OPENZFS_REF} for OpenWrt kernel ${krel}"
  (
    set -Eeuo pipefail
    cd "${src}"
    [ -x ./configure ] || ./autogen.sh
  )

  (
    set -Eeuo pipefail
    export STAGING_DIR="${OPENWRT_DIR}/staging_dir"
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
    make -j"${JOBS}"
    make DESTDIR="${files}" install
  )

  prune_openzfs_runtime "${files}"

  mkdir -p "${files}/lib/modules/${krel}"
  find "${files}/lib/modules/${krel}" -type f \( -name 'spl.ko' -o -name 'zfs.ko' \) \
    -exec sh -c 'cp -f "$1" "$2/${1##*/}"' sh {} "${files}/lib/modules/${krel}" \;
}

install_zfsbootmenu() {
  local src files

  if [ -n "${ZFSBOOTMENU_DIR}" ]; then
    src="${ZFSBOOTMENU_DIR}"
    [ -d "${src}/zfsbootmenu" ] || die "ZFSBOOTMENU_DIR lacks zfsbootmenu tree: ${src}"
  else
    src="${SRCDIR}/zfsbootmenu-${ZFSBOOTMENU_REF}"
    clone_ref "${ZFSBOOTMENU_REPO}" "${ZFSBOOTMENU_REF}" "${src}"
  fi

  files="${OPENWRT_DIR}/files"
  log "installing ZFSBootMenu runtime from ${src}"
  run "${src}/install-tree.sh" "${src}/zfsbootmenu" "${files}"
}

install_clevis_scripts() {
  local src files f

  if [ -n "${CLEVIS_DIR}" ]; then
    src="${CLEVIS_DIR}"
    [ -d "${src}/src" ] || die "CLEVIS_DIR lacks src tree: ${src}"
  else
    src="${SRCDIR}/clevis-${CLEVIS_REF}"
    clone_ref "${CLEVIS_REPO}" "${CLEVIS_REF}" "${src}"
  fi

  files="${OPENWRT_DIR}/files"
  mkdir -p "${files}/usr/bin"

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
    install -m 0755 "${src}/${f}" "${files}/usr/bin/${f##*/}"
  done
}

copy_preserve_path() {
  local src root dst real

  src="${1}"
  root="${2}"

  [ -e "${src}" ] || return 0
  dst="${root}${src}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"

  real="$(readlink -f "${src}" 2>/dev/null || true)"
  if [ -n "${real}" ] && [ "${real}" != "${src}" ] && [ -e "${real}" ]; then
    mkdir -p "$(dirname "${root}${real}")"
    cp -a "${real}" "${root}${real}"
  fi
}

copy_host_elf_runtime() {
  local bin root interp dep

  bin="${1}"
  root="${2}"

  copy_preserve_path "${bin}" "${root}"

  interp="$(readelf -l "${bin}" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | head -n 1)"
  [ -z "${interp}" ] || copy_preserve_path "${interp}" "${root}"

  ldd "${bin}" 2>/dev/null \
    | awk '/=> \// { print $3 } /^\// { print $1 }' \
    | sort -u \
    | while read -r dep; do
        [ -n "${dep}" ] && copy_preserve_path "${dep}" "${root}"
      done
}

install_glibc_tools() {
  local files tool path fallback

  [ "${WITH_GLIBC_TOOLS}" = "1" ] || return 0

  files="${OPENWRT_DIR}/files"
  mkdir -p "${files}/usr/bin"

  log "installing host glibc tools required by Clevis/ZBM"
  for tool in jose jq tpm2 head tail sort hostname nohup mawk less; do
    path="$(command -v "${tool}" 2>/dev/null || true)"
    if [ -n "${path}" ]; then
      copy_host_elf_runtime "${path}" "${files}"
    else
      log "host tool not found, skipping: ${tool}"
    fi
  done

  fallback="${HOST_TOOL_ROOTFS}/usr/bin/fzf"
  path="$(command -v fzf 2>/dev/null || true)"
  if [ -n "${path}" ]; then
    copy_host_elf_runtime "${path}" "${files}"
  elif [ -x "${fallback}" ]; then
    log "using fzf from existing validated rootfs: ${fallback}"
    install -m 0755 "${fallback}" "${files}/usr/bin/fzf"
    if [ -d "${HOST_TOOL_ROOTFS}/lib/x86_64-linux-gnu" ]; then
      mkdir -p "${files}/lib"
      cp -a --update=none "${HOST_TOOL_ROOTFS}/lib/x86_64-linux-gnu" "${files}/lib/"
    fi
    if [ -e "${HOST_TOOL_ROOTFS}/lib64/ld-linux-x86-64.so.2" ]; then
      mkdir -p "${files}/lib64"
      cp -a --update=none "${HOST_TOOL_ROOTFS}/lib64/ld-linux-x86-64.so.2" "${files}/lib64/"
    fi
  else
    die "fzf is required for ZFSBootMenu TUI; install fzf or set HOST_TOOL_ROOTFS"
  fi

  if [ -x "${files}/usr/bin/tpm2" ]; then
    find /usr/bin -maxdepth 1 \( -type f -o -type l \) -name 'tpm2_*' -printf '%f\n' \
      | while read -r tool; do
          ln -snf tpm2 "${files}/usr/bin/${tool}"
        done
  fi
}

install_repo_overlay() {
  local files

  files="${OPENWRT_DIR}/files"
  [ -d "${OVERLAY_DIR}" ] || die "missing overlay directory: ${OVERLAY_DIR}"

  log "copying repository runtime overlay"
  rsync -a "${OVERLAY_DIR}/" "${files}/"

  mkdir -p "${files}/libexec/load_key.d" "${files}/etc/rc.d"
  install -m 0755 "${TOPDIR}/hooks/load_key_zfs_clevis_hook.sh" \
    "${files}/libexec/load_key.d/10-clevis-tpm2"
  ln -snf ../init.d/zbm-kcl-setup "${files}/etc/rc.d/S19zbm-kcl-setup"
}

prepare_runtime_overlay() {
  local files

  files="${OPENWRT_DIR}/files"
  rm -rf "${files}"
  mkdir -p "${files}"

  install_zfsbootmenu
  install_clevis_scripts
  install_glibc_tools
  install_repo_overlay
}

rebuild_openwrt_with_overlay() {
  local rootdir

  log "rebuilding OpenWrt image with runtime overlay"
  find "${OPENWRT_DIR}/build_dir" -maxdepth 3 -type d -name 'root-*' -prune -exec rm -rf {} +
  run make -C "${OPENWRT_DIR}" -j"${JOBS}"

  rootdir="$(find_rootfs_dir)"
  [ -n "${rootdir}" ] || die "cannot locate rebuilt OpenWrt rootfs"
}

validate_rootfs() {
  local rootdir krel missing

  rootdir="$(find_rootfs_dir)"
  [ -n "${rootdir}" ] || die "cannot locate rebuilt OpenWrt rootfs"
  krel="$(kernel_release)"
  missing=0

  log "validating rootfs at ${rootdir}"
  for path in \
    "/bin/zfsbootmenu" \
    "/lib/zfsbootmenu-core.sh" \
    "/libexec/load_key.d/10-clevis-tpm2" \
    "/usr/bin/zbm-kcl-apply" \
    "/usr/bin/zbm-auto-boot" \
    "/usr/bin/clevis" \
    "/usr/bin/clevis-decrypt-tpm2" \
    "/usr/bin/clevis-encrypt-tpm2" \
    "/usr/bin/tpm2" \
    "/usr/bin/fzf" \
    "/usr/sbin/zfs" \
	    "/usr/sbin/zpool" \
	    "/lib/modules/${krel}/zlib_inflate.ko" \
	    "/lib/modules/${krel}/zlib_deflate.ko" \
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

  if ! grep -Rqs 'ZBM_TARGET_CONSOLE_ROTATE' "${rootdir}/lib/zfsbootmenu-core.sh"; then
    printf 'missing target console rotation support in zfsbootmenu-core.sh\n' >&2
    missing=1
  fi

  [ "${missing}" = "0" ] || die "rootfs validation failed"
}

build_uki() {
  local kernel osrel cmdline krel

  kernel="${OPENWRT_DIR}/bin/targets/x86/64/openwrt-x86-64-generic-initramfs-kernel.bin"
  [ -f "${kernel}" ] || die "missing OpenWrt initramfs kernel: ${kernel}"
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
    --cmdline "@${cmdline}" \
    --os-release "@${osrel}" \
    --uname "${krel}" \
    --stub "${STUB}" \
    --efi-arch x64 \
    --output "${UKI}"

  run ukify inspect "${UKI}"
}

main() {
  for tool in git curl make gcc g++ python3 perl awk sed tar gzip cpio rsync unzip bzip2 xz patch objcopy readelf ldd ukify autoconf automake libtoolize pkg-config bison flex; do
    need "${tool}"
  done

  mkdir -p "${BUILDDIR}" "${SRCDIR}" "${OUTDIR}"

  log "versions: OpenWrt=${OPENWRT_TAG} ZFSBootMenu=${ZFSBOOTMENU_REF} Clevis=${CLEVIS_REF} OpenZFS=${OPENZFS_REF}"
  prepare_openwrt
  build_openwrt_base
  prepare_runtime_overlay
  build_openzfs
  rebuild_openwrt_with_overlay
  validate_rootfs
  build_uki

  log "UKI=${UKI}"
}

main "$@"
