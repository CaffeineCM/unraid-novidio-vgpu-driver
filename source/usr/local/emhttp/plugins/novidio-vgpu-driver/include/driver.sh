#!/bin/bash

PLUGIN_DIR="/usr/local/emhttp/plugins/novidio-vgpu-driver"
SETTINGS_FILE="/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
KERNEL_V="$(uname -r)"
PACKAGE_DIR="/boot/config/plugins/novidio-vgpu-driver/packages/${KERNEL_V%%-*}"
PACKAGE_PREFIX="nvidia"
REPO="CaffeineCM/unraid-novidio-vgpu-driver"
DL_URL="https://github.com/${REPO}/releases/download/${KERNEL_V}"
VGPU_PRELOAD="/usr/local/lib/libvgpu_unlock_rs.so"

package_version() {
  echo "${1}" | sed -nE 's/^nvidia-([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'
}

selected_driver_version() {
  grep '^driver_version=' "${SETTINGS_FILE}" 2>/dev/null | cut -d '=' -f2
}

current_installed_version() {
  modinfo nvidia 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

list_remote_packages() {
  wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/${KERNEL_V}" \
    | jq -r '.assets[].name' \
    | grep -E "^${PACKAGE_PREFIX}.*\.txz$" \
    | grep -E -v '\.md5$' \
    | sort -V
}

list_local_packages() {
  find "${PACKAGE_DIR}" -maxdepth 1 -type f -name "${PACKAGE_PREFIX}-*.txz" -printf '%f\n' 2>/dev/null | sort -V
}

resolve_remote_target_package() {
  local requested="${1:-$(selected_driver_version)}"
  if [ "${requested}" = "latest" ]; then
    list_remote_packages | tail -1
  else
    list_remote_packages | grep -F -- "${requested}" | tail -1
  fi
}

resolve_local_target_package() {
  local requested="${1:-$(selected_driver_version)}"
  if [ "${requested}" = "latest" ]; then
    list_local_packages | tail -1
  else
    list_local_packages | grep -F -- "${requested}" | tail -1
  fi
}

set_selected_driver_version() {
  local version="${1}"
  sed -i "/driver_version=/c\driver_version=${version}" "${SETTINGS_FILE}"
  if [ "${version}" != "latest" ]; then
    sed -i "/update_check=/c\update_check=false" "${SETTINGS_FILE}"
  fi
}

ensure_package_dir() {
  mkdir -p "${PACKAGE_DIR}"
}

download_package() {
  local package_name="${1}"

  ensure_package_dir

  if wget -q -nc --show-progress --progress=bar:force:noscroll -O "${PACKAGE_DIR}/${package_name}" "${DL_URL}/${package_name}"; then
    wget -q -nc --show-progress --progress=bar:force:noscroll -O "${PACKAGE_DIR}/${package_name}.md5" "${DL_URL}/${package_name}.md5"
    if [ "$(md5sum "${PACKAGE_DIR}/${package_name}" | awk '{print $1}')" != "$(awk '{print $1}' "${PACKAGE_DIR}/${package_name}.md5")" ]; then
      echo
      echo "-----ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR------"
      echo "--------------------------------CHECKSUM ERROR!---------------------------------"
      rm -f "${PACKAGE_DIR}/${package_name}" "${PACKAGE_DIR}/${package_name}.md5"
      exit 1
    fi
    echo
    echo "-----------Successfully downloaded Nvidia vGPU Driver Package v$(package_version "${package_name}")-----------"
  else
    echo
    echo "---------------Can't download Nvidia vGPU Driver Package v$(package_version "${package_name}")----------------"
    exit 1
  fi
}

download_selected() {
  local requested="${1:-$(selected_driver_version)}"
  local package_name

  package_name="$(resolve_remote_target_package "${requested}")"
  if [ -z "${package_name}" ]; then
    echo
    echo "-----ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR------"
    echo "------Can't find selected Nvidia vGPU driver version in available releases------"
    exit 1
  fi

  echo
  echo "+=============================================================================="
  echo "| WARNING - WARNING - WARNING - WARNING - WARNING - WARNING - WARNING - WARNING"
  echo "|"
  echo "| Don't close this window with the red 'X' in the top right corner until the 'DONE' button is displayed!"
  echo "|"
  echo "| WARNING - WARNING - WARNING - WARNING - WARNING - WARNING - WARNING - WARNING"
  echo "+=============================================================================="
  echo
  echo "----------------Downloading Nvidia vGPU Driver Package v$(package_version "${package_name}")-----------------"
  echo "---------This could take some time, please don't close this window!------------"
  download_package "${package_name}"
  echo
  echo "----Driver v$(package_version "${package_name}") is downloaded and ready for install actions.----"
}

stop_vgpu_services() {
  if pgrep -x nvidia-vgpud >/dev/null 2>&1; then
    command -v nvidia-vgpud >/dev/null 2>&1 && nvidia-vgpud stop >/dev/null 2>&1
    pkill -x nvidia-vgpud >/dev/null 2>&1 || true
  fi
  if pgrep -x nvidia-vgpu-mgr >/dev/null 2>&1; then
    command -v nvidia-vgpu-mgr >/dev/null 2>&1 && nvidia-vgpu-mgr stop >/dev/null 2>&1
    pkill -x nvidia-vgpu-mgr >/dev/null 2>&1 || true
  fi
}

start_vgpu_services() {
  if command -v nvidia-vgpud >/dev/null 2>&1; then
    LD_PRELOAD="${VGPU_PRELOAD}" nvidia-vgpud >/dev/null 2>&1 &
  fi
  if command -v nvidia-vgpu-mgr >/dev/null 2>&1; then
    LD_PRELOAD="${VGPU_PRELOAD}" nvidia-vgpu-mgr >/dev/null 2>&1 &
  fi
}

unload_nvidia_modules() {
  local mod
  for mod in nvidia_vgpu_vfio nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if lsmod | awk '{print $1}' | grep -qx "${mod}"; then
      if ! modprobe -r "${mod}" >/dev/null 2>&1; then
        echo "Failed to unload module ${mod}. Hot upgrade cannot continue."
        return 1
      fi
    fi
  done
  return 0
}

activate_driver() {
  local disable_xconfig

  disable_xconfig="$(grep '^disable_xconfig=' "${SETTINGS_FILE}" 2>/dev/null | cut -d '=' -f2)"
  if command -v Xorg >/dev/null 2>&1 && [ "${disable_xconfig}" != "true" ]; then
    nvidia-xconfig --output-xconfig=/etc/X11/xorg.conf --silent 2>/dev/null || true
  fi

  depmod -a >/dev/null 2>&1 || true
  nvidia-modprobe >/dev/null 2>&1 || true
  modprobe nvidia >/dev/null 2>&1 || true
  modprobe nvidia_vgpu_vfio >/dev/null 2>&1 || true
  start_vgpu_services
}

install_local_package() {
  local package_name="${1}"

  /sbin/upgradepkg --install-new --reinstall "${PACKAGE_DIR}/${package_name}" >/dev/null
  activate_driver
  echo
  echo "----------------Installed Nvidia vGPU Driver Package v$(package_version "${package_name}")----------------"
}

prepared_version() {
  local package_name

  package_name="$(resolve_local_target_package)"
  if [ -n "${package_name}" ]; then
    package_version "${package_name}"
  fi
}

boot_apply_selected() {
  local package_name
  local installed_version
  local target_version

  package_name="$(resolve_local_target_package)"
  if [ -z "${package_name}" ]; then
    exit 0
  fi

  target_version="$(package_version "${package_name}")"
  installed_version="$(current_installed_version)"

  if [ "${installed_version}" = "${target_version}" ]; then
    exit 0
  fi

  echo "Applying prepared Nvidia vGPU Driver Package v${target_version} during boot..."
  stop_vgpu_services
  unload_nvidia_modules >/dev/null 2>&1 || true
  install_local_package "${package_name}"
}

hot_upgrade_selected() {
  local requested="${1:-$(selected_driver_version)}"
  local package_name
  local target_version

  package_name="$(resolve_local_target_package "${requested}")"
  if [ -z "${package_name}" ]; then
    download_selected "${requested}"
    package_name="$(resolve_local_target_package "${requested}")"
  fi

  if [ -z "${package_name}" ]; then
    echo "Unable to resolve a local driver package for hot upgrade."
    exit 1
  fi

  target_version="$(package_version "${package_name}")"

  echo
  echo "----------------Starting experimental hot upgrade to v${target_version}----------------"
  echo "-------Make sure no VM, Docker container, or host workload is using the GPU.-------"

  stop_vgpu_services
  if ! unload_nvidia_modules; then
    echo "Falling back to reboot-based install is recommended."
    exit 1
  fi

  install_local_package "${package_name}"
  echo "Hot upgrade completed. Verify with nvidia-smi and modinfo."
}

download_reboot_selected() {
  local requested="${1:-$(selected_driver_version)}"
  local selected_pkg

  download_selected "${requested}"
  selected_pkg="$(resolve_local_target_package "${requested}")"

  echo
  echo "Scheduling reboot to install Nvidia vGPU Driver Package v$(package_version "${selected_pkg}")..."
  /usr/local/emhttp/plugins/dynamix/scripts/notify -e "Nvidia vGPU Driver" -d "Reboot scheduled to install Nvidia vGPU Driver v$(package_version "${selected_pkg}")" -i "alert" -l "/Main"
  nohup bash -c 'sleep 3; /sbin/reboot' >/dev/null 2>&1 &
}

case "${1}" in
  download_only)
    download_selected "${2}"
    ;;
  hot_upgrade)
    hot_upgrade_selected "${2}"
    ;;
  download_reboot)
    download_reboot_selected "${2}"
    ;;
  boot_apply_selected)
    boot_apply_selected
    ;;
  prepared_version)
    prepared_version
    ;;
  *)
    echo "Unknown action: ${1}"
    exit 1
    ;;
esac
