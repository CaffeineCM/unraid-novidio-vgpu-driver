#!/bin/bash
# SPDX-License-Identifier: GPL-3.0

# For debugging purposes
# set -x

# Quick and (very) dirty script to make novideo drivers for vgpu guest
# for unraid 
# Credits:midi1996
#         samicrusader#4026
#         ich777
## Check if Script is running as root

if [ "$(id -u)" != 0 ]; then
	cat <<R

  [!] Not running as root.
  [i] Please run the script again as root.
  [i] Run: 
  [i] sudo bash $(basename $0) [flags]
  [i] Exiting...

R
	exit 1
fi

######## FUNCTIONS ##########

cleanup () {
	echo -ne "\r"
	echo " [<] Cleaning up the mess..."
	echo "  [?] Do you want to cleanup $DATA_TMP and remove it?"
	echo "  [?] Type Y to confirm or any key to cancel."
	read clsans
	if [[ "${clsans,,}" == "y" ]]; then
		echo "  [!] Cleaning up..."
		rm -rf "${DATA_TMP}" && echo " [i] Cleaned up! Exiting." || { echo "  [!] Error while removing $DATA_TMP. Bailing out."; exit 1; }
	else
		echo "  [!] Not cleaning up. Exiting now."
	fi
	exit 1
}

print_usage() {
	cat <<EOF

 [i] Usage: sudo bash $(basename "$0") -n NVIDIA_VGPU_KVM_RUN.run -u UNRAID_SOURCE_FOLDER [-g NVIDIA_BASE_DRIVER.run] [-s] [-c]
 [i] -n NVIDIA_VGPU_KVM_RUN.run
 [i] -g NVIDIA_BASE_DRIVER.run
 [i] -u UNRAID_SOURCE_FOLDER (linux-X.XX.XX-Unraid)

EOF
}

driver_version_from_run() {
	local run_file="${1}"
	local version

	version="$(sh "${run_file}" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	if [[ -z "${version}" ]]; then
		version="$(basename "${run_file}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	fi

	echo "${version}"
}

driver_branch() {
	local version="${1}"

	echo "${version}" | awk -F. '{print $1 "." $2}'
}

files_prepare () {
	echo
	touch "${LOG_F}" || { echo " [!] Error creating log file."; exit 1; }
	echo " [i] Log file created: ${LOG_F}"
	echo " [>] Running some tests..."
	if [[ -n "${NV_RUN}" ]]; then
		[ ! -e "${DATA_DIR}/${NV_RUN}" ] && echo " [!] Nvidia vGPU host driver package not found: ${NV_RUN}" && exit 1
		echo "  [i] Retrieving Nvidia drivers version from package..."
		echo "  [i] It might take a while... Please wait."
 	 	NV_DRV_V=$(driver_version_from_run "${DATA_DIR}/${NV_RUN}")
 		if [[ -z "${NV_DRV_V}" ]]; then
  		echo "  [!] Error while getting Nvidia drivers version, please check package or with '--version' flag."
  		exit 1
  	fi
  	echo "  [✓] Got Nvidia driver version: ${NV_DRV_V} "
	fi
	if [[ -n "${GRID_RUN}" ]]; then
		[ ! -e "${DATA_DIR}/${GRID_RUN}" ] && echo " [!] Nvidia base driver package not found: ${GRID_RUN}" && exit 1
		echo "  [i] Retrieving base driver version from package..."
		echo "  [i] It might take a while... Please wait."
		GRID_DRV_V=$(driver_version_from_run "${DATA_DIR}/${GRID_RUN}")
		if [[ -z "${GRID_DRV_V}" ]]; then
			echo "  [!] Error while getting base driver version, please check package or with '--version' flag."
			exit 1
		fi
		echo "  [✓] Got base driver version: ${GRID_DRV_V} "
	fi
	if [[ -n "${NV_DRV_V}" ]] && [[ -n "${GRID_DRV_V}" ]] && [[ "$(driver_branch "${NV_DRV_V}")" != "$(driver_branch "${GRID_DRV_V}")" ]]; then
		echo "  [!] The vGPU host driver (${NV_DRV_V}) and base driver (${GRID_DRV_V}) are not from the same branch."
		exit 1
	fi
	FREE_STG=$(df -k --output=avail "$PWD" | tail -n1)
	[ "${FREE_STG}" -lt $((7*1024*1024)) ] && echo "  [!] Not enough disk space. Make sure that you have 7GB free." && exit 1 || echo " [✓] Enough free space on disk."
	if wget -q --spider https://kernel.org
	then
		echo " [✓] Internet Available."
	else
		echo " [!] Internet Unvailable."
		exit 1
	fi
	echo ""
	echo " [>] Preparing folder structure..."
	if [[ -z "${SKIP_KERNEL}" ]] && [[ -d "${DATA_TMP}" ]]; then
		echo " [!] Old tmp folder found."
		echo "  [?] Do you want to delete the old temporiry file 'tmp'?"
		echo "  [?] Press 1 for yes or 2 for no"
		select ans in "Yes" "No"; do
			case $ans in
				Yes )
					echo "  [>] Proceeding with the deletion..."
					rm -rf "${DATA_TMP}" || { echo "   [!] Error while deleting the old temporaryf folder. Please delete it manually."; exit 1; }
					echo " [✓] Old output deleted."
					break
					;;
				No ) 
					echo " [!] Using old tmp folder! Errors may occure."
					break
			 		;;
			esac
		done
	fi
	mkdir -p "${DATA_TMP}" 
	for stage_dir in "${PKG_TMP_D}" "${VGPU_TMP_D}" "${GRID_TMP_D}"; do
		mkdir -p "${stage_dir}"/usr/lib64/xorg/modules/{drivers,extensions} \
				"${stage_dir}"/usr/lib \
				"${stage_dir}"/usr/bin \
				"${stage_dir}"/etc \
				"${stage_dir}"/lib/modules/"${UNAME%/}"/kernel/drivers/video \
				"${stage_dir}"/lib/firmware || { echo "  [!] Error making destination folder"; exit 1; }
	done
	echo " [✓] Folders created."
	echo " [✓] Done preparing."
	echo
}

build_kernel () {
	echo " [>] Building kernel sauce..."
	echo "  [>] Downloading Linux ${LNX_FULL_VER} Sauce..."
	cd "${DATA_TMP}"
	wget -q -nc -4c --show-progress --progress=bar:force:noscroll https://mirrors.edge.kernel.org/pub/linux/kernel/v"${LNX_MAJ_NUMBER}".x/linux-"${LNX_FULL_VER}".tar.xz || { echo "  [!] Error downloading the kernel source."; exit 1; }
	echo "  [>] Extracting the kernel sauce..." 
	tar xf ./linux-"${LNX_FULL_VER}".tar.xz || { echo "  [!] Error while extracting the linux source"; exit 1; }
	cd ./linux-"${LNX_FULL_VER}" || { echo "  [!] Error while changing to the linux source folder"; exit 1; }
	echo "   [✓] Extracted kernel sauce ${LNX_FULL_VER}."
	echo "  [>] Applying Unraid patches..."
	cp -r "${DATA_DIR}"/"${UNRAID_DIR}" "${DATA_TMP}"/"${UNAME%/}"
	find "${DATA_TMP}"/"${UNAME%/}"/ -type f -name '*.patch' -exec patch -p1 -i {} \; -delete >>"${LOG_F}" 2>&1 || { echo "  [!] Couldn't Patch the source, exiting..."; exit 1; }
	echo "   [✓] Applied Unraid patches to the kernel sauce."
	echo "  [>] Merging Unraid config and files..."
	cp "${DATA_TMP}"/"${UNAME%/}"/.config . || { echo "  [!] Couldn't find .config file in your Unraid folder, exiting..."; exit 1; }
	cp -r "${DATA_TMP}"/"${UNAME%/}"/drivers/md/* drivers/md/ || { echo "  [!] Couldn't find drivers/md folder in your Unraid folder, exiting..."; exit 1; }
	echo "   [✓] Merged Unraid config and files..."
	echo "  [>] Building the kernel..." 
	make -j$(nproc) >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error Building the kernel.\n  [!] Please check ${LOG_F} .\n"; exit 1; }
	make -j$(nproc) modules >>"${LOG_F}" 2>&1 || { echo -e "\n  [!] Error Building the kernel modules.\n  [!] Please check ${LOG_F} .\n"; exit 1; }
	echo " [✓] Done cooking the sauce."
	echo
}

link_sauce () {
	# Prepare kernel source build directory
	echo " [>] Linking source dir to host /lib/modules "
	cd "${DATA_TMP}"
	mkdir -p /lib/modules/"${UNAME%/}" || { echo "  [!] Error making /lib/modules/${UNAME%/} folder"; exit 1; }
	ln -sf "${DATA_TMP}"/linux-"${LNX_FULL_VER}" /lib/modules/"${UNAME%/}"/build || { echo "  [!] Error linking /lib/modules/""${UNAME%/}"" folder"; exit 1; } 
	echo " [✓] Linked."
	echo
}

prepare_installer_host() {
	if [[ "${INSTALLER_HOST_PREPARED}" -eq 1 ]]; then
		return 0
	fi

	if [[ -f /var/log/nvidia-installer.log ]]; then
		echo "  [>] Removing old Nvidia Installer logs..."
		rm -f /var/log/nvidia-installer.log || echo "  [!] Error while removing old Nvidia Installer logs. Continuing..."
	fi

	if command -v nvidia-uninstall >/dev/null 2>&1 || modinfo nvidia >/dev/null 2>&1; then
		cat <<Q
  [?] On host systems with Nvidia drivers are already installed
  [?] driver conflicts and system breaks can happen.
  [?] Make sure you're running this IN A VM!
  [?] This script will attempt uninstalling Nvidia drivers
  [?] before proceeding to clean up the system.
  [?] Press Enter to continue, or Ctrl+C to stop the script!
Q
		read -r -p ""
		echo "  [>] Uninstalling Nvidia drivers..."
		sh "${DATA_DIR}/${NV_RUN}" --uninstall --silent >>"${LOG_F}" 2>&1 || true
		cat <<UF
  [?] Uninstall is complete. Reguardless of the success,
  [?] it's only for cleanup.
  [i] Proceeding...
UF
	fi

	INSTALLER_HOST_PREPARED=1
}

install_runfile() {
	local run_file="${1}"
	local target_dir="${2}"
	local label="${3}"
	local run_path="${DATA_DIR}/${run_file}"
	local extracted_dir
	local installer_dir
	local nv_pid
	local tail_pid
	local ret=30
	local ret_c=0

	echo " [>] Installing ${label} to ${target_dir}"
	cd "${DATA_DIR}"
	chmod +x "${run_path}" || { echo " [!] Error setting chmod on ${run_file}. Exiting."; exit 1; }

	extracted_dir="$(basename "${run_file}" .run)"
	installer_dir="${DATA_TMP}/${extracted_dir}"
	if [ -d "${installer_dir}" ]; then
		echo "  [>] Removing old extracted installer folder for ${run_file}"
		rm -rf "${installer_dir}" || { echo "  [!] Error while removing old installer folder"; exit 1; }
	fi

	echo "  [>] Extracting ${label} runfile..."
	(
		cd "${DATA_TMP}" &&
		sh "${run_path}" --extract-only >>"${LOG_F}" 2>&1
	) || { echo "  [!] Error while extracting ${run_file}. Exiting."; exit 1; }

	[ -x "${installer_dir}/nvidia-installer" ] || { echo "  [!] Extracted installer not found in ${installer_dir}. Exiting."; exit 1; }

	rm -f /var/log/nvidia-installer.log || true

	cat <<NI
  [>] Installing ${label} to ${target_dir}
   [i] You might want to check the progress by running:
   [i] tail -F /var/log/nvidia-installer.log 
   [i] The output of the log will be in ${LOG_F} too.
NI

	"${installer_dir}/nvidia-installer" --kernel-name="${UNAME%/}" \
	  --no-precompiled-interface \
	  --disable-nouveau \
	  --x-prefix="${target_dir}"/usr \
	  --x-library-path="${target_dir}"/usr/lib64 \
	  --x-module-path="${target_dir}"/usr/lib64/xorg/modules \
	  --opengl-prefix="${target_dir}"/usr \
	  --installer-prefix="${target_dir}"/usr \
	  --utility-prefix="${target_dir}"/usr \
	  --documentation-prefix="${target_dir}"/usr \
	  --application-profile-path="${target_dir}"/usr/share/nvidia \
	  --proc-mount-point="${target_dir}"/proc \
	  --kernel-install-path="${target_dir}"/lib/modules/"${UNAME%/}"/kernel/drivers/video \
	  --compat32-prefix="${target_dir}"/usr \
	  --compat32-libdir=/lib \
	  --install-compat32-libs \
	  --no-x-check \
	  --no-dkms \
	  --no-nouveau-check \
	  --skip-depmod \
	  --j"${CPU_COUNT}" \
	  --silent >>"${LOG_F}" 2>&1 &

	nv_pid=$!

	tee -a "${LOG_F}" >/dev/null <<LOG

[>>] tail -F /var/log/nvidia-installer.log

LOG

	while [ ! -f /var/log/nvidia-installer.log ]
	do
		if [ "$ret_c" -ge "$ret" ]; then
			echo "   [!] Error while getting Nvidia Installer logs after $ret retries."
			exit 1
		fi
		ret_c=$((ret_c+1))
		sleep 1
	done

	tail -F /var/log/nvidia-installer.log >> "${LOG_F}" &
	tail_pid=$!

	wait "$nv_pid"
	kill "$tail_pid" >/dev/null 2>&1 || true

	echo "  [>] Checking ${label} install logs for success..."
	if grep -q "now complete" /var/log/nvidia-installer.log >>"${LOG_F}" 2>&1
	then
		echo "   [✓] ${label} seems to be installed properly."
		echo "   [i] You might want to check /var/log/nvidia-installer.log"
		for (( i=30; i>0; i-- )); do
			echo -ne "   [i] Resuming the script in $i seconds. Press any key to resume immeditely.\r"
				if IFS= read -sr -N 1 -t 1 key
				then
					break
				fi
			done
	else
		echo -e '\a'
		cat <<NQ
  [!] Nvidia Driver DOES NOT seem to be installed properly.
  [i] You might want to check /var/log/nvidia-installer.log
  [i] Press Ctrl + C to Stop the script immeditely.
  [i] Sleeping for 30 seconds before resuming.
NQ
		sleep 30
		for (( i=30; i>0; i-- )); do
			echo -ne "   [i] Resuming the script in $i seconds. Press any key to resume immeditely.\r"
				if IFS= read -sr -N 1 -t 1 key
				then
					break
				fi
			done
			read -p "   [!] Are you sure you want to continue? $(echo $'\nThe resulting package may be broken!\n Press Enter to confirm.')" -n 1 -r
	fi
	echo 

	collect_installer_artifacts "${installer_dir}" "${target_dir}" "${label}"
}

copy_matching_entries() {
	local source_dir="${1}"
	local destination_dir="${2}"
	shift 2

	local pattern
	local entry
	local -a matches=()

	mkdir -p "${destination_dir}" || { echo "  [!] Error creating ${destination_dir}"; exit 1; }

	shopt -s nullglob
	for pattern in "$@"; do
		for entry in "${source_dir}"/${pattern}; do
			matches+=("${entry}")
		done
	done
	shopt -u nullglob

	for entry in "${matches[@]}"; do
		cp -a "${entry}" "${destination_dir}"/ || { echo "  [!] Error copying ${entry} to ${destination_dir}"; exit 1; }
	done
}

collect_installer_artifacts() {
	local installer_dir="${1}"
	local target_dir="${2}"
	local label="${3}"
	local module_dir="${target_dir}/lib/modules/${UNAME%/}/kernel/drivers/video"
	local -a module_files=()
	local module_file

	echo "  [>] Collecting ${label} artifacts from ${installer_dir}"

	mapfile -t module_files < <(find "${installer_dir}/kernel" -type f -name '*.ko' 2>/dev/null)
	for module_file in "${module_files[@]}"; do
		cp -a "${module_file}" "${module_dir}"/ || { echo "  [!] Error copying kernel module ${module_file}"; exit 1; }
	done

	copy_matching_entries "${installer_dir}" "${target_dir}/usr/lib64" "lib*.so*"
	copy_matching_entries "${installer_dir}/32" "${target_dir}/usr/lib" "lib*.so*"
	copy_matching_entries "${installer_dir}" "${target_dir}/usr/bin" \
		"nvidia-smi" \
		"nvidia-debugdump" \
		"nvidia-persistenced" \
		"nvidia-cuda-mps-control" \
		"nvidia-cuda-mps-server" \
		"nvidia-modprobe" \
		"nvidia-bug-report.sh" \
		"nvidia-vgpu-mgr" \
		"nvidia-vgpud"

	echo "  [✓] Collected ${label} artifacts."
	echo
}

merge_driver_stages() {
	local source_dir

	echo " [>] Merging staged driver trees into ${PKG_TMP_D}"
	for source_dir in "${GRID_TMP_D}" "${VGPU_TMP_D}"; do
		[ -d "${source_dir}" ] || continue
		cp -a "${source_dir}"/. "${PKG_TMP_D}"/ || { echo " [!] Error while merging ${source_dir}"; exit 1; }
	done
	echo " [✓] Driver trees merged."
	echo
}

validate_merged_driver() {
	local missing=0

	check_required_path() {
		local pattern="${1}"
		local description="${2}"

		if ! compgen -G "${PKG_TMP_D}/${pattern}" >/dev/null; then
			echo " [!] Missing merged driver component: ${description} (${pattern})"
			missing=1
		fi
	}

	check_required_path "lib/modules/${UNAME%/}/kernel/drivers/video/nvidia.ko" "nvidia kernel module"
	check_required_path "lib/modules/${UNAME%/}/kernel/drivers/video/nvidia-vgpu-vfio.ko" "nvidia vgpu vfio module"
	check_required_path "lib/modules/${UNAME%/}/kernel/drivers/video/nvidia-uvm.ko" "nvidia uvm module"
	check_required_path "lib/modules/${UNAME%/}/kernel/drivers/video/nvidia-modeset.ko" "nvidia modeset module"
	check_required_path "lib/modules/${UNAME%/}/kernel/drivers/video/nvidia-drm.ko" "nvidia drm module"
	check_required_path "usr/lib64/libcuda.so*" "CUDA userspace library"
	check_required_path "usr/lib64/libnvidia-encode.so*" "NVENC userspace library"
	check_required_path "usr/lib64/libnvcuvid.so*" "NVDEC userspace library"
	check_required_path "usr/bin/nvidia-vgpu-mgr" "nvidia-vgpu-mgr userspace binary"
	check_required_path "usr/bin/nvidia-vgpud" "nvidia-vgpud userspace binary"

	if [[ "${missing}" -ne 0 ]]; then
		echo " [!] Merged driver validation failed. The resulting package would not support Docker and vGPU together."
		exit 1
	fi

	echo " [✓] Merged driver validation passed."
	echo
}

copy_files () {
	# Copy files for OpenCL and Vulkan over to temporary installation directory
	echo " [>] Copying extra files..."
	if [ -d /lib/firmware/nvidia ]; then
	  cp -R /lib/firmware/nvidia "${PKG_TMP_D}"/lib/firmware/
	fi
	cp /usr/bin/nvidia-modprobe "${PKG_TMP_D}"/usr/bin/
	cp -R /etc/OpenCL "${PKG_TMP_D}"/etc/
	cp -R /etc/vulkan "${PKG_TMP_D}"/etc/
	
	# Copy gridd related files
	cp -R /etc/nvidia "${PKG_TMP_D}"/etc/
	cp -R /usr/lib/nvidia "${PKG_TMP_D}"/usr/lib/
	cp -R /usr/share/nvidia "${PKG_TMP_D}"/usr/share/
	echo " [✓] File copy is done. Please check for any errors."
	echo
}

libnvidia_inst () {
	# Download libnvidia-container, nvidia-container-runtime & container-toolkit and extract it to temporary installation directory
	# Source libnvidia-container: https://github.com/ich777/libnvidia-container
	# Source nvidia-container-runtime: https://github.com/ich777/nvidia-container-runtime
	# Source nvidia-container-toolkit: https://github.com/ich777/nvidia-container-toolkit
	echo " [>] Copying Docker-related files..."

	cd "${DATA_TMP}"
	if [ ! -f "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz ]; then
	  wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz "https://github.com/ich777/libnvidia-container/releases/download/${LIBNVIDIA_CONTAINER_V}/libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz" || { echo "Error downloading libnvidia-container-v${LIBNVIDIA_CONTAINER_V}.tar.gz"; exit 1; }
	fi
	tar -C "${PKG_TMP_D}"/ -xf "${DATA_TMP}"/libnvidia-container-v"${LIBNVIDIA_CONTAINER_V}".tar.gz || { echo "Error while extracting libnvidia-container package"; exit 1; }

	cd "${DATA_TMP}"
	if [ ! -f "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz ]; then
	  wget -q -nc --show-progress --progress=bar:force:noscroll -O "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz "https://github.com/ich777/nvidia-container-toolkit/releases/download/${CONTAINER_TOOLKIT_V}/nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz" || { echo "Error downloading nvidia-container-toolkit-v${CONTAINER_TOOLKIT_V}.tar.gz"; exit 1; }
	fi
	tar -C "${PKG_TMP_D}"/ -xf "${DATA_TMP}"/nvidia-container-toolkit-v"${CONTAINER_TOOLKIT_V}".tar.gz || { echo "Error while extracting nvidia-container-toolkit package"; exit 1; }

	echo " [✓] Docker-related files copied."
	echo ""
}

package_building () {
	# Create Slackware package
	echo " [>] Making Slackware Package..."

	PLUGIN_NAME="nvidia-driver"
	BASE_DIR="${PKG_TMP_D}/"
	TMP_DIR="${DATA_TMP}/${PLUGIN_NAME}_$(echo $RANDOM)"
	# TMP_DIR="/tmp/${PLUGIN_NAME}_$(echo $RANDOM)"
	VERSION="$(date +'%Y.%m.%d')"
	PACKAGE_BASENAME="${PLUGIN_NAME%%-*}-${NV_DRV_V}"

	if [[ -n "${GRID_RUN}" ]]; then
		PACKAGE_BASENAME="${PACKAGE_BASENAME}-merged"
	fi

	PACKAGE_BASENAME="${PACKAGE_BASENAME}-${UNAME%/}-1"

	mkdir -p "$TMP_DIR"/"$VERSION"
	cd "$TMP_DIR"/"$VERSION"
	cp -R "$BASE_DIR"/* "$TMP_DIR"/"$VERSION"/
	mkdir "$TMP_DIR"/"$VERSION"/install
	tee -a "$TMP_DIR"/"$VERSION"/install/slack-desc >/dev/null <<EOF
	   |-----handy-ruler------------------------------------------------------|
$PLUGIN_NAME: $PLUGIN_NAME Package contents:
$PLUGIN_NAME:
$PLUGIN_NAME: Nvidia-Driver v${NV_DRV_V}
$PLUGIN_NAME: libnvidia-container v${LIBNVIDIA_CONTAINER_V}
$PLUGIN_NAME: nvidia-container-toolkit v${CONTAINER_TOOLKIT_V}
$PLUGIN_NAME:
$PLUGIN_NAME:
$PLUGIN_NAME: Custom $PLUGIN_NAME for Unraid Kernel v${UNAME%%-*} by you
$PLUGIN_NAME:
EOF

	MAKEPKG=
	if command -v makepkg
	then
			echo " [*] makepkg is installed... Proceeding."
			MAKEPKG=$(which makepkg)
	else
		cat <<Q
  [!] This system does not have makepkg installed
  [!] Press Enter to continue and install
  [!] makepkg temporarily. Otherwise
  [!] press Ctrl+C to cancel, the driver package
  [!] will NOT be created.
Q
		read -p ""
		echo "  [>] Installing makepkg to ${DATA_TMP}..."
		if ! ls "${DATA_TMP}"/pkgtools*.txz 1> /dev/null 2>&1
		then
			echo "    [!] pkgtools not found. Downloading..."
			wget -q -nc --show-progress --progress=bar:force:noscroll https://slackware.uk/slackware/slackware64-15.0/slackware64/a/pkgtools-15.0-noarch-42.txz -P "${DATA_TMP}" || { echo "    [!] Error while downloading pkgtools package, please download Slackware pkgtool and put it manually in ${DATA_TMP}"; exit 1; }
		fi
		tar -C "${DATA_TMP}" -xf "${DATA_TMP}"/pkgtools* >>"${LOG_F}" 2>&1
		MAKEPKG=${DATA_TMP}/sbin/makepkg
		command -v "${MAKEPKG}" 1> /dev/null 2>&1 && echo "    [✓] makepkg has been installed to ${DATA_TMP}" || { echo "    [!] makepkg was not installed properly. Quitting."; exit 1; }
	fi
	echo "  [>] Making the package, this might take a while..."
	"${MAKEPKG}" -l n -c n "$TMP_DIR"/"${PACKAGE_BASENAME}".txz >>"${LOG_F}" 2>&1
	md5sum "$TMP_DIR"/"${PACKAGE_BASENAME}".txz | awk '{print $1}' | tee -a "$TMP_DIR"/"${PACKAGE_BASENAME}".txz.md5 >>"${LOG_F}" 2>&1
	echo "  [>] Creating Out folder in ${DATA_DIR}"
	mkdir -p "${DATA_DIR}"/out && echo " [✓] Created Out dir."
	echo "  [>] Copying the resulting drivers..."
	cp -R "$TMP_DIR"/"${PACKAGE_BASENAME}".txz* "${DATA_DIR}"/out
	echo ""
	echo "   [i] Filename: ${DATA_DIR}/out/${PACKAGE_BASENAME}.txz"
	echo "   [i] MD5 Hash: $(cat ${DATA_DIR}/out/${PACKAGE_BASENAME}.txz.md5)"
	echo "   [i] Size: $(du -kh ${DATA_DIR}/out/${PACKAGE_BASENAME}.txz | cut -f1)"
	echo ""
	echo " [✓] Done, check for errors."
	echo -e '\a'
}

run_cmd() {
	# catches errors and shows the line

    local command="$@"
    local exit_status=0
    local line_number=$LINENO

    # Run the command
    eval "$command"
    exit_status=$?

    # Check the exit status
    if [ $exit_status -ne 0 ]; then
        echo "[!] Command failed with exit status $exit_status at line $line_number"
        exit $exit_status
    fi
}

main_run() {
	trap cleanup INT
	run_cmd files_prepare
	if [[ -z "${SKIP_KERNEL}" ]]; then
		run_cmd build_kernel
	fi
	run_cmd link_sauce
	run_cmd prepare_installer_host
	if [[ -n "${GRID_RUN}" ]]; then
		run_cmd "install_runfile \"${GRID_RUN}\" \"${GRID_TMP_D}\" \"base driver\""
	fi
	run_cmd "install_runfile \"${NV_RUN}\" \"${VGPU_TMP_D}\" \"vGPU host driver\""
	run_cmd merge_driver_stages
	if [[ -n "${GRID_RUN}" ]]; then
		run_cmd validate_merged_driver
	fi
	run_cmd copy_files
	run_cmd libnvidia_inst
	run_cmd package_building
}

######### SCRIPT ##########

# Options setup

while getopts 'n:g:u:shc' OPTION; do
	case "$OPTION" in
		n)
			NV_RUN="$OPTARG"
			echo " [i] Got Nvidia vGPU host driver: ${NV_RUN}"
			;;
		g)
			GRID_RUN="$OPTARG"
			echo " [i] Got Nvidia base driver: ${GRID_RUN}"
			;;
		u)
			UNRAID_DIR="$OPTARG"
			echo " [i] Got Unraid source: ${UNRAID_DIR}"
			;;
		s)
			SKIP_KERNEL=1
			echo " [i] Skipping kernel build. ONLY USE THIS IF KERNEL IS ALREADY BUILT!"
			;;
		h)
			print_usage
			exit 0
			;;
		c)
			echo -e "\n [i] Cleaning up after script end."
			CLEANUP_END=1
			exit 0
			;;
		?)
			print_usage
			exit 1
			;;
	esac
done

# Actual RUN

## Sauces ##

	# Source libnvidia-container: https://github.com/ich777/libnvidia-container
	# Source nvidia-container-runtime: https://github.com/ich777/nvidia-container-runtime
	# Source nvidia-container-toolkit: https://github.com/ich777/nvidia-container-toolkit

## VARS ##

  # WORK DIRS
DATA_DIR=$(pwd)
DATA_TMP=$(pwd)/tmp
PKG_TMP_D="${DATA_TMP}/NVIDIA"
VGPU_TMP_D="${DATA_TMP}/NVIDIA_VGPU"
GRID_TMP_D="${DATA_TMP}/NVIDIA_GRID"
LOG_F="$DATA_DIR/logfile_$(date +'%Y.%m.%d')_$RANDOM".log

  # System Cap
CPU_COUNT=$(nproc)

  # Features
SKIP_KERNEL=
CLEANUP_END=0
INSTALLER_HOST_PREPARED=0

  # Docker Support
LIBNVIDIA_CONTAINER_V=1.14.3
CONTAINER_TOOLKIT_V=1.14.3

if [[ -z "${NV_RUN}" ]] || [[ -z "${UNRAID_DIR}" ]]; then
	if [[ "${CLEANUP_END}" -eq 1 ]]; then
		run_cmd cleanup
	else
		echo " [!] Please provide both [-u] and [-n]."
		print_usage
	exit 1
	fi
elif [[ -n ${NV_RUN} ]] && [[ -n ${UNRAID_DIR} ]]; then
	tee <<WEL

 [!] Welcome to Nvidia driver packager for Unraid
 [!] Note: Use [-g] with a matching standard Linux driver runfile to build a merged Docker + vGPU package.
 [!] Sleeping 3 seconds before proceeding...

WEL
	sleep 3
	UNAME=$(echo "${UNRAID_DIR}" | sed 's/linux-//')
	LNX_MAJ_NUMBER=$(echo "${UNAME%/}" | cut -d "." -f1)
	LNX_FULL_VER=$(echo "${UNAME%/}" | cut -d "-" -f1)
	declare -g UNAME
	declare -g LNX_MAJ_NUMBER
	declare -g LNX_FULL_VER
	# declare -g LIBNVIDIA_CONTAINER_V=1.14.3
	# declare -g CONTAINER_TOOLKIT_V=1.14.3
	if [[ "${CLEANUP_END}" -eq 1 ]]; then
		run_cmd main_run
		run_cmd cleanup
	else
		run_cmd main_run
	fi
fi

echo <<END

	[!] Script Ended.

END

exit 0
