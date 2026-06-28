case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ -z "${ZBM_AUTOSTART_PROFILE_DONE:-}" ] || return 0 2>/dev/null || exit 0
export ZBM_AUTOSTART_PROFILE_DONE=1

_zbm_autostart=
for _zbm_autostart_file in /run/zbm-runtime/kcl.env /etc/zfsbootmenu-kcl.env; do
  [ -r "${_zbm_autostart_file}" ] || continue
  _zbm_autostart="$(sed -n 's/^ZBM_AUTOSTART=//p' "${_zbm_autostart_file}" | tail -n 1)"
  [ -n "${_zbm_autostart}" ] && break
done

case "${_zbm_autostart}" in
  y|Y|yes|YES|Yes|1|true|TRUE|True|on|ON|On) ;;
  *)
    unset _zbm_autostart _zbm_autostart_file
    return 0 2>/dev/null || exit 0
    ;;
esac

_zbm_autostart_wait=0
while [ -e /run/zbm-autoboot.pending ] && [ ! -e /run/zbm-autoboot.done ] && [ "${_zbm_autostart_wait}" -lt 60 ]; do
  sleep 1
  _zbm_autostart_wait=$((_zbm_autostart_wait + 1))
done

if [ -e /run/zbm-autoboot.pending ] && [ ! -e /run/zbm-autoboot.done ]; then
  echo "zbm-auto-boot is still running; run zbm-start after it finishes." >&2
elif [ ! -e /run/zbm-autoboot.failed ]; then
  :
else
  printf '<6>%s\n' '[zbm-autostart] entering zbm-start from login profile' >/dev/kmsg 2>/dev/null || true
  [ -x /usr/bin/zbm-start ] && /usr/bin/zbm-start
fi

unset _zbm_autostart _zbm_autostart_file _zbm_autostart_wait
