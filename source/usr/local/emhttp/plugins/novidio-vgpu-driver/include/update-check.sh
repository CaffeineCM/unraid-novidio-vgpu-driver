#!/bin/bash
package_version() {
echo "${1}" | sed -nE 's/^nvidia-([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'
}

download_with_verify() {
local package_path="/boot/config/plugins/novidio-vgpu-driver/packages/${KERNEL_V%%-*}/${LAT_PACKAGE}"
local md5_path="${package_path}.md5"
local tmp_package="${package_path}.part"
local tmp_md5="${md5_path}.part"

rm -f "${package_path}" "${md5_path}" "${tmp_package}" "${tmp_md5}"

if wget -q --show-progress --progress=bar:force:noscroll -O "${tmp_package}" "${DL_URL}/${LAT_PACKAGE}" ; then
  wget -q --show-progress --progress=bar:force:noscroll -O "${tmp_md5}" "${DL_URL}/${LAT_PACKAGE}.md5"
  if [ "$(md5sum "${tmp_package}" | awk '{print $1}')" != "$(awk '{print $1}' "${tmp_md5}")" ]; then
    echo
    echo "-----ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR------"
    echo "--------------------------------CHECKSUM ERROR!---------------------------------"
    /usr/local/emhttp/plugins/dynamix/scripts/notify -e "Nvidia vGPU Driver" -d "Found new Nvidia Driver v${LATEST_V} but a checksum error occurred! Please try to install the driver manually!" -i "alert" -l "/Settings/novidio-vgpu-driver"
    crontab -l | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh'  | crontab -
    rm -f "${tmp_package}" "${tmp_md5}"
    exit 1
  fi
  mv -f "${tmp_package}" "${package_path}"
  mv -f "${tmp_md5}" "${md5_path}"
  return 0
fi

rm -f "${tmp_package}" "${tmp_md5}"
return 1
}

KERNEL_V="$(uname -r)"
PACKAGE="nvidia"
SET_DRV_V="$(cat /boot/config/plugins/novidio-vgpu-driver/settings.cfg | grep "driver_version" | cut -d '=' -f2)"
INSTALLED_V="$(nvidia-smi | grep NVIDIA-SMI | cut -d ' ' -f3)"

download() {
if download_with_verify ; then
  echo
  echo "-----------Successfully downloaded Nvidia Driver Package v$(package_version "$LAT_PACKAGE")-----------"
  /usr/local/emhttp/plugins/dynamix/scripts/notify -e "Nvidia vGPU Driver" -d "New Nvidia Driver v${LATEST_V} found and downloaded! Please reboot your Server to install the new version!" -l "/Main"
  crontab -l | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh'  | crontab -
else
  echo
  echo "---------------Can't download Nvidia Driver Package v$(package_version "$LAT_PACKAGE")----------------"
  /usr/local/emhttp/plugins/dynamix/scripts/notify -e "Nvidia vGPU Driver" -d "Found new Nvidia vGPU Driver v${LATEST_V} but a download error occurred! Please try to download the driver manually!" -i "alert" -l "/Settings/novidio-vgpu-driver"
  crontab -l | grep -v '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/update-check.sh'  | crontab -
  exit 1
fi
}

#Check if one of latest, latest_prb or latest_nfb is checked otherwise exit
if [ "${SET_DRV_V}" != "latest" ]; then
  exit 0
elif [ "${SET_DRV_V}" == "latest" ]; then
  LAT_PACKAGE="$(wget -qO- https://api.github.com/repos/CaffeineCM/unraid-novidio-vgpu-driver/releases/tags/${KERNEL_V} | jq -r '.assets[].name' | grep "$PACKAGE" | grep -E -v '\.md5$' | sort -V | tail -1)"
  if [ -z ${LAT_PACKAGE} ]; then
    logger "novidio-vgpu-driver-Plugin: Automatic update check failed, can't get latest version number!"
    exit 1
  elif [ "$(package_version "$LAT_PACKAGE")" != "${INSTALLED_V}" ]; then
    download
  fi

#Check for old packages that are not suitable for this Kernel and not suitable for the current Nvidia driver version
rm -f $(ls -d /boot/config/plugins/novidio-vgpu-driver/packages/${KERNEL_V%%-*}/* 2>/dev/null | grep -v "${KERNEL_V%%-*}")
rm -f $(ls /boot/config/plugins/novidio-vgpu-driver/packages/${KERNEL_V%%-*}/* 2>/dev/null | grep -v "$LAT_PACKAGE")
fi
