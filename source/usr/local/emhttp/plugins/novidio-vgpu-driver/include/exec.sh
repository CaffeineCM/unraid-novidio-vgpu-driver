#!/bin/bash

DRIVER_HELPER="/usr/local/emhttp/plugins/novidio-vgpu-driver/include/driver.sh"
SETTINGS_FILE="/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
VGPU_UNLOCK_CONFIG="/etc/vgpu_unlock/config.toml"

get_setting() {
local key="${1}"

grep "^${key}=" "${SETTINGS_FILE}" 2>/dev/null | tail -1 | cut -d '=' -f2-
}

set_setting() {
local key="${1}"
local value="${2}"

sed -i.bak "/^${key}=/d" "${SETTINGS_FILE}"
rm -f "${SETTINGS_FILE}.bak"
printf '%s=%s\n' "${key}" "${value}" >> "${SETTINGS_FILE}"
}

fetch_driver_assets() {
KERNEL_V="$(uname -r)"
PACKAGE="nvidia"
wget -qO- "https://api.github.com/repos/CaffeineCM/unraid-novidio-vgpu-driver/releases/tags/${KERNEL_V}" | jq -r '.assets[].name' | grep -E "^${PACKAGE}.*\.txz$" | grep -E -v '\.md5$' | sort -V
}

extract_driver_selectors() {
sed -nE 's/^nvidia-([0-9]+\.[0-9]+\.[0-9]+)(-merged)?-.*\.txz$/\1\2/p' | sort -Vu
}

function update(){
{
fetch_driver_assets 2>/dev/null | extract_driver_selectors
${DRIVER_HELPER} list_local_versions 2>/dev/null
get_selected_version
get_installed_version
get_prepared_version
} | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-merged)?$' | sort -Vu > /tmp/novidio_vgpu_driver
if [ ! -s /tmp/novidio_vgpu_driver ]; then
  echo -n "$(${DRIVER_HELPER} current_installed_selector 2>/dev/null)" > /tmp/novidio_vgpu_driver
fi
}

function update_version(){
run_action download_only "${1}"
}

function get_latest_version(){
KERNEL_V="$(uname -r)"
echo -n "$(cat /tmp/novidio_vgpu_driver | tail -1)"
}

##function get_prb(){
##echo -n "$(comm -12 /tmp/novidio_vgpu_driver <(echo "$(cat /tmp/nvidia_branches | grep 'PRB' | cut -d '=' -f2 | sort -V)") | tail -1)"
##}

##function get_nfb(){
##echo -n "$(comm -12 /tmp/novidio_vgpu_driver <(echo "$(cat /tmp/nvidia_branches | grep 'NFB' | cut -d '=' -f2 | sort -V)") | tail -1)"
##}

function get_selected_version(){
echo -n "$(get_setting driver_version)"
}

function get_installed_version(){
echo -n "$(${DRIVER_HELPER} current_installed_selector 2>/dev/null)"
}

function get_prepared_version(){
echo -n "$(${DRIVER_HELPER} prepared_version 2>/dev/null)"
}

function update_check(){
echo -n "$(get_setting update_check)"
}

function get_vgpu_unlock(){
if [ "$(get_setting vgpu_unlock)" = "true" ]; then
  echo -n "true"
else
  echo -n "false"
fi
}

function change_vgpu_unlock(){
local enabled="${1}"

case "${enabled}" in
  true|false)
    ;;
  *)
    echo "Invalid vGPU Unlock value: ${enabled}" >&2
    return 1
    ;;
esac

set_setting vgpu_unlock "${enabled}"
mkdir -p "$(dirname "${VGPU_UNLOCK_CONFIG}")"
printf 'unlock = %s\n' "${enabled}" > "${VGPU_UNLOCK_CONFIG}"

if [ "${enabled}" = "true" ]; then
  echo "vGPU Unlock enabled. Reboot before creating mdev devices."
else
  echo "vGPU Unlock disabled. Reboot before creating mdev devices."
fi
}

function get_nvidia_pci_id(){
echo -n "$(nvidia-smi --query-gpu=index,name,gpu_bus_id,uuid --format=csv,noheader | tr "," "\n" | sed 's/^[ \t]*//' | sed -e s/00000000://g | sed -n '3p')"
}

function get_mdev_list(){
local device_path
local uuid
local parent_path
local parent_bdf
local type_path
local type_name
local found=0

shopt -s nullglob

for device_path in /sys/bus/mdev/devices/*; do
  [ -e "${device_path}" ] || continue
  uuid="$(basename "${device_path}")"
  parent_bdf=""
  type_name=""

  if [ -L "${device_path}/parent" ]; then
    parent_path="$(readlink -f "${device_path}/parent")"
    parent_bdf="$(basename "${parent_path}")"
  fi

  if [ -L "${device_path}/mdev_type" ]; then
    type_path="$(readlink -f "${device_path}/mdev_type")"
    if [ -r "${type_path}/name" ]; then
      type_name="$(cat "${type_path}/name")"
    else
      type_name="$(basename "${type_path}")"
    fi
  fi

  if [ -n "${parent_bdf}" ] && [ -n "${type_name}" ]; then
    echo "${uuid} (${parent_bdf}, ${type_name})"
  elif [ -n "${type_name}" ]; then
    echo "${uuid} (${type_name})"
  else
    echo "${uuid}"
  fi
  found=1
done

if [ "${found}" -eq 0 ]; then
  echo -n ""
fi
}

function get_mdev_types(){
local bus_path
local gpu_bdf
local type_path
local type_id
local type_name
local available
local found=0

shopt -s nullglob

for bus_path in /sys/class/mdev_bus/*; do
  [ -d "${bus_path}/mdev_supported_types" ] || continue
  gpu_bdf="$(basename "$(readlink -f "${bus_path}")")"

  for type_path in "${bus_path}"/mdev_supported_types/*; do
    [ -d "${type_path}" ] || continue
    type_id="$(basename "${type_path}")"
    type_name="${type_id}"
    available="?"

    if [ -r "${type_path}/name" ]; then
      type_name="$(cat "${type_path}/name")"
    fi

    if [ -r "${type_path}/available_instances" ]; then
      available="$(cat "${type_path}/available_instances")"
    fi

    echo "${gpu_bdf}: ${type_id} - ${type_name} (available: ${available})"
    found=1
  done
done

if [ "${found}" -eq 0 ]; then
  echo -n ""
fi
}

function get_flash_id(){
aaa="$(udevadm info -q all -n /dev/sda1 | grep -i by-uuid | head -1)" && echo "${aaa:0-9:9}"
}
function change_update_check(){
case "${1}" in
  true|false)
    ;;
  *)
    echo "Invalid update check value: ${1}" >&2
    return 1
    ;;
esac

set_setting update_check "${1}"
if [ "${1}" == "true" ]; then
  if ! crontab -l 2>/dev/null | grep -q "/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh"; then
    (crontab -l 2>/dev/null; echo "$((0 + RANDOM % 59)) $(shuf -i 8-9 -n 1) * * * /usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh &>/dev/null 2>&1") | crontab -
  fi
elif [ "${1}" == "false" ]; then
  crontab -l 2>/dev/null | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh' | crontab -
fi

}

function run_action(){
version="${2:-latest}"
set_setting driver_version "${version}"
if [ "${version}" != "latest" ]; then
  set_setting update_check false
  crontab -l 2>/dev/null | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh' | crontab -
fi
${DRIVER_HELPER} "${1}" "${version}"
}

$@
