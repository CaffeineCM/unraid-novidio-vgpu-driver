#!/bin/bash

fetch_driver_assets() {
KERNEL_V="$(uname -r)"
PACKAGE="nvidia"
wget -qO- "https://api.github.com/repos/CaffeineCM/unraid-novidio-vgpu-driver/releases/tags/${KERNEL_V}" | jq -r '.assets[].name' | grep -E "^${PACKAGE}.*\.txz$" | grep -E -v '\.md5$' | sort -V
}

extract_driver_versions() {
sed -nE 's/^nvidia[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' | sort -Vu
}

function update(){
echo -n "$(fetch_driver_assets | extract_driver_versions | tail -10)" > /tmp/novidio_vgpu_driver
if [ ! -s /tmp/novidio_vgpu_driver ]; then
  echo -n "$(modinfo nvidia | grep "version:" | awk '{print $2}' | head -1)" > /tmp/novidio_vgpu_driver
fi
}

function update_version(){
sed -i "/driver_version=/c\driver_version=${1}" "/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
if [ "${1}" != "latest" ]; then
  sed -i "/update_check=/c\update_check=false" "/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
  echo -n "$(crontab -l | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh &>/dev/null 2>&1'  | crontab -)"
fi
/usr/local/emhttp/plugins/novidio-vgpu-driver/include/download.sh
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
echo -n "$(cat /boot/config/plugins/novidio-vgpu-driver/settings.cfg | grep "driver_version" | cut -d '=' -f2)"
}

function get_installed_version(){
echo -n "$(modinfo nvidia | grep -w "version:" | awk '{print $2}')"
}

function update_check(){
echo -n "$(cat /boot/config/plugins/novidio-vgpu-driver/settings.cfg | grep "update_check" | cut -d '=' -f2)"
}

function get_nvidia_pci_id(){
echo -n "$(nvidia-smi --query-gpu=index,name,gpu_bus_id,uuid --format=csv,noheader | tr "," "\n" | sed 's/^[ \t]*//' | sed -e s/00000000://g | sed -n '3p')"
}

function get_mdev_list(){
echo -n "$(mdevctl list)"
}

function get_flash_id(){
aaa="$(udevadm info -q all -n /dev/sda1 | grep -i by-uuid | head -1)" && echo "${aaa:0-9:9}"
}
function change_update_check(){
sed -i "/update_check=/c\update_check=${1}" "/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
if [ "${1}" == "true" ]; then
  if [ ! "$(crontab -l | grep "/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh")" ]; then
    echo -n "$((crontab -l ; echo ""$((0 + $RANDOM % 59))" "$(shuf -i 8-9 -n 1)" * * * /usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh &>/dev/null 2>&1") | crontab -)"
  fi
elif [ "${1}" == "false" ]; then
  echo -n "$(crontab -l | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh &>/dev/null 2>&1'  | crontab -)"
fi

}

$@
