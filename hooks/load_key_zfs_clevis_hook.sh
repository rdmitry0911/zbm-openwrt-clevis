#!/bin/bash

[ -r /etc/zfsbootmenu-kcl.env ] && source /etc/zfsbootmenu-kcl.env
[ -r /run/zbm-runtime/kcl.env ] && source /run/zbm-runtime/kcl.env

###############
### clevis hook
###############

#   Requirements:
#
# - OTB clevis (full set) and optionally dropbear packages are embedded in zfsbootmenu
# - latchset.clevis:decrypt=yes user property has to be added in advance to the encrypted dataset for automatic decryption
#   The value of this property should be authorized key for ssh login to zfsbootmenu as a root. 
#   Valid example: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhw5gGy/g9CM8PlB23Ag1RMgPfUoXu2tKELP9FIOcK4 rdmitry0911@gmail.com"
#   These properties are used to configure root ssh accsess to ZBM. I use this way of passing dropbear config to avoid rebuilding of ZBM 
#   for running on another host. In case there is no need to access ZBM via ssh these properties are not needed
# - /boot directory should reside inside the encrypted dataset
# - keylocation of the encrypted dataset should be set to file:///some/file Valid example: file:///etc/zfs/keys/rpool.key and this file
#   should be embedded to initramfs of the target system. It is safe as initramfs  is located in encrypted /boot directory (see ove note)
# - To avoid conflicts with existing files in ZBM, it is a good idea to create a subfolder in /etc/zfs and put a keyfile there with 
#   unique name
#
#
# The logic of the module is this:
# - Before asking the passphrase in zfsbootmenu this module checks if the volume is eligable for automatic unlocking
# - if yes, it
#       1. Trys to decrypt the passphrase stored in a special property in encrypted format. The script uses clevis and tpm2 for that
#       2. In case of failure it asks the user a passphrase and check if it is valid
#       3. Valid passphrase is stored in clear text in keylocation (in fact in RAM) and in encrypted format bound to tpm2 in a special
#          user property latchset.clevis:jwe of the encrypted dataset for next boots
# - Then module returns the control back to ZBM
#
# arg1: ZFS filesystem
# prints: nothing
# asks: passphrase
# returns: 0 on success, 1 on failure
#

CLEVIS_CHECK_1=""
CLEVIS_CHECK_4=""
CLEVIS_CHECK_5=""
CLEVIS_CHECK_7=""
CLEVIS_CHECK_9=""
CLEVIS_HOOK_LOG=/tmp/load-key-clevis-hook.log

init_hook_log()
{
  : > "${CLEVIS_HOOK_LOG}" 2>/dev/null || true
  chmod 0600 "${CLEVIS_HOOK_LOG}" 2>/dev/null || true
}

log_hook()
{
  local level pri msg

  level="${1:-notice}"
  msg="${2:-}"

  [ -n "${msg}" ] || return 0
  printf '%s\n' "${msg}" >> "${CLEVIS_HOOK_LOG}" 2>/dev/null || true

  if command -v logger >/dev/null 2>&1; then
    logger -t zbm-clevis-hook -- "${msg}" 2>/dev/null || true
  fi

  case "${level}" in
    debug) pri=7 ;;
    info|notice) pri=6 ;;
    warn|warning) pri=4 ;;
    err|error) pri=3 ;;
    *) pri=5 ;;
  esac

  printf '<%s>%s\n' "${pri}" "[zbm-clevis-hook] ${msg}" >/dev/kmsg 2>/dev/null || true
}

clevis_decrypt_to_file()
{
  local payload="$1"
  local outfile="$2"

  printf '%s' "${payload}" | clevis decrypt > "${outfile}" 2>>"${CLEVIS_HOOK_LOG}"
}

clevis_decrypt_check()
{
  local payload="$1"

  printf '%s' "${payload}" | clevis decrypt > /dev/null 2>>"${CLEVIS_HOOK_LOG}"
}

zfs_load_key_check_file()
{
  local dataset="$1"
  local path="$2"

  zfs load-key -L "file://${path}" -n "${dataset}" > /dev/null 2>>"${CLEVIS_HOOK_LOG}"
}

zfs_load_key_check_prompt()
{
  local dataset="$1"
  local pass="$2"

  printf '%s' "${pass}" | zfs load-key -n -L prompt "${dataset}" > /dev/null 2>>"${CLEVIS_HOOK_LOG}"
}

pcr_check_status()
{
  local payload="$1"

  [ -n "${payload}" ] || {
    printf '%s' '-'
    return 0
  }

  if clevis_decrypt_check "${payload}"; then
    printf '%s' 'OK'
  else
    printf '%s' 'FAIL'
  fi
}

kcl_get()
{
        local key value

        for key in "$@"; do
                case "$key" in
                        clevis.decrypt)
                                [ -n "${ZBM_CLEVIS_DECRYPT:-}" ] && { printf '%s' "${ZBM_CLEVIS_DECRYPT}"; return 0; }
                                ;;
                        clevis.store)
                                [ -n "${ZBM_CLEVIS_STORE:-}" ] && { printf '%s' "${ZBM_CLEVIS_STORE}"; return 0; }
                                ;;
                        clevis.file_location)
                                [ -n "${ZBM_CLEVIS_FILE_LOCATION:-}" ] && { printf '%s' "${ZBM_CLEVIS_FILE_LOCATION}"; return 0; }
                                ;;
                        clevis.pcr_ids)
                                [ -n "${ZBM_CLEVIS_PCR_IDS:-}" ] && { printf '%s' "${ZBM_CLEVIS_PCR_IDS}"; return 0; }
                                ;;
                        clevis.host)
                                [ -n "${ZBM_HOST:-}" ] && { printf '%s' "${ZBM_HOST}"; return 0; }
                                ;;
                        clevis.CHAT_ID)
                                [ -n "${ZBM_CLEVIS_CHAT_ID:-}" ] && { printf '%s' "${ZBM_CLEVIS_CHAT_ID}"; return 0; }
                                ;;
                        clevis.API_TOKEN)
                                [ -n "${ZBM_CLEVIS_API_TOKEN:-}" ] && { printf '%s' "${ZBM_CLEVIS_API_TOKEN}"; return 0; }
                                ;;
                esac

                value="$(awk -v key="${key}" '
                        {
                                for (i = 1; i <= NF; i++) {
                                        if ($i ~ ("^" key "=")) {
                                                sub("^" key "=", "", $i)
                                                print $i
                                                exit
                                        }
                                }
                        }
                ' /proc/cmdline)"
                [ -n "${value}" ] && { printf '%s' "${value}"; return 0; }
        done

        return 1
}

detect_host_name()
{
  local host

  host="$(kcl_get clevis.host owrt.host || true)"
  [ -n "${host}" ] || host="$(hostname 2>/dev/null || true)"
  [ -n "${host}" ] || host="$(uname -n 2>/dev/null || true)"
  printf '%s' "${host:-unknown-host}"
}

discover_ifname()
{
  local ifn

  for ifn in /sys/class/net/*; do
    ifn="${ifn##*/}"
    [ "${ifn}" = "lo" ] && continue
    printf '%s\n' "${ifn}"
    return 0
  done
  return 1
}

detect_primary_ip()
{
  local ip target_if

  target_if="${ZBM_NET_IFNAME:-}"
  [ -n "${target_if}" ] || target_if="$(discover_ifname || true)"
  if command -v ip >/dev/null 2>&1; then
    if [ -n "${target_if}" ]; then
      ip="$(ip -o -4 addr show dev "${target_if}" scope global 2>/dev/null | awk '
        {
          split($4, a, "/")
          print a[1]
          exit
        }
      ')"
    fi
    if [ -z "${ip:-}" ]; then
      ip="$(ip -o -4 addr show up scope global 2>/dev/null | awk '
        $2 != "lo" {
          split($4, a, "/")
          print a[1]
          exit
        }
      ')"
    fi
  fi

  if [ -z "${ip:-}" ] && command -v ifconfig >/dev/null 2>&1; then
    ip="$(ifconfig 2>/dev/null | awk '
      /^[a-zA-Z0-9]/ { iface=$1; sub(/:$/, "", iface) }
      $1 == "inet" && iface != "lo" { print $2; exit }
      /inet addr:/ && iface != "lo" {
        sub(/^addr:/, "", $2)
        print $2
        exit
      }
    ')"
  fi

  printf '%s' "${ip:-unknown-ip}"
}

apply_runtime_network_for_notify()
{
  if [ -x /usr/bin/zbm-network-up ]; then
    if /usr/bin/zbm-network-up >>"${CLEVIS_HOOK_LOG}" 2>&1; then
      log_hook notice "telegram notify: runtime network reapplied from kcl"
    else
      log_hook warn "telegram notify: runtime network reapply failed"
    fi
  fi
}

wait_for_network()
{
  local tries ip

  tries="${1:-10}"
  while [ "${tries}" -gt 0 ]; do
    ip="$(detect_primary_ip)"
    if [ -n "${ip}" ] && [ "${ip}" != "unknown-ip" ]; then
      return 0
    fi
    sleep 1
    tries=$((tries - 1))
  done

  return 1
}

url_encode()
{
  local input output i char hex

  input="${1}"
  output=""

  LC_ALL=C
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-])
        output="${output}${char}"
        ;;
      *)
        printf -v hex '%02X' "'${char}"
        output="${output}%${hex}"
        ;;
    esac
  done

  printf '%s' "${output}"
}

send_telegram_message()
{
  local token chat text body rc response_file response_text stderr_file stderr_text client

  token="$(kcl_get clevis.API_TOKEN || true)"
  chat="$(kcl_get clevis.CHAT_ID || true)"
  text="${1}"

  [ -n "${token}" ] || {
    log_hook debug "telegram notify skipped: clevis.API_TOKEN is empty"
    return 0
  }
  [ -n "${chat}" ] || {
    log_hook debug "telegram notify skipped: clevis.CHAT_ID is empty"
    return 0
  }
  if command -v uclient-fetch >/dev/null 2>&1; then
    client="uclient-fetch"
  elif command -v wget >/dev/null 2>&1; then
    client="wget"
  else
    log_hook warn "telegram notify skipped: no HTTPS client is available in runtime"
    return 0
  fi

  apply_runtime_network_for_notify

  if wait_for_network 15; then
    log_hook notice "telegram notify: network became ready before send"
  else
    log_hook warn "telegram notify: network still not ready, trying ${client} anyway"
  fi

  body="chat_id=$(url_encode "${chat}")&text=$(url_encode "${text}")"
  response_file="$(mktemp)"
  stderr_file="$(mktemp)"
  "${client}" -q -O "${response_file}" --timeout=15 \
    --header='Content-Type: application/x-www-form-urlencoded' \
    --post-data="${body}" \
    "https://api.telegram.org/bot${token}/sendMessage" \
    2>"${stderr_file}"
  rc=$?

  response_text="$(tr '\n' ' ' < "${response_file}" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
  stderr_text="$(tr '\n' ' ' < "${stderr_file}" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
  rm -f "${response_file}"
  rm -f "${stderr_file}"

  if [ "${rc}" -eq 0 ]; then
    log_hook notice "telegram notify: ${client} rc=${rc}"
    [ -n "${response_text}" ] && log_hook debug "telegram notify response: ${response_text}"
    [ -n "${stderr_text}" ] && log_hook debug "telegram notify ${client} stderr: ${stderr_text}"
  else
    log_hook warn "telegram notify: ${client} rc=${rc}"
    [ -n "${response_text}" ] && log_hook warn "telegram notify response: ${response_text}"
    [ -n "${stderr_text}" ] && log_hook warn "telegram notify ${client} stderr: ${stderr_text}"
  fi
}

pcr_status_summary()
{
  printf '1=%s 4=%s 5=%s 7=%s 9=%s' \
    "${CLEVIS_CHECK_1:--}" \
    "${CLEVIS_CHECK_4:--}" \
    "${CLEVIS_CHECK_5:--}" \
    "${CLEVIS_CHECK_7:--}" \
    "${CLEVIS_CHECK_9:--}"
}

failed_pcr_list()
{
  local configured item status out

  configured="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"
  out=""

  OLDIFS="${IFS}"
  IFS=', '
  for item in ${configured}; do
    case "${item}" in
      1) status="${CLEVIS_CHECK_1:--}" ;;
      4) status="${CLEVIS_CHECK_4:--}" ;;
      5) status="${CLEVIS_CHECK_5:--}" ;;
      7) status="${CLEVIS_CHECK_7:--}" ;;
      9) status="${CLEVIS_CHECK_9:--}" ;;
      *) status="-" ;;
    esac
    if [ "${status}" = "FAIL" ]; then
      [ -z "${out}" ] && out="${item}" || out="${out},${item}"
    fi
  done
  IFS="${OLDIFS}"

  printf '%s' "${out:-none}"
}

notify_autoboot_failure()
{
  local dataset reason host ip msg pcr_ids pcr_status pcr_failed

  is_manual_phase && return 0

  dataset="${1}"
  reason="${2}"
  host="$(detect_host_name)"
  ip="$(detect_primary_ip)"
  pcr_ids="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"
  pcr_status="$(pcr_status_summary)"
  pcr_failed="$(failed_pcr_list)"
  msg="Clevis auto-unlock failed on ${host}
IP: ${ip}
Dataset: ${dataset}
Reason: ${reason}
Configured PCRs: ${pcr_ids}
PCR status: ${pcr_status}
Failed PCRs: ${pcr_failed}"

  send_telegram_message "${msg}"
}

get_fs_value()
{
        fs="$1"
        value=$2

        zfs get -H -ovalue "$value" "$fs" 2> /dev/null
}

store_clevis_jwe_zfs()
{
  local dataset="$1"

  zfs set latchset.clevis:jwe="$(cat /tmp/clevis_zfs.jwe)" "$dataset" || return 1
  zfs set latchset.clevis:jwe_1="$(cat /tmp/clevis_zfs_1.jwe)" "$dataset" || return 1
  zfs set latchset.clevis:jwe_4="$(cat /tmp/clevis_zfs_4.jwe)" "$dataset" || return 1
  zfs set latchset.clevis:jwe_5="$(cat /tmp/clevis_zfs_5.jwe)" "$dataset" || return 1
  zfs set latchset.clevis:jwe_7="$(cat /tmp/clevis_zfs_7.jwe)" "$dataset" || return 1
  zfs set latchset.clevis:jwe_9="$(cat /tmp/clevis_zfs_9.jwe)" "$dataset" || return 1
}

ensure_efivarfs()
{
  if ! grep -q '[[:space:]]efivarfs$' /proc/filesystems 2>/dev/null; then
    modpath="/lib/modules/$(uname -r)/efivarfs.ko"
    [ -f "${modpath}" ] && insmod "${modpath}" >/dev/null 2>&1 || true
  fi
  mkdir -p /sys/firmware/efi/efivars
  if ! awk '$2 == target { found=1 } END { exit !found }' target="/sys/firmware/efi/efivars" /proc/mounts; then
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars || return 1
  fi
}

read_efivar_payload()
{
  local name="$1"

  efivar -n "${name}" -p 2>/dev/null | awk -F'|' '
    {
      field=$2
      gsub(/^[[:space:]]+/, "", field)
      gsub(/[[:space:]]+$/, "", field)
      aggr=aggr field
    }
    END {
      print aggr
    }
  '
}

mount_jwe_store()
{
  local spec="$1"
  local mode="${2:-rw}"
  local dev dir

  IFS=':' read -r dev dir <<< "${spec}"
  [ -n "${dev}" ] || return 1

  ZBM_CLEVIS_STORE_DEV="${dev}"
  ZBM_CLEVIS_STORE_DIR="${dir#/}"
  ZBM_CLEVIS_STORE_MNT="/tmp/jwe_mount"

  mkdir -p "${ZBM_CLEVIS_STORE_MNT}"
  mount "${ZBM_CLEVIS_STORE_DEV}" "${ZBM_CLEVIS_STORE_MNT}" || return 1
  [ -n "${ZBM_CLEVIS_STORE_DIR}" ] && mkdir -p "${ZBM_CLEVIS_STORE_MNT}/${ZBM_CLEVIS_STORE_DIR}"
  if [ "${mode}" = "rw" ]; then
    mount -o rw,remount "${ZBM_CLEVIS_STORE_MNT}" >/dev/null 2>&1 || true
  else
    mount -o ro,remount "${ZBM_CLEVIS_STORE_MNT}" >/dev/null 2>&1 || true
  fi
}

umount_jwe_store()
{
  sync >/dev/null 2>&1 || true
  if awk '$2 == target { found=1 } END { exit !found }' target="/tmp/jwe_mount" /proc/mounts; then
    umount /tmp/jwe_mount >/dev/null 2>&1 || true
  fi
  rm -rf /tmp/jwe_mount
}

read_jwe_store_file()
{
  local name="$1"
  local path="${ZBM_CLEVIS_STORE_MNT}"

  [ -n "${ZBM_CLEVIS_STORE_DIR:-}" ] && path="${path}/${ZBM_CLEVIS_STORE_DIR}"
  cat "${path}/${name}"
}

write_jwe_store_file()
{
  local src="$1"
  local name="$2"
  local path="${ZBM_CLEVIS_STORE_MNT}"

  [ -n "${ZBM_CLEVIS_STORE_DIR:-}" ] && path="${path}/${ZBM_CLEVIS_STORE_DIR}"
  cp "${src}" "${path}/${name}"
}

with_rw_pool()
{
  local pool="$1"
  local ro_state rc=0 flipped=0
  shift

  ro_state="$(zpool get -H -p -o value readonly "$pool" 2>/dev/null || true)"
  if [[ "$ro_state" == "on" ]]; then
    zpool export "$pool" || return 1
    zpool import -N -o readonly=off "$pool" || return 1
    flipped=1
  fi

  "$@" || rc=$?

  if [[ "$flipped" == "1" ]]; then
    zpool export "$pool" || true
    zpool import -N -o readonly=on "$pool" || true
  fi

  return "$rc"
}

is_manual_phase()
{
  [ -e /run/zbm-autoboot.done ]
}

reset_pcr_statuses()
{
  CLEVIS_CHECK_1="-"
  CLEVIS_CHECK_4="-"
  CLEVIS_CHECK_5="-"
  CLEVIS_CHECK_7="-"
  CLEVIS_CHECK_9="-"
}

populate_pcr_statuses()
{
  local dataset="$1"
  local store="$2"
  local store_path="${3:-}"

  reset_pcr_statuses

  if [[ "$store" == "zfs" ]]; then
    CLEVIS_CHECK_1="$(zfs get -H -p -o value latchset.clevis:jwe_1 -s local "$dataset" 2>/dev/null || true)"
    CLEVIS_CHECK_4="$(zfs get -H -p -o value latchset.clevis:jwe_4 -s local "$dataset" 2>/dev/null || true)"
    CLEVIS_CHECK_5="$(zfs get -H -p -o value latchset.clevis:jwe_5 -s local "$dataset" 2>/dev/null || true)"
    CLEVIS_CHECK_7="$(zfs get -H -p -o value latchset.clevis:jwe_7 -s local "$dataset" 2>/dev/null || true)"
    CLEVIS_CHECK_9="$(zfs get -H -p -o value latchset.clevis:jwe_9 -s local "$dataset" 2>/dev/null || true)"
  elif [[ "$store" == "efi" ]]; then
    ensure_efivarfs || return 1
    CLEVIS_CHECK_1="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE_1)"
    CLEVIS_CHECK_4="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE_4)"
    CLEVIS_CHECK_5="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE_5)"
    CLEVIS_CHECK_7="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE_7)"
    CLEVIS_CHECK_9="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE_9)"
  elif [[ "$store" == "vfat" ]]; then
    [ -n "${store_path}" ] || return 1
    mount_jwe_store "$store_path" ro || return 1
    CLEVIS_CHECK_1="$(read_jwe_store_file Clevis.JWE_1 2>/dev/null || true)"
    CLEVIS_CHECK_4="$(read_jwe_store_file Clevis.JWE_4 2>/dev/null || true)"
    CLEVIS_CHECK_5="$(read_jwe_store_file Clevis.JWE_5 2>/dev/null || true)"
    CLEVIS_CHECK_7="$(read_jwe_store_file Clevis.JWE_7 2>/dev/null || true)"
    CLEVIS_CHECK_9="$(read_jwe_store_file Clevis.JWE_9 2>/dev/null || true)"
    umount_jwe_store
  fi

  CLEVIS_CHECK_1="$(pcr_check_status "$CLEVIS_CHECK_1")"
  CLEVIS_CHECK_4="$(pcr_check_status "$CLEVIS_CHECK_4")"
  CLEVIS_CHECK_5="$(pcr_check_status "$CLEVIS_CHECK_5")"
  CLEVIS_CHECK_7="$(pcr_check_status "$CLEVIS_CHECK_7")"
  CLEVIS_CHECK_9="$(pcr_check_status "$CLEVIS_CHECK_9")"
}

reseal_data_set()
{
  PCR_IDS="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"

  echo >&2
  echo "Automatic clevis unlock failed for ${1}." >&2
  echo "PCR status: 1=${CLEVIS_CHECK_1} 4=${CLEVIS_CHECK_4} 5=${CLEVIS_CHECK_5} 7=${CLEVIS_CHECK_7} 9=${CLEVIS_CHECK_9}" >&2
  echo "Configured PCRs: ${PCR_IDS}" >&2
  read -r -p "Reseal password [yes/no]: " SRESEAL
  seq=3
  if [[ "$SRESEAL" == "yes" ]]; then
    while [[ "$seq" -gt 0 ]]
    do
      read -r -s -p "Enter ZFS password for ${1} (${seq} attempt(s) left): " PASS
      echo >&2
      zfs_load_key_check_prompt "$1" "$PASS"
      res=$?
      if [[ "$res" == "0" ]]; then
        seq=0
      else
        seq=$((seq - 1))
        PASS=""
      fi
    done
    echo "$PASS"
    return 0
  else
    # In fact we don't want to reseal
    echo ""
    return 1
  fi
}

load_key_clevis() {

  dataset_for_clevis_unlock="$1"
  unlock_dataset="$dataset_for_clevis_unlock"
  zdebug "Processing dataset $dataset_for_clevis_unlock"

  encryption_root="$(zfs get -H -o value encryptionroot "$dataset_for_clevis_unlock" 2>/dev/null || true)"
  if [[ -n "$encryption_root" && "$encryption_root" != "-" && "$encryption_root" != "$dataset_for_clevis_unlock" ]]; then
    unlock_dataset="$encryption_root"
    zdebug "Using encryption root $unlock_dataset for dataset $dataset_for_clevis_unlock"
  fi

  init_hook_log
  reset_pcr_statuses
  CLEVIS_CHECK="$(kcl_get clevis.decrypt || true)"
  if [[ "$CLEVIS_CHECK" == "yes" ]]; then
    zdebug "Found dataset for clevis unlocking: $unlock_dataset"
    KEYLOCATION="$(get_fs_value "${unlock_dataset}" keylocation)" || KEYLOCATION=
    KEYFILE="${KEYLOCATION#file://}"
    if [ "${KEYLOCATION}" = "${KEYFILE}" ] || [ -z "${KEYFILE}" ]; then
        # That's not us
        zwarn "keylocation is not file while clevis unlock is set for dataset $unlock_dataset"
        notify_autoboot_failure "$unlock_dataset" "keylocation is not file-backed"
        return 0
    fi
    if [ -f "${KEYFILE}" ]; then
      zwarn "Key filename $KEYLOCATION in keylocation property for dataset $unlock_dataset conflicts with existing file in ZBM. Please change it"
      notify_autoboot_failure "$unlock_dataset" "keylocation conflicts with existing file in ZBM"
      return 0
    fi
    # We suppose the keylocation has value in format file:///something/key
  fail_stamp="/tmp/clevis-autoboot-failed.${unlock_dataset//\//_}"

  KEYSTATUS="$(zfs get -H -p -o value keystatus -s none "$unlock_dataset")"
        if [[ "$KEYSTATUS" == "unavailable" ]]; then
        if ! is_manual_phase && [[ -e "$fail_stamp" ]]; then
          zwarn "automatic clevis unlock already failed for $unlock_dataset in this boot"
          return 1
        fi
        # Prepare the key with password for unlocking in right place
        mkdir -p "$(dirname "$KEYFILE")"
	CLEVIS_LOCATION="$(kcl_get clevis.store || true)"
        if [[ -z "$CLEVIS_LOCATION" ]]; then
          if zfs get -H -p -o value latchset.clevis:jwe -s local "$unlock_dataset" 2>/dev/null | grep -qv '^-'; then
            CLEVIS_LOCATION="zfs"
          else
            CLEVIS_LOCATION="vfat"
          fi
        fi
	if [[ "$CLEVIS_LOCATION" == "zfs" ]]; then
          JWE="$(zfs get -H -p -o value latchset.clevis:jwe -s local "$unlock_dataset")"
	elif [[ "$CLEVIS_LOCATION" == "efi" ]]; then
          ensure_efivarfs || return 1
          JWE="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE)"
	else
          CLEVIS_STORE="$(kcl_get clevis.file_location || true)"
          if [[ "$CLEVIS_STORE" != "-" ]]; then
            mount_jwe_store "$CLEVIS_STORE" ro || return 1
            JWE="$(read_jwe_store_file Clevis.JWE)"
            umount_jwe_store
          fi
	fi
        mkdir -p "$(dirname /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key)"
        if clevis_decrypt_to_file "$JWE" /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key && \
           zfs_load_key_check_file "$unlock_dataset" /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key; then
          rm -f "$fail_stamp"
          mv /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key "$KEYFILE"
          return 0
        else
          if ! is_manual_phase; then
            : > "$fail_stamp"
            populate_pcr_statuses "$unlock_dataset" "$CLEVIS_LOCATION" "${CLEVIS_STORE:-}" || true
            notify_autoboot_failure "$unlock_dataset" "clevis decrypt or zfs load-key verification failed"
            zwarn "automatic clevis unlock failed for $unlock_dataset in auto-boot mode"
            return 1
          fi
          # We have autodecrypt flag set to on, however dataset can't be unlocked. Offer resealing the password
	  if [[ "$CLEVIS_LOCATION" != "zfs" && "$CLEVIS_LOCATION" != "efi" ]]; then
            if [[ "$CLEVIS_STORE" == "-" ]]; then
                # We failed. The jwe location is not correctly stored in dataset
                zwarn "We failed. The jwe file location is not correctly defined in commandline"
                notify_autoboot_failure "$unlock_dataset" "clevis.file_location is not defined for vfat backend"
                return 1
            fi
	  fi

	  populate_pcr_statuses "$unlock_dataset" "$CLEVIS_LOCATION" "${CLEVIS_STORE:-}" || true

          RESEAL="$(reseal_data_set "$unlock_dataset")"
          if [[ "$RESEAL" != "" ]]; then
            # We are fine
            PCR_IDS="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"
            printf '%s' "$RESEAL" | clevis encrypt tpm2 "{\"pcr_ids\":\"${PCR_IDS}\",\"pcr_bank\":\"sha256\"}" > /tmp/clevis_zfs.jwe 2>>"${CLEVIS_HOOK_LOG}"
            printf '%s' "OK" | clevis encrypt tpm2 '{"pcr_ids":"1","pcr_bank":"sha256"}' > /tmp/clevis_zfs_1.jwe 2>>"${CLEVIS_HOOK_LOG}"
            printf '%s' "OK" | clevis encrypt tpm2 '{"pcr_ids":"4","pcr_bank":"sha256"}' > /tmp/clevis_zfs_4.jwe 2>>"${CLEVIS_HOOK_LOG}"
            printf '%s' "OK" | clevis encrypt tpm2 '{"pcr_ids":"5","pcr_bank":"sha256"}' > /tmp/clevis_zfs_5.jwe 2>>"${CLEVIS_HOOK_LOG}"
            printf '%s' "OK" | clevis encrypt tpm2 '{"pcr_ids":"7","pcr_bank":"sha256"}' > /tmp/clevis_zfs_7.jwe 2>>"${CLEVIS_HOOK_LOG}"
            printf '%s' "OK" | clevis encrypt tpm2 '{"pcr_ids":"9","pcr_bank":"sha256"}' > /tmp/clevis_zfs_9.jwe 2>>"${CLEVIS_HOOK_LOG}"
	    if [[ "$CLEVIS_LOCATION" == "zfs" ]]; then
              zdebug "Try to store correct jwe in $unlock_dataset"
              pool=${unlock_dataset%/*}
              with_rw_pool "$pool" store_clevis_jwe_zfs "$unlock_dataset" || return 1
              jwe_check="$(zfs get -H -p -o value latchset.clevis:jwe -s local "$unlock_dataset")"
	    elif [[ "$CLEVIS_LOCATION" == "efi" ]]; then
              zdebug "Try to store correct jwe in 55555555-5555-5555-5555-555555555555-ClevisJWE efivar"
              ensure_efivarfs || return 1
              mount -o rw,remount /sys/firmware/efi/efivars
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE --write -f /tmp/clevis_zfs.jwe
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_1 --write -f /tmp/clevis_zfs_1.jwe
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_4 --write -f /tmp/clevis_zfs_4.jwe
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_5 --write -f /tmp/clevis_zfs_5.jwe
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_7 --write -f /tmp/clevis_zfs_7.jwe
              efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_9 --write -f /tmp/clevis_zfs_9.jwe
              mount -o ro,remount /sys/firmware/efi/efivars
              jwe_check="$(read_efivar_payload 55555555-5555-5555-5555-555555555555-ClevisJWE)"
	    else
              zdebug "Try to store correct jwe in Clevis.JWE file"
              mount_jwe_store "$CLEVIS_STORE" rw || return 1
              write_jwe_store_file /tmp/clevis_zfs.jwe Clevis.JWE
              write_jwe_store_file /tmp/clevis_zfs_1.jwe Clevis.JWE_1
              write_jwe_store_file /tmp/clevis_zfs_4.jwe Clevis.JWE_4
              write_jwe_store_file /tmp/clevis_zfs_5.jwe Clevis.JWE_5
              write_jwe_store_file /tmp/clevis_zfs_7.jwe Clevis.JWE_7
              write_jwe_store_file /tmp/clevis_zfs_9.jwe Clevis.JWE_9
              jwe_check="$(read_jwe_store_file Clevis.JWE)"
              umount_jwe_store
	    fi
            # check if we are fine
            if clevis_decrypt_to_file "$jwe_check" /tmp/"$dataset_for_clevis_unlock"_clevis_verify_key && \
               zfs_load_key_check_file "$unlock_dataset" /tmp/"$dataset_for_clevis_unlock"_clevis_verify_key; then
              rm -f /tmp/"$dataset_for_clevis_unlock"_clevis_verify_key
              zdebug "The jwe was correctly stored in $CLEVIS_LOCATION for dataset $unlock_dataset"
            else
              rm -f /tmp/"$dataset_for_clevis_unlock"_clevis_verify_key
              # We failed. The jwe is not correctly stored in dataset
              zwarn "We failed. The jwe was not correctly stored in $CLEVIS_LOCATION for dataset $unlock_dataset"
              return 1
            fi
            echo "$RESEAL" >"$KEYFILE"
            return 0
          else
            # We don't want to reseal
            return 1
          fi
        fi
    else
      zwarn "This is strange. Without our help the key is available. Probably keyfile was by mistake put into ZBM initramfs. Plese recheck ZBM configuration"
      return 1
    fi
  else
    #  That's not us
    zdebug "Flag for automatic decryption latchset.clevis:decrypt is not set for dataset $dataset_for_clevis_unlock"
    return 0
  fi
}

######################
### end of clevis hook
######################

######################
### Hook entry point
######################

# Source functional libraries, logging and configuration
sources=(
  /lib/profiling-lib.sh
  /etc/zfsbootmenu.conf
  /lib/zfsbootmenu-kcl.sh
  /lib/zfsbootmenu-core.sh
  /lib/kmsg-log-lib.sh
  /etc/profile
)

for src in "${sources[@]}"; do
  # shellcheck disable=SC1090
  if ! source "${src}" >/dev/null 2>&1 ; then
    echo -e "\033[0;31mWARNING: ${src} was not sourced; unable to proceed\033[0m"
    exec /bin/bash
  fi
done

unset src sources

hook_dataset="${1:-${ZBM_ENCRYPTION_ROOT:-}}"
load_key_clevis "${hook_dataset}"
