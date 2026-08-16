# Unraid Nvidia vGPU Driver 插件
[English README](README.md)

不带 `merged` 标记的驱动包为单独的 KVM 版本，主要面向虚拟机中的 vGPU 使用。带 `merged` 标记的驱动包用于支持 Docker + vGPU 的 merged 部署场景。

- 当前支持的最新版本：请查看 Releases 页面

- 这是一个适用于 Unraid 的 vGPU 驱动，可将一张 GPU 划分给多个虚拟机使用

- 本仓库用于维护 Unraid vGPU Driver 插件

- 安装插件（`Plugins -> Install Plugin`）：
- `https://raw.githubusercontent.com/CaffeineCM/unraid-novidio-vgpu-driver/master/novidio-vgpu-driver.plg`

## 构建驱动包

- 单独的 KVM 驱动包继续保持原有命名格式：
- `nvidia-<version>-<kernel>-<build>.txz`

- merged 驱动包会在文件名中带上 `merged` 标记：
- `nvidia-<version>-merged-<kernel>-<build>.txz`

- 构建单独的 KVM 驱动包：

```shell
sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_vgpu_kvm_package>.run
```

- 构建支持 Docker + vGPU 的 merged 驱动包：

```shell
sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_vgpu_kvm_package>.run -g <nvidia_base_driver_package>.run
```

- `-g` 需要传入同版本分支的标准 Linux NVIDIA 驱动 `run` 文件，例如 `NVIDIA-Linux-x86_64-535.247.01.run`，而不是 `*-grid.run` 这种 guest 驱动包。

- 示例：

```shell
sudo ./unraid-nvidia-building.sh \
  -u linux-6.12.24-Unraid \
  -n NVIDIA-Linux-x86_64-535.247.02-vgpu-kvm.run \
  -g NVIDIA-Linux-x86_64-535.247.01.run
```

## vGPU Unlock 与 Profile 选择

`vGPU Unlock` 默认关闭。只有当前 NVIDIA 分支不再为物理 GPU 提供 Profile 时，才在 **设置 -> Novidio Vgpu Driver** 中启用它；修改后必须重启，再创建 mdev 设备。

Profile ID 会随驱动分支变化。例如在 vGPU 17 / R550 中，解锁后的 Tesla P4 可能把原来的 `GRID P4-4Q` / `nvidia-65` 映射为 `GRID V40-4Q` / `nvidia-49`。必须使用插件页面 **mdev Types** 当前显示的值，不能直接沿用其他驱动版本的类型编号。

解锁后显示的容量与实例上限可能来自被模拟的目标 GPU，而不是物理显卡。所有运行中 vGPU 的显存总量不能超过物理显存；merged 部署还要给 Docker 留出显存。

## 创建 mdev 设备

安装 `User Scripts`，新建一个随阵列启动的脚本，并按实际环境修改以下参数。脚本会按 Profile 名称解析当前类型编号，不依赖 `mdevctl`。

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

把对应 UUID 加入虚拟机 XML。由于设备由 User Script 预先创建，使用 `managed='no'`：

```xml
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source>
    <address uuid='2b6976dd-8620-49de-8d8d-ae9ba47a50db'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x08' function='0x0'/>
</hostdev>
```

请按虚拟机实际配置调整 UUID、bus 和 slot。

## merged Docker + vGPU

必须选择文件名包含 `merged` 的驱动包。虚拟机使用 mdev UUID；Docker 必须使用 `nvidia-smi -L` 返回的物理显卡 `GPU-*` UUID，mdev UUID 不是 CUDA / NVIDIA Container Toolkit 的设备选择器。

NVIDIA Docker 容器需要维护以下参数：

```text
Extra Parameters: --runtime=nvidia
NVIDIA_VISIBLE_DEVICES=GPU-<物理显卡UUID>
NVIDIA_DRIVER_CAPABILITIES=all
```

虚拟机运行时会保留其 vGPU 显存；Docker 使用剩余的物理显存和计算单元，因此需要据此选择 vGPU Profile 大小。


### 致谢
- 感谢 `stl88083365` 提供 unraid 插件基础
- 感谢 Discord 用户 `@mbuchel` 提供实验性补丁
- 感谢 Discord 用户 `@LIL'pingu` 提供扩展的 43 错误修复
- 特别感谢 `@DualCoder`，没有他的工作（`vGPU_Unlock`）就不会有这个项目
- 感谢 Discord 用户 `@snowman` 创建此 patcher
- 感谢 Discord 用户 `@midi` 编写这些 shell 脚本
