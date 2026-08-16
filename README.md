# Unraid Nvidia vGPU Driver plugin
[中文说明](README.zh-CN.md)

Packages without the `merged` marker are KVM-only and focus on vGPU usage in virtual machines. Packages that include the `merged` marker are intended for merged Docker + vGPU deployments.

- Latest version currently supported: Check releases tab

- Unraid driver for vgpu. Split GPU amongst VMs

- This is the repository for the Unraid vGPU Driver plugin.

- Install plugin (Plugins -> Install Plugin):
- https://raw.githubusercontent.com/CaffeineCM/unraid-novidio-vgpu-driver/master/novidio-vgpu-driver.plg

## Build Driver Packages

- Plain KVM-only packages keep the original filename format:
- `nvidia-<version>-<kernel>-<build>.txz`

- Merged packages include the `merged` marker in the filename:
- `nvidia-<version>-merged-<kernel>-<build>.txz`

- Build a plain KVM package:

```shell
sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_vgpu_kvm_package>.run
```

- Build a merged Docker + vGPU package:

```shell
sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_vgpu_kvm_package>.run -g <nvidia_base_driver_package>.run
```

- `-g` should point to the matching standard Linux NVIDIA driver runfile, for example `NVIDIA-Linux-x86_64-535.247.01.run`, not the `*-grid.run` guest package.

- Example:

```shell
sudo ./unraid-nvidia-building.sh \
  -u linux-6.12.24-Unraid \
  -n NVIDIA-Linux-x86_64-535.247.02-vgpu-kvm.run \
  -g NVIDIA-Linux-x86_64-535.247.01.run
```

## vGPU Unlock and profile selection

`vGPU Unlock` is disabled by default. Enable it from **Settings -> Novidio Vgpu Driver** only when the active NVIDIA branch no longer exposes profiles for the physical GPU, then reboot before creating mdev devices.

Profile IDs are driver-branch specific. For example, with vGPU 17 / R550, an unlocked Tesla P4 can expose the 4 GB profile as `GRID V40-4Q` / `nvidia-49` instead of the older `GRID P4-4Q` / `nvidia-65`. Always use the current values shown under **mdev Types** in the plugin page. Do not copy a type ID from another driver version.

Unlock metadata can describe the spoofed target GPU rather than the physical card. Keep the total framebuffer assigned to active vGPUs within the physical GPU capacity, and leave framebuffer available for Docker workloads in a merged deployment.

## Create mdev devices

Install `User Scripts`, create a script that runs when the array starts, and adapt the following values. The script resolves the current type ID by profile name and does not require `mdevctl`.

```shell
#!/bin/bash
set -euo pipefail

NVPCI="0000:03:00.0"
PROFILE_NAME="GRID V40-4Q"
UUIDS=(
  "2b6976dd-8620-49de-8d8d-ae9ba47a50db"
)

TYPE_ROOT="/sys/class/mdev_bus/${NVPCI}/mdev_supported_types"
TYPE_PATH=""

for i in {1..60}; do
  for candidate in "${TYPE_ROOT}"/*; do
    [ -r "${candidate}/name" ] || continue
    if [ "$(cat "${candidate}/name")" = "${PROFILE_NAME}" ]; then
      TYPE_PATH="${candidate}"
      break
    fi
  done
  [ -n "${TYPE_PATH}" ] && break
  sleep 2
done

if [ -z "${TYPE_PATH}" ]; then
  echo "Profile not found: ${PROFILE_NAME}" >&2
  find "${TYPE_ROOT}" -mindepth 2 -maxdepth 2 -type f -name name -print -exec cat {} \; 2>/dev/null || true
  exit 1
fi

echo "Using ${PROFILE_NAME} ($(basename "${TYPE_PATH}")) on ${NVPCI}"

for uuid in "${UUIDS[@]}"; do
  if [ -e "/sys/bus/mdev/devices/${uuid}/remove" ]; then
    echo 1 > "/sys/bus/mdev/devices/${uuid}/remove"
  fi
  echo "${uuid}" > "${TYPE_PATH}/create"
done

find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -type l -printf '%f\n'
```

Add the corresponding UUID to the VM XML. Because the User Script creates the device, use `managed='no'`:

```xml
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source>
    <address uuid='2b6976dd-8620-49de-8d8d-ae9ba47a50db'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x08' function='0x0'/>
</hostdev>
```

Adjust the UUID, bus, and slot for the VM.

## Merged Docker + vGPU

Use a package whose filename contains `merged`. The VM consumes an mdev UUID, while Docker must use the physical GPU UUID reported by `nvidia-smi -L`; an mdev UUID is not a CUDA/NVIDIA Container Toolkit device selector.

For an NVIDIA Docker container, maintain these values:

```text
Extra Parameters: --runtime=nvidia
NVIDIA_VISIBLE_DEVICES=GPU-<physical-GPU-UUID>
NVIDIA_DRIVER_CAPABILITIES=all
```

The vGPU framebuffer remains reserved while the VM is running. Docker uses the remaining physical GPU memory and engines, so size the vGPU profiles accordingly.


### Credits
- Thanks to stl88083365 for the unraid plugin foundation
- Thanks to the discord user @mbuchel for the experimental patches
- Thanks to the discord user @LIL'pingu for the extended 43 crash fix
- Special thanks to @DualCoder without his work (vGPU_Unlock) we would not be here
- and thanks to the discord user @snowman for creating this patcher
- thanks to the discord user @midi creating this shell scripts
