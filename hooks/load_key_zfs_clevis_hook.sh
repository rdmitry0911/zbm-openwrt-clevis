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

reseal_data_set()
{
  API_TOKEN="$(kcl_get clevis.API_TOKEN || true)"
  CHAT_ID="$(kcl_get clevis.CHAT_ID || true)"
  host="$(kcl_get clevis.host || true)"

  IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  PCR_IDS="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"

 if [[ -n "$API_TOKEN" && -n "$CHAT_ID" ]]; then
 MSG="<b>Clevis for ZBM:</b> Reboot of $host IP: $IP <b>Password is required</b>"
 curl -k -s --data "text=$MSG" --data "chat_id=$CHAT_ID&parse_mode=html" 'https://api.telegram.org/bot'$API_TOKEN'/sendMessage' > /dev/null
 fi

  rd="Our IP: $IP
1 - firmware data/host platform configuration: $CLEVIS_CHECK_1
4 - Boot loader and additional drivers: $CLEVIS_CHECK_4
5 - GPT/Partition table: $CLEVIS_CHECK_5
7 - SecureBoot state: $CLEVIS_CHECK_7
9 - booter + kcl : $CLEVIS_CHECK_9
Configured PCRs: $PCR_IDS
We have autodecrypt flag set to on, however $1 can't be unlocked. Would you like to reseal the password [yes/no] "
  read -p "$rd" SRESEAL
  seq=3
  if [[ "$SRESEAL" == "yes" ]]; then
    while [[ "$seq" -gt 0 ]]
    do
      read -s -p  "Type the password, please, to unlock $1. You have $seq attempts left : " PASS
      echo -n "$PASS" | zfs load-key -n -L prompt "$1" >&2
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

  # We need to setup network for remote access

  ssh1="$(kcl_get clevis.ssh1 || true)"
  ssh2="$(kcl_get clevis.ssh2 || true)"

  [[ -n "$ssh1" ]] && echo "$ssh1" >> /root/.ssh/authorized_keys
  [[ -n "$ssh2" ]] && echo "$ssh2" >> /root/.ssh/authorized_keys

  CLEVIS_CHECK="$(kcl_get clevis.decrypt || true)"
  if [[ "$CLEVIS_CHECK" == "yes" ]]; then
    zdebug "Found dataset for clevis unlocking: $unlock_dataset"
    KEYLOCATION="$(get_fs_value "${unlock_dataset}" keylocation)" || KEYLOCATION=
    KEYFILE="${KEYLOCATION#file://}"
    if [ "${KEYLOCATION}" = "${KEYFILE}" ] || [ -z "${KEYFILE}" ]; then
        # That's not us
        zwarn "keylocation is not file while clevis unlock is set for dataset $unlock_dataset"
        return 0
    fi
    if [ -f "${KEYFILE}" ]; then
      zwarn "Key filename $KEYLOCATION in keylocation property for dataset $unlock_dataset conflicts with existing file in ZBM. Please change it"
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
          JWE="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	else
          CLEVIS_STORE="$(kcl_get clevis.file_location || true)"
          if [[ "$CLEVIS_STORE" != "-" ]]; then
            mount_jwe_store "$CLEVIS_STORE" ro || return 1
            JWE="$(read_jwe_store_file Clevis.JWE)"
            umount_jwe_store
          fi
	fi
        mkdir -p "$(dirname /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key)"
        echo "$JWE" | clevis decrypt >/tmp/"$dataset_for_clevis_unlock"_clevis_temp_key
        if zfs load-key -L file:///tmp/"$dataset_for_clevis_unlock"_clevis_temp_key -n "$unlock_dataset"; then
          rm -f "$fail_stamp"
          mv /tmp/"$dataset_for_clevis_unlock"_clevis_temp_key "$KEYFILE"
          return 0
        else
          if ! is_manual_phase; then
            : > "$fail_stamp"
            zwarn "automatic clevis unlock failed for $unlock_dataset in auto-boot mode"
            return 1
          fi
          # We have autodecrypt flag set to on, however dataset can't be unlocked. Offer resealing the password
	  if [[ "$CLEVIS_LOCATION" == "zfs" ]]; then
	    CLEVIS_CHECK_1="$(zfs get -H -p -o value latchset.clevis:jwe_1 -s local "$unlock_dataset")"
	    CLEVIS_CHECK_4="$(zfs get -H -p -o value latchset.clevis:jwe_4 -s local "$unlock_dataset")"
	    CLEVIS_CHECK_5="$(zfs get -H -p -o value latchset.clevis:jwe_5 -s local "$unlock_dataset")"
	    CLEVIS_CHECK_7="$(zfs get -H -p -o value latchset.clevis:jwe_7 -s local "$unlock_dataset")"
	    CLEVIS_CHECK_9="$(zfs get -H -p -o value latchset.clevis:jwe_9 -s local "$unlock_dataset")"
	  elif [[ "$CLEVIS_LOCATION" == "efi" ]]; then
            ensure_efivarfs || return 1
	    CLEVIS_CHECK_1="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_1 -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	    CLEVIS_CHECK_4="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_4 -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	    CLEVIS_CHECK_5="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_5 -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	    CLEVIS_CHECK_7="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_7 -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	    CLEVIS_CHECK_9="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE_9 -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
	  else
            if [[ "$CLEVIS_STORE" == "-" ]]; then
                # We failed. The jwe location is not correctly stored in dataset
                zwarn "We failed. The jwe file location is not correctly defined in commandline"
                return 1
            fi
            mount_jwe_store "$CLEVIS_STORE" ro || return 1
            CLEVIS_CHECK_1="$(read_jwe_store_file Clevis.JWE_1)"
            CLEVIS_CHECK_4="$(read_jwe_store_file Clevis.JWE_4)"
            CLEVIS_CHECK_5="$(read_jwe_store_file Clevis.JWE_5)"
            CLEVIS_CHECK_7="$(read_jwe_store_file Clevis.JWE_7)"
            CLEVIS_CHECK_9="$(read_jwe_store_file Clevis.JWE_9)"
            umount_jwe_store
	  fi

	  CLEVIS_CHECK_1="$(echo $CLEVIS_CHECK_1 | clevis decrypt)"
	  CLEVIS_CHECK_4="$(echo $CLEVIS_CHECK_4 | clevis decrypt)"
	  CLEVIS_CHECK_5="$(echo $CLEVIS_CHECK_5 | clevis decrypt)"
	  CLEVIS_CHECK_7="$(echo $CLEVIS_CHECK_7 | clevis decrypt)"
	  CLEVIS_CHECK_9="$(echo $CLEVIS_CHECK_9 | clevis decrypt)"

          RESEAL="$(reseal_data_set "$unlock_dataset")"
          if [[ "$RESEAL" != "" ]]; then
            # We are fine
            PCR_IDS="$(kcl_get clevis.pcr_ids || printf '1,4,5,7,9')"
            echo "$RESEAL"|clevis encrypt tpm2 "{\"pcr_ids\":\"${PCR_IDS}\",\"pcr_bank\":\"sha256\"}" > /tmp/clevis_zfs.jwe
            echo "OK"|clevis encrypt tpm2 '{"pcr_ids":"1","pcr_bank":"sha256"}' > /tmp/clevis_zfs_1.jwe
            echo "OK"|clevis encrypt tpm2 '{"pcr_ids":"4","pcr_bank":"sha256"}' > /tmp/clevis_zfs_4.jwe
            echo "OK"|clevis encrypt tpm2 '{"pcr_ids":"5","pcr_bank":"sha256"}' > /tmp/clevis_zfs_5.jwe
            echo "OK"|clevis encrypt tpm2 '{"pcr_ids":"7","pcr_bank":"sha256"}' > /tmp/clevis_zfs_7.jwe
            echo "OK"|clevis encrypt tpm2 '{"pcr_ids":"9","pcr_bank":"sha256"}' > /tmp/clevis_zfs_9.jwe
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
              jwe_check="$(efivar -n 55555555-5555-5555-5555-555555555555-ClevisJWE -p|awk -F \| '{aggr=aggr $2} END {print aggr}')"
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
            if echo "$jwe_check" | clevis decrypt | zfs load-key -n -L prompt "$unlock_dataset"; then
              zdebug "The jwe was correctly stored in $CLEVIS_LOCATION for dataset $unlock_dataset"
            else
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
