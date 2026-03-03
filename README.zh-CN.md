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
sudo ./unraid-nvidia-building.sh -u linux-<version>-Unraid -n <nvidia_vgpu_kvm_package>.run -g <nvidia_grid_package>.run
```

- 示例：

```shell
sudo ./unraid-nvidia-building.sh \
  -u linux-6.12.24-Unraid \
  -n NVIDIA-Linux-x86_64-535.247.02-vgpu-kvm.run \
  -g NVIDIA-Linux-x86_64-535.247.01-grid.run
```

- 1. 在 Unraid 应用商店中安装 `User Scripts`
- 2. 创建一个新的运行脚本（名称可自定义）
- 3. 将下面内容填入新创建的脚本

```shell
#!/bin/bash
# set -x

## Modify the following variables to suit your environment
#WIN is the UUID for a VM
#UBU is a second UUID for a VM. These two allow for splitting the GPU
#NVPCI is the PCI ID for the GPU. Check the tools tab for this number
#MDEVLIST is the profile you are going to use from the supported MDEVCTL list
WIN="2b6976dd-8620-49de-8d8d-ae9ba47a50db"
UBU="5fd6286d-06ac-4406-8b06-f26511c260d3"
NVPCI="0000:03:00.0"
MDEVLIST="nvidia-65"

#define UUIDs for GPU
#Change the variables below to match the ones above
arr=( "${WIN}" "${UBU}" )

for os in "${arr[@]}"; do
    if [[ "$(mdevctl list)" == *"$os"* ]]; then
        echo " [i] Found $os running, stopping and undefining..."
        mdevctl stop -u "$os"
        mdevctl undefine -u "$os"
    fi
done

for os in "${arr[@]}"; do
    echo " [i] Defining and running $os..."
    mdevctl define -u "$os" -p "$NVPCI" --type "$MDEVLIST"
    mdevctl start -u "$os"
done

echo " [i] Currently defined mdev devices:"
mdevctl list
```

- 4. 将该脚本设置为阵列启动时自动运行
- 5. 在虚拟机 XML 模板中加入以下内容：

    <hostdev mode='subsystem' type='mdev' managed='yes' model='vfio-pci' display='off' ramfb='off'>
      <source>
        <address uuid='2b6976dd-8620-49de-8d8d-ae9ba47a50db'/>
      </source>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x08' function='0x0'/>
    </hostdev>

- `uuid`、`bus`、`slot` 请根据你的实际环境修改


### 致谢
- 感谢 `stl88083365` 提供 unraid 插件基础
- 感谢 Discord 用户 `@mbuchel` 提供实验性补丁
- 感谢 Discord 用户 `@LIL'pingu` 提供扩展的 43 错误修复
- 特别感谢 `@DualCoder`，没有他的工作（`vGPU_Unlock`）就不会有这个项目
- 感谢 Discord 用户 `@snowman` 创建此 patcher
- 感谢 Discord 用户 `@midi` 编写这些 shell 脚本
