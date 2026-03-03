#!/bin/bash

PLUGIN_DIR="/usr/local/emhttp/plugins/novidio-vgpu-driver"
SETTINGS_FILE="/boot/config/plugins/novidio-vgpu-driver/settings.cfg"
KERNEL_V="$(uname -r)"
PACKAGE_DIR="/boot/config/plugins/novidio-vgpu-driver/packages/${KERNEL_V%%-*}"
PACKAGE_PREFIX="nvidia"
REPO="CaffeineCM/unraid-novidio-vgpu-driver"
DL_URL="https://github.com/${REPO}/releases/download/${KERNEL_V}"
VGPU_PRELOAD="/usr/local/lib/libvgpu_unlock_rs.so"
LOG_FILE="/boot/logs/novidio-vgpu-driver.log"

setup_logging() {
  local action="${1}"

  case "${action}" in
    download_only|import_upload|boot_apply_selected|hot_upgrade|download_reboot)
      mkdir -p "$(dirname "${LOG_FILE}")"
      touch "${LOG_FILE}"
      exec > >(tee -a "${LOG_FILE}") 2>&1
      echo
      echo "===== $(date '+%Y-%m-%d %H:%M:%S') ${action} ====="
      ;;
  esac
}

package_version() {
  echo "${1}" | sed -nE 's/^nvidia-([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p'
}

package_variant() {
  if echo "${1}" | grep -Eq '^nvidia-[0-9]+\.[0-9]+\.[0-9]+-merged-.*\.txz$'; then
    echo "merged"
  else
    echo "kvm"
  fi
}

package_selector() {
  local version

  version="$(package_version "${1}")"
  [ -n "${version}" ] || return 0

  if [ "$(package_variant "${1}")" = "merged" ]; then
    echo "${version}-merged"
  else
    echo "${version}"
  fi
}

selector_version() {
  echo "${1}" | sed 's/-merged$//'
}

selector_variant() {
  if echo "${1}" | grep -Eq -- '-merged$'; then
    echo "merged"
  else
    echo "kvm"
  fi
}

selector_label() {
  local selector="${1}"
  local version

  case "${selector}" in
    latest)
      echo "latest"
      return 0
      ;;
    "")
      return 0
      ;;
  esac

  version="$(selector_version "${selector}")"
  if [ "$(selector_variant "${selector}")" = "merged" ]; then
    echo "${version} (merged)"
  else
    echo "${version} (kvm)"
  fi
}

package_label() {
  selector_label "$(package_selector "${1}")"
}

sort_packages() {
  while read -r package_name; do
    [ -n "${package_name}" ] || continue
    printf '%s\t%s\t%s\n' \
      "$(package_version "${package_name}")" \
      "$( [ "$(package_variant "${package_name}")" = "merged" ] && echo 1 || echo 0 )" \
      "${package_name}"
  done | sort -t "$(printf '\t')" -k1,1V -k2,2n | cut -f3
}

selected_driver_version() {
  grep '^driver_version=' "${SETTINGS_FILE}" 2>/dev/null | cut -d '=' -f2
}

current_installed_version() {
  modinfo nvidia 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

current_installed_selector() {
  local version

  version="$(current_installed_version)"
  [ -n "${version}" ] || return 0

  if [ -e /usr/lib64/libcuda.so ] \
    && modinfo nvidia_uvm >/dev/null 2>&1 \
    && modinfo nvidia_modeset >/dev/null 2>&1 \
    && modinfo nvidia_drm >/dev/null 2>&1; then
    echo "${version}-merged"
  else
    echo "${version}"
  fi
}

relink_library_dir() {
  local lib_dir="${1}"
  local target_version="${2}"
  local versioned
  local base
  local base_name

  [ -d "${lib_dir}" ] || return 0

  for versioned in "${lib_dir}"/*.so."${target_version}"; do
    [ -e "${versioned}" ] || continue
    base="${versioned%.${target_version}}"
    base_name="$(basename "${base}")"

    if [ -L "${base}.1" ] || [ -e "${base}.1" ]; then
      ln -sfn "$(basename "${versioned}")" "${base}.1"
    fi

    if [ -L "${base}" ] || [ ! -e "${base}" ]; then
      if [ -L "${base}.1" ] || [ -e "${base}.1" ]; then
        ln -sfn "${base_name}.1" "${base}"
      else
        ln -sfn "$(basename "${versioned}")" "${base}"
      fi
    fi
  done
}

relink_nvidia_userspace() {
  local target_version

  target_version="${1:-$(current_installed_version)}"
  [ -n "${target_version}" ] || return 0

  relink_library_dir /usr/lib64 "${target_version}"
  relink_library_dir /usr/lib "${target_version}"
  ldconfig >/dev/null 2>&1 || true
}

list_remote_packages() {
  wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/${KERNEL_V}" \
    | jq -r '.assets[].name' \
    | grep -E "^${PACKAGE_PREFIX}.*\.txz$" \
    | grep -E -v '\.md5$' \
    | sort_packages
}

list_local_packages() {
  local package_path

  [ -d "${PACKAGE_DIR}" ] || return 0

  for package_path in "${PACKAGE_DIR}"/${PACKAGE_PREFIX}-*.txz; do
    [ -f "${package_path}" ] || continue
    basename "${package_path}"
  done | sort_packages
}

list_local_versions() {
  list_local_packages | while read -r package_name; do
    package_selector "${package_name}"
  done | sed '/^$/d' | sort -Vu
}

resolve_package_by_request() {
  local requested="${1}"
  local package_list_command="${2}"
  local selector_match

  if [ "${requested}" = "latest" ]; then
    ${package_list_command} | tail -1
    return 0
  fi

  selector_match="$(${package_list_command} | while read -r package_name; do
    [ "$(package_selector "${package_name}")" = "${requested}" ] && echo "${package_name}"
  done | tail -1)"
  if [ -n "${selector_match}" ]; then
    echo "${selector_match}"
    return 0
  fi

  ${package_list_command} | while read -r package_name; do
    [ "$(package_version "${package_name}")" = "$(selector_version "${requested}")" ] && echo "${package_name}"
  done | tail -1
}

resolve_remote_target_package() {
  local requested="${1:-$(selected_driver_version)}"
  resolve_package_by_request "${requested}" list_remote_packages
}

resolve_local_target_package() {
  local requested="${1:-$(selected_driver_version)}"
  resolve_package_by_request "${requested}" list_local_packages
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

validate_package_name() {
  local package_name="${1}"

  if ! echo "${package_name}" | grep -Eq "^${PACKAGE_PREFIX}-[0-9]+\.[0-9]+\.[0-9]+(-merged)?-${KERNEL_V}-[0-9]+\.txz$"; then
    echo "Upload rejected: filename must match ${PACKAGE_PREFIX}-<version>[-merged]-${KERNEL_V}-<build>.txz"
    return 1
  fi
}

validate_package_contents() {
  local package_path="${1}"
  local package_name="${2}"
  local contents

  if ! contents="$(tar -tf "${package_path}" 2>/dev/null)"; then
    echo "Upload rejected: unable to read the txz archive."
    return 1
  fi

  package_name="${package_name:-$(basename "${package_path}")}"

  if ! echo "${contents}" | grep -Eq '(^|/)(usr/bin/nvidia-smi)$'; then
    echo "Upload rejected: package is missing usr/bin/nvidia-smi"
    return 1
  fi

  if ! echo "${contents}" | grep -Eq '(^|/)(usr/bin/nvidia-vgpu-mgr)$'; then
    echo "Upload rejected: package is missing usr/bin/nvidia-vgpu-mgr"
    return 1
  fi

  if ! echo "${contents}" | grep -Eq '(^|/)(usr/bin/nvidia-vgpud)$'; then
    echo "Upload rejected: package is missing usr/bin/nvidia-vgpud"
    return 1
  fi

  if ! echo "${contents}" | grep -Eq "(^|/)lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia\\.ko$"; then
    echo "Upload rejected: package is missing lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia.ko"
    return 1
  fi

  if ! echo "${contents}" | grep -Eq "(^|/)lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-vgpu-vfio\\.ko$"; then
    echo "Upload rejected: package is missing lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-vgpu-vfio.ko"
    return 1
  fi

  if [ "$(package_variant "${package_name}")" = "merged" ]; then
    if ! echo "${contents}" | grep -Eq "(^|/)lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-uvm\\.ko$"; then
      echo "Upload rejected: merged package is missing lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-uvm.ko"
      return 1
    fi

    if ! echo "${contents}" | grep -Eq "(^|/)lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-modeset\\.ko$"; then
      echo "Upload rejected: merged package is missing lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-modeset.ko"
      return 1
    fi

    if ! echo "${contents}" | grep -Eq "(^|/)lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-drm\\.ko$"; then
      echo "Upload rejected: merged package is missing lib/modules/${KERNEL_V}/kernel/drivers/video/nvidia-drm.ko"
      return 1
    fi

    if ! echo "${contents}" | grep -Eq '(^|/)(usr/lib64/libcuda\.so(\.[^/]+)?)$'; then
      echo "Upload rejected: merged package is missing usr/lib64/libcuda.so"
      return 1
    fi

    if ! echo "${contents}" | grep -Eq '(^|/)(usr/lib64/libnvidia-encode\.so(\.[^/]+)?)$'; then
      echo "Upload rejected: merged package is missing usr/lib64/libnvidia-encode.so"
      return 1
    fi

    if ! echo "${contents}" | grep -Eq '(^|/)(usr/lib64/libnvcuvid\.so(\.[^/]+)?)$'; then
      echo "Upload rejected: merged package is missing usr/lib64/libnvcuvid.so"
      return 1
    fi
  fi
}

import_uploaded_package() {
  local upload_path="${1}"
  local original_name="${2}"
  local target_path
  if [ ! -f "${upload_path}" ]; then
    echo "Upload rejected: temporary upload file not found."
    return 1
  fi

  validate_package_name "${original_name}" || return 1
  validate_package_contents "${upload_path}" "${original_name}" || return 1

  ensure_package_dir
  target_path="${PACKAGE_DIR}/${original_name}"
  rm -f "${target_path}" "${target_path}.md5"
  mv -f "${upload_path}" "${target_path}"
  md5sum "${target_path}" | awk '{print $1}' > "${target_path}.md5"
  echo "Imported Nvidia vGPU Driver Package $(package_label "${original_name}")"
}

download_package() {
  local package_name="${1}"
  local package_path
  local md5_path
  local tmp_package
  local tmp_md5

  ensure_package_dir
  package_path="${PACKAGE_DIR}/${package_name}"
  md5_path="${PACKAGE_DIR}/${package_name}.md5"
  tmp_package="${package_path}.part"
  tmp_md5="${md5_path}.part"

  rm -f "${package_path}" "${md5_path}" "${tmp_package}" "${tmp_md5}"

  if wget -q --show-progress --progress=bar:force:noscroll -O "${tmp_package}" "${DL_URL}/${package_name}"; then
    wget -q --show-progress --progress=bar:force:noscroll -O "${tmp_md5}" "${DL_URL}/${package_name}.md5"
    if [ "$(md5sum "${tmp_package}" | awk '{print $1}')" != "$(awk '{print $1}' "${tmp_md5}")" ]; then
      echo
      echo "-----ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR - ERROR------"
      echo "--------------------------------CHECKSUM ERROR!---------------------------------"
      rm -f "${tmp_package}" "${tmp_md5}"
      exit 1
    fi
    mv -f "${tmp_package}" "${package_path}"
    mv -f "${tmp_md5}" "${md5_path}"
    echo
    echo "-----------Successfully downloaded Nvidia vGPU Driver Package $(package_label "${package_name}")-----------"
  else
    echo
    echo "---------------Can't download Nvidia vGPU Driver Package $(package_label "${package_name}")----------------"
    rm -f "${tmp_package}" "${tmp_md5}"
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
  echo "----------------Downloading Nvidia vGPU Driver Package $(package_label "${package_name}")-----------------"
  echo "---------This could take some time, please don't close this window!------------"
  download_package "${package_name}"
  echo
  echo "----Driver $(package_label "${package_name}") is downloaded and ready for install actions.----"
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
  relink_nvidia_userspace
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

  if ! /sbin/upgradepkg --install-new --reinstall "${PACKAGE_DIR}/${package_name}" >/dev/null; then
    echo "Failed to install Nvidia vGPU Driver Package $(package_label "${package_name}")"
    return 1
  fi
  activate_driver
  echo
  echo "----------------Installed Nvidia vGPU Driver Package $(package_label "${package_name}")----------------"
}

prepared_version() {
  local package_name

  package_name="$(resolve_local_target_package)"
  if [ -n "${package_name}" ]; then
    package_selector "${package_name}"
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

  target_version="$(package_label "${package_name}")"
  installed_version="$(current_installed_version)"

  if [ "${installed_version}" = "$(package_version "${package_name}")" ]; then
    relink_nvidia_userspace "${installed_version}"
    exit 0
  fi

  echo "Applying prepared Nvidia vGPU Driver Package ${target_version} during boot..."
  stop_vgpu_services
  if ! unload_nvidia_modules >/dev/null 2>&1; then
    echo "Failed to unload existing Nvidia modules during boot apply."
    exit 1
  fi
  if ! install_local_package "${package_name}"; then
    exit 1
  fi
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

  target_version="$(package_label "${package_name}")"

  echo
  echo "----------------Starting experimental hot upgrade to ${target_version}----------------"
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
  echo "Scheduling reboot to install Nvidia vGPU Driver Package $(package_label "${selected_pkg}")..."
  /usr/local/emhttp/plugins/dynamix/scripts/notify -e "Nvidia vGPU Driver" -d "Reboot scheduled to install Nvidia vGPU Driver $(package_label "${selected_pkg}")" -i "alert" -l "/Main"
  nohup bash -c 'sleep 3; /sbin/reboot' >/dev/null 2>&1 &
}

setup_logging "${1}"

case "${1}" in
  log_path)
    echo "${LOG_FILE}"
    ;;
  download_only)
    download_selected "${2}"
    ;;
  import_upload)
    import_uploaded_package "${2}" "${3}"
    ;;
  list_local_versions)
    list_local_versions
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
  current_installed_selector)
    current_installed_selector
    ;;
  selector_label)
    selector_label "${2}"
    ;;
  *)
    echo "Unknown action: ${1}"
    exit 1
    ;;
esac
