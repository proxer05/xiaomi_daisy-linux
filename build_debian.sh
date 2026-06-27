#!/usr/bin/env bash
#
# build_debian.sh — Build a Debian Bookworm ARM64 image for Xiaomi Mi A2 Lite (daisy/MSM8953)
#
# This is the Debian spin of build.sh. It uses the same kernel, lk2nd,
# firmware, and boot image logic, but populates the rootfs with Debian
# Bookworm via debootstrap instead of Arch Linux ARM.
#
# Optionally installs PXVIRT (Proxmox VE for ARM64) when --with-pxvirt is set.
#
# Prerequisites:
#   - An x86_64 Linux host (tested on Arch Linux / Ubuntu 22.04+)
#   - Root or sudo access (for chroot, loop mounts, etc.)
#   - ~10 GB free disk space
#   - debootstrap and qemu-user-static installed
#
# Usage:
#   sudo ./build_debian.sh [OPTIONS]
#
# Options:
#   --skip-deps        Skip installing host dependencies
#   --skip-kernel      Skip kernel compilation (use previously compiled)
#   --skip-rootfs      Skip rootfs creation (use existing root.img)
#   --skip-lk2nd       Skip lk2nd compilation (use pre-built or skip)
#   --with-pxvirt      Install PXVIRT (Proxmox VE for ARM64)
#   --rootfs-size SIZE  Root filesystem size in MB (default: 8192)
#   --kernel-branch BR  Kernel git branch (default: master)
#   --help             Show this help
#
# The output is placed in ./output/ and contains:
#   - boot.img          (kernel + dtb + initramfs for fastboot)
#   - root.img          (ext4 rootfs image for the userdata partition)
#   - lk2nd.img         (secondary bootloader, flash to 'boot' partition)
#   - flash_debian.sh   (convenience script to flash everything)
#
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Configuration
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
OUTPUT_DIR="${SCRIPT_DIR}/output"
ROOTFS_MOUNT="${WORK_DIR}/rootfs_mnt"

# Device specifics
DEVICE_CODENAME="daisy"
SOC="msm8953"
DEVICE_DTB_PATTERNS=("apq8053-*" "msm8953-*" "sdm450-*")

# Kernel
KERNEL_REPO="https://github.com/msm8953-mainline/linux.git"
KERNEL_BRANCH="7.0.9/main"
KERNEL_DIR="${WORK_DIR}/linux"
KERNEL_CONFIG="${SCRIPT_DIR}/configs/msm8953_defconfig"

# lk2nd
LK2ND_REPO="https://github.com/msm8916-mainline/lk2nd.git"
LK2ND_DIR="${WORK_DIR}/lk2nd"

# Firmware
FW_DAISY_COMMIT="9ae200b57743088f83a6f2b02a6b7ce4596a77d6"
FW_DAISY_URL="https://github.com/alikates/firmware-xiaomi-daisy/archive/${FW_DAISY_COMMIT}.tar.gz"
FW_DAISY_DIR="${WORK_DIR}/firmware-xiaomi-daisy-${FW_DAISY_COMMIT}"

# Debian rootfs
ROOTFS_IMG="${WORK_DIR}/root.img"
ROOTFS_SIZE_MB=8192

# Cross-compilation
CROSS_COMPILE="aarch64-linux-gnu-"
ARCH="arm64"

# Boot image parameters (MSM8953 / lk2nd compatible)
BOOT_BASE="0x80000000"
BOOT_KERNEL_OFFSET="0x00008000"
BOOT_RAMDISK_OFFSET="0x01000000"
BOOT_TAGS_OFFSET="0x00000100"
BOOT_PAGESIZE="2048"
BOOT_CMDLINE="console=tty0 root=PARTLABEL=userdata rootwait rw loglevel=3 splash"

# Defaults
SKIP_DEPS=false
SKIP_KERNEL=false
SKIP_ROOTFS=false
SKIP_LK2ND=false
WITH_PXVIRT=false

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-deps)    SKIP_DEPS=true;    shift ;;
        --skip-kernel)  SKIP_KERNEL=true;  shift ;;
        --skip-rootfs)  SKIP_ROOTFS=true;  shift ;;
        --skip-lk2nd)   SKIP_LK2ND=true;  shift ;;
        --with-pxvirt)  WITH_PXVIRT=true;  shift ;;
        --rootfs-size)  ROOTFS_SIZE_MB="$2"; shift 2 ;;
        --kernel-branch) KERNEL_BRANCH="$2"; shift 2 ;;
        --help)
            head -n 39 "$0" | tail -n +2 | sed 's/^#//' | sed 's/^ //'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

###############################################################################
# Helpers
###############################################################################
log() {
    echo -e "\n\033[1;32m>>> $*\033[0m"
}

warn() {
    echo -e "\033[1;33mWARN: $*\033[0m"
}

die() {
    echo -e "\033[1;31mERROR: $*\033[0m" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (or via sudo)."
    fi
}

cleanup_mounts() {
    log "Cleaning up mounts..."
    for mp in "${ROOTFS_MOUNT}/dev/pts" "${ROOTFS_MOUNT}/dev" \
              "${ROOTFS_MOUNT}/proc" "${ROOTFS_MOUNT}/sys" \
              "${ROOTFS_MOUNT}/run" "${ROOTFS_MOUNT}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -l "$mp" 2>/dev/null || true
        fi
    done
    if [[ -n "${LOOP_DEV:-}" ]] && [[ -b "${LOOP_DEV}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}

trap cleanup_mounts EXIT

###############################################################################
# Step 1: Install host dependencies
###############################################################################
install_deps() {
    log "Installing host build dependencies..."

    if command -v pacman &>/dev/null; then
        # Arch Linux host
        pacman -S --needed --noconfirm \
            base-devel aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
            arm-none-eabi-gcc arm-none-eabi-binutils \
            qemu-user-static qemu-user-static-binfmt \
            dtc python bc flex bison openssl libelf \
            wget curl git rsync cpio gzip xz \
            dosfstools e2fsprogs util-linux \
            android-tools \
            libarchive \
            debootstrap

    elif command -v apt-get &>/dev/null; then
        # Debian / Ubuntu host
        apt-get update
        apt-get install -y \
            build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
            gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
            binfmt-support qemu-user-static \
            device-tree-compiler python3 bc flex bison \
            libssl-dev libelf-dev libncurses-dev \
            wget curl git rsync cpio gzip xz-utils \
            dosfstools e2fsprogs mount \
            libarchive-tools \
            debootstrap

        # Package names for Android tools changed between Ubuntu 22.04 and 24.04
        apt-get install -y mkbootimg || apt-get install -y android-tools-mkbootimg
        apt-get install -y android-sdk-libsparse-utils || apt-get install -y android-tools-fsutils


    elif command -v dnf &>/dev/null; then
        # Fedora host
        dnf install -y \
            @development-tools gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
            arm-none-eabi-gcc arm-none-eabi-binutils \
            qemu-user-static \
            dtc python3 bc flex bison \
            openssl-devel elfutils-libelf-devel ncurses-devel \
            wget curl git rsync cpio gzip xz \
            dosfstools e2fsprogs util-linux \
            android-tools bsdtar \
            debootstrap

    else
        die "Unsupported host distribution. Install dependencies manually."
    fi
}

###############################################################################
# Step 2: Clone / update kernel source
###############################################################################
prepare_kernel() {
    log "Preparing mainline kernel source (msm8953-mainline)..."

    if [[ -d "${KERNEL_DIR}/.git" ]]; then
        log "Kernel source exists, updating..."
        git -C "${KERNEL_DIR}" fetch --depth=1 origin "${KERNEL_BRANCH}"
        git -C "${KERNEL_DIR}" checkout FETCH_HEAD
    else
        log "Cloning kernel from ${KERNEL_REPO} (branch: ${KERNEL_BRANCH})..."
        git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"
    fi

    # Apply kernel config
    if [[ ! -f "${KERNEL_CONFIG}" ]]; then
        log "Downloading postmarketOS msm8953 config..."
        wget -qO "${KERNEL_CONFIG}" "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/device/community/linux-postmarketos-qcom-msm8953/config-postmarketos-qcom-msm8953.aarch64?ref_type=heads"
    fi

    log "Using kernel config from ${KERNEL_CONFIG}"
    cp "${KERNEL_CONFIG}" "${KERNEL_DIR}/.config"

    # Force display and touch drivers to be built-in
    local configs=(
        "CONFIG_DRM_MSM"
        "CONFIG_DRM_PANEL_HIMAX_HX8399C_FHDPLUS"
        "CONFIG_DRM_PANEL_MDSS_ILI7807_FHDPLUS"
        "CONFIG_DRM_PANEL_MDSS_OTM1911_FHDPLUS"
        "CONFIG_TOUCHSCREEN_EDT_FT5X06"
        "CONFIG_TOUCHSCREEN_GOODIX"
    )
    for conf in "${configs[@]}"; do
        sed -i "s/^${conf}=m/${conf}=y/" "${KERNEL_DIR}/.config"
    done

    # Force Qualcomm Wi-Fi driver to be built as a module
    local configs_m=(
        "CONFIG_ATH10K"
        "CONFIG_ATH10K_SNOC"
    )
    for conf in "${configs_m[@]}"; do
        if grep -q "^# ${conf} is not set" "${KERNEL_DIR}/.config"; then
            sed -i "s/^# ${conf} is not set/${conf}=m/" "${KERNEL_DIR}/.config"
        elif grep -q "^${conf}=" "${KERNEL_DIR}/.config"; then
            sed -i "s/^${conf}=.*/${conf}=m/" "${KERNEL_DIR}/.config"
        else
            echo "${conf}=m" >> "${KERNEL_DIR}/.config"
        fi
    done

    # Ensure virtualization/container configs for PXVIRT
    "${SCRIPT_DIR}/scripts/ensure_kernel_config.sh" "${KERNEL_DIR}/.config"

    log "Configuring kernel..."
    make -C "${KERNEL_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
}

###############################################################################
# Step 3: Compile the kernel
###############################################################################
compile_kernel() {
    log "Compiling kernel (this may take a while)..."
    local nproc
    nproc="$(nproc)"

    make -C "${KERNEL_DIR}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        -j"${nproc}" \
        Image.gz dtbs modules

    log "Kernel compilation complete."
    log "  Image: ${KERNEL_DIR}/arch/arm64/boot/Image.gz"

    # Concatenate matching DTBs
    log "Concatenating DTBs for: ${DEVICE_DTB_PATTERNS[*]}"
    local dtb_path="${KERNEL_DIR}/arch/arm64/boot/dts/qcom/all-dtbs.img"
    rm -f "${dtb_path}"
    local dtb_count=0
    for pattern in "${DEVICE_DTB_PATTERNS[@]}"; do
        for dtb in "${KERNEL_DIR}/arch/arm64/boot/dts/qcom/"${pattern}.dtb; do
            [[ -f "${dtb}" ]] || continue
            cat "${dtb}" >> "${dtb_path}"
            dtb_count=$((dtb_count + 1))
        done
    done

    if [[ ! -s "${dtb_path}" ]] || [[ ${dtb_count} -eq 0 ]]; then
        die "No DTBs found matching patterns: ${DEVICE_DTB_PATTERNS[*]}"
    fi

    log "  DTB: ${dtb_path} (${dtb_count} DTBs from apq8053/msm8953/sdm450 families)"

    KERNEL_IMAGE="${KERNEL_DIR}/arch/arm64/boot/Image.gz"
    KERNEL_DTB="${dtb_path}"
}

###############################################################################
# Step 4: Build lk2nd secondary bootloader
###############################################################################
build_lk2nd() {
    log "Building lk2nd secondary bootloader..."

    if [[ -d "${LK2ND_DIR}/.git" ]]; then
        log "lk2nd source exists, updating..."
        git -C "${LK2ND_DIR}" pull --depth=1 || true
    else
        log "Cloning lk2nd..."
        git clone --depth=1 "${LK2ND_REPO}" "${LK2ND_DIR}"
    fi

    make -C "${LK2ND_DIR}" \
        TOOLCHAIN_PREFIX=arm-none-eabi- \
        lk2nd-msm8953 -j"$(nproc)"

    LK2ND_IMAGE="${LK2ND_DIR}/build-lk2nd-msm8953/lk2nd.img"

    if [[ ! -f "${LK2ND_IMAGE}" ]]; then
        warn "lk2nd.img not found at expected path, searching..."
        LK2ND_IMAGE="$(find "${LK2ND_DIR}" -name "lk2nd.img" -type f | head -1)"
    fi

    if [[ -z "${LK2ND_IMAGE:-}" ]] || [[ ! -f "${LK2ND_IMAGE}" ]]; then
        warn "lk2nd build may have failed. You'll need to provide lk2nd.img manually."
        LK2ND_IMAGE=""
    else
        log "  lk2nd: ${LK2ND_IMAGE}"
    fi
}

###############################################################################
# Step 5: Fetch firmware blobs
###############################################################################
fetch_firmware() {
    log "Fetching xiaomi-daisy firmware blobs (postmarketOS)..."

    if [[ -d "${FW_DAISY_DIR}" ]]; then
        log "Firmware already downloaded: ${FW_DAISY_DIR}"
        return 0
    fi

    local tarball="${WORK_DIR}/firmware-xiaomi-daisy-${FW_DAISY_COMMIT}.tar.gz"
    if [[ ! -f "${tarball}" ]]; then
        log "Downloading firmware-xiaomi-daisy (commit ${FW_DAISY_COMMIT:0:12})..."
        wget -q --show-progress -O "${tarball}" "${FW_DAISY_URL}"
    fi

    log "Extracting firmware..."
    tar -xzf "${tarball}" -C "${WORK_DIR}"

    if [[ ! -d "${FW_DAISY_DIR}" ]]; then
        die "Firmware extraction failed — expected directory ${FW_DAISY_DIR}"
    fi

    log "Firmware ready: ${FW_DAISY_DIR}"
}

###############################################################################
# Step 6: Create Debian Bookworm rootfs
###############################################################################
create_rootfs() {
    log "Creating Debian Bookworm ARM64 rootfs (${ROOTFS_SIZE_MB} MB)..."

    # Create ext4 image
    log "Creating ext4 image: ${ROOTFS_IMG}"
    dd if=/dev/zero of="${ROOTFS_IMG}" bs=1M count="${ROOTFS_SIZE_MB}" status=progress
    mkfs.ext4 -F -L "debian" "${ROOTFS_IMG}"

    # Mount it
    mkdir -p "${ROOTFS_MOUNT}"
    LOOP_DEV="$(losetup --find --show "${ROOTFS_IMG}")"
    mount "${LOOP_DEV}" "${ROOTFS_MOUNT}"

    # Bootstrap Debian Bookworm
    log "Running debootstrap (Debian Bookworm arm64)..."
    debootstrap --arch=arm64 --foreign bookworm "${ROOTFS_MOUNT}" http://deb.debian.org/debian

    # Copy qemu for second stage on x86_64 host
    if [[ "$(uname -m)" == "x86_64" ]]; then
        cp /usr/bin/qemu-aarch64-static "${ROOTFS_MOUNT}/usr/bin/" 2>/dev/null || \
        cp /usr/bin/qemu-aarch64 "${ROOTFS_MOUNT}/usr/bin/qemu-aarch64-static" 2>/dev/null || \
        warn "qemu-aarch64-static not found; debootstrap second stage may fail"
    fi

    # Run debootstrap second stage inside chroot
    log "Running debootstrap second stage..."
    chroot "${ROOTFS_MOUNT}" /debootstrap/debootstrap --second-stage

    # Install kernel modules
    log "Installing kernel modules into rootfs..."
    make -C "${KERNEL_DIR}" \
        ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        INSTALL_MOD_PATH="${ROOTFS_MOUNT}" \
        modules_install

    # Install firmware blobs (identical to Arch version)
    log "Installing xiaomi-daisy firmware blobs..."
    local fw_base="${ROOTFS_MOUNT}/lib/firmware"
    local fw_qcom="${fw_base}/qcom/msm8953/xiaomi/daisy"
    mkdir -p "${fw_base}" "${fw_qcom}"

    # GPU: Adreno 506 zap shader
    if [[ -d "${FW_DAISY_DIR}/gpu" ]]; then
        install -Dm644 "${FW_DAISY_DIR}/gpu/a506_zap.b02" "${fw_qcom}/a506_zap.b02"
        install -Dm644 "${FW_DAISY_DIR}/gpu/a506_zap.mdt" "${fw_qcom}/a506_zap.mdt"
        log "  Installed GPU zap shader → ${fw_qcom}/"
    else
        warn "GPU firmware not found in ${FW_DAISY_DIR}/gpu"
    fi

    # WCNSS: remoteproc firmware
    if [[ -d "${FW_DAISY_DIR}/wcnss" ]]; then
        for blob in "${FW_DAISY_DIR}/wcnss"/wcnss.{mdt,b*}; do
            [[ -f "${blob}" ]] || continue
            install -Dm644 "${blob}" "${fw_base}/$(basename "${blob}")"
        done
        log "  Installed WCNSS remoteproc firmware → ${fw_base}/"

        if [[ -f "${FW_DAISY_DIR}/wcnss/WCNSS_qcom_wlan_nv.bin" ]]; then
            mkdir -p "${fw_base}/wlan/prima"
            install -Dm644 "${FW_DAISY_DIR}/wcnss/WCNSS_qcom_wlan_nv.bin" \
                "${fw_base}/wlan/prima/WCNSS_qcom_wlan_nv.bin"
            log "  Installed WiFi NV calibration → ${fw_base}/wlan/prima/"
        fi
    else
        warn "WCNSS firmware not found in ${FW_DAISY_DIR}/wcnss"
    fi

    # ADSP
    if [[ -d "${FW_DAISY_DIR}/adsp" ]]; then
        for blob in "${FW_DAISY_DIR}/adsp"/adsp.{mdt,b*}; do
            [[ -f "${blob}" ]] || continue
            install -Dm644 "${blob}" "${fw_base}/$(basename "${blob}")"
        done
        log "  Installed ADSP remoteproc firmware → ${fw_base}/"
    fi

    # Modem
    if [[ -d "${FW_DAISY_DIR}/modem" ]]; then
        for blob in "${FW_DAISY_DIR}/modem"/*.{mdt,mbn,b*}; do
            [[ -f "${blob}" ]] || continue
            install -Dm644 "${blob}" "${fw_base}/$(basename "${blob}")"
        done
        log "  Installed modem remoteproc firmware → ${fw_base}/"
    fi

    # Host linux-firmware fallback
    if [[ -d "/usr/lib/firmware/qcom" ]]; then
        mkdir -p "${fw_base}/qcom"
        cp -rn /usr/lib/firmware/qcom/* "${fw_base}/qcom/" 2>/dev/null || true
    fi

    # Copy device-specific configurations
    log "Applying device-specific configurations..."
    WITH_PXVIRT="${WITH_PXVIRT}" \
        "${SCRIPT_DIR}/scripts/configure_rootfs_debian.sh" "${ROOTFS_MOUNT}"

    # Run chroot setup
    log "Running chroot configuration..."
    mount --bind /proc "${ROOTFS_MOUNT}/proc"
    mount --bind /dev "${ROOTFS_MOUNT}/dev"
    mount --bind /dev/pts "${ROOTFS_MOUNT}/dev/pts"
    mount --bind /sys "${ROOTFS_MOUNT}/sys"
    mount --bind /run "${ROOTFS_MOUNT}/run"

    # Set up DNS for chroot
    local resolv_backup=""
    if [[ -f "${ROOTFS_MOUNT}/etc/resolv.conf" ]]; then
        resolv_backup="$(cat "${ROOTFS_MOUNT}/etc/resolv.conf")"
    fi
    echo "nameserver 8.8.8.8" > "${ROOTFS_MOUNT}/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "${ROOTFS_MOUNT}/etc/resolv.conf"
    if [[ -f /etc/resolv.conf ]]; then
        grep -v '^#' /etc/resolv.conf | grep 'nameserver' >> "${ROOTFS_MOUNT}/etc/resolv.conf" || true
    fi

    # Run chroot setup script
    cp "${SCRIPT_DIR}/scripts/chroot_setup_debian.sh" "${ROOTFS_MOUNT}/tmp/"
    chroot "${ROOTFS_MOUNT}" /bin/bash /tmp/chroot_setup_debian.sh "${WITH_PXVIRT}"
    rm -f "${ROOTFS_MOUNT}/tmp/chroot_setup_debian.sh"

    # Restore resolv.conf
    rm -f "${ROOTFS_MOUNT}/etc/resolv.conf"
    if [[ -n "${resolv_backup}" ]]; then
        echo "${resolv_backup}" > "${ROOTFS_MOUNT}/etc/resolv.conf"
    else
        ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOTFS_MOUNT}/etc/resolv.conf"
    fi

    # Cleanup qemu binary
    rm -f "${ROOTFS_MOUNT}/usr/bin/qemu-aarch64-static"

    # Unmount
    cleanup_mounts

    log "Debian rootfs created: ${ROOTFS_IMG}"
}

###############################################################################
# Step 7: Generate initramfs
###############################################################################
generate_initramfs() {
    log "Generating minimal initramfs..."

    local initramfs_dir="${WORK_DIR}/initramfs"
    local initramfs_img="${WORK_DIR}/initramfs.cpio.gz"

    rm -rf "${initramfs_dir}"
    mkdir -p "${initramfs_dir}"/{bin,dev,etc,lib,lib64,mnt,proc,root,sbin,sys,tmp,run}

    log "Skipping custom init script generation to use native kernel mounting."

    # Pack initramfs
    (cd "${initramfs_dir}" && find . | cpio -o -H newc 2>/dev/null | gzip > "${initramfs_img}")

    log "Initramfs created: ${initramfs_img}"
    INITRAMFS_IMG="${initramfs_img}"
}

###############################################################################
# Step 8: Create boot.img
###############################################################################
create_boot_img() {
    log "Creating boot.img..."

    local kernel_dtb_concat="${WORK_DIR}/kernel-dtb"
    cat "${KERNEL_IMAGE}" "${KERNEL_DTB}" > "${kernel_dtb_concat}"

    if command -v mkbootimg &>/dev/null; then
        mkbootimg \
            --base "${BOOT_BASE}" \
            --kernel_offset "${BOOT_KERNEL_OFFSET}" \
            --ramdisk_offset "${BOOT_RAMDISK_OFFSET}" \
            --tags_offset "${BOOT_TAGS_OFFSET}" \
            --pagesize "${BOOT_PAGESIZE}" \
            --kernel "${kernel_dtb_concat}" \
            --ramdisk "${INITRAMFS_IMG}" \
            --cmdline "${BOOT_CMDLINE}" \
            --output "${OUTPUT_DIR}/boot.img"
    elif [[ -f "/usr/bin/android-tools-mkbootimg" ]]; then
        /usr/bin/android-tools-mkbootimg \
            --base "${BOOT_BASE}" \
            --kernel_offset "${BOOT_KERNEL_OFFSET}" \
            --ramdisk_offset "${BOOT_RAMDISK_OFFSET}" \
            --tags_offset "${BOOT_TAGS_OFFSET}" \
            --pagesize "${BOOT_PAGESIZE}" \
            --kernel "${kernel_dtb_concat}" \
            --ramdisk "${INITRAMFS_IMG}" \
            --cmdline "${BOOT_CMDLINE}" \
            --output "${OUTPUT_DIR}/boot.img"
    else
        die "mkbootimg not found. Install android-tools or mkbootimg."
    fi

    log "boot.img created: ${OUTPUT_DIR}/boot.img"
}

###############################################################################
# Step 9: Package everything
###############################################################################
package_output() {
    log "Packaging output..."

    # Copy rootfs image
    cp "${ROOTFS_IMG}" "${OUTPUT_DIR}/root.img"

    # Copy lk2nd if available
    if [[ -n "${LK2ND_IMAGE:-}" ]] && [[ -f "${LK2ND_IMAGE}" ]]; then
        cp "${LK2ND_IMAGE}" "${OUTPUT_DIR}/lk2nd.img"
    fi

    # Create flash script
    cat > "${OUTPUT_DIR}/flash_debian.sh" << 'FLASH_EOF'
#!/usr/bin/env bash
#
# flash_debian.sh — Flash Debian Bookworm ARM64 to Xiaomi Mi A2 Lite (daisy)
#
# Prerequisites:
#   1. Unlock bootloader (via Xiaomi's official tool)
#   2. Install fastboot (android-tools)
#   3. Phone in fastboot mode (Vol Down + Power while connecting USB)
#
# IMPORTANT: This will ERASE your userdata partition!
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo " Debian Bookworm ARM64 Flasher"
echo " Xiaomi Mi A2 Lite (daisy)"
echo "=============================================="
echo ""

# Check fastboot
if ! command -v fastboot &>/dev/null; then
    echo "ERROR: fastboot not found. Install android-tools."
    exit 1
fi

# Check for device
echo "Waiting for device in fastboot mode..."
fastboot devices | grep -q . || {
    echo "ERROR: No device found in fastboot mode."
    echo "  1. Power off the phone"
    echo "  2. Hold Volume Down + Power"
    echo "  3. Connect USB cable"
    exit 1
}

echo "Device found!"
echo ""

# Step 1: Flash lk2nd (if available and not already flashed)
if [[ -f "${SCRIPT_DIR}/lk2nd.img" ]]; then
    echo "==> Step 1: Flashing lk2nd to boot partition..."
    echo "    lk2nd is a secondary bootloader that provides standard"
    echo "    fastboot for booting mainline kernels."
    echo ""
    read -rp "Flash lk2nd? (y/N): " answer
    if [[ "${answer,,}" == "y" ]]; then
        fastboot flash boot "${SCRIPT_DIR}/lk2nd.img"
        echo ""
        echo "    lk2nd flashed. The phone will now reboot into lk2nd."
        echo "    lk2nd provides its own fastboot interface."
        echo ""
        echo "    Please wait for lk2nd fastboot screen, then press Enter."
        fastboot reboot
        read -rp "Press Enter when phone shows lk2nd fastboot screen..."
        sleep 2
    fi
else
    echo "==> Step 1: lk2nd.img not found, skipping."
    echo "    Make sure lk2nd is already flashed to boot partition!"
    echo ""
fi

# Step 2: Flash boot.img (kernel)
echo "==> Step 2: Flashing boot.img (kernel + initramfs)..."
if [[ -f "${SCRIPT_DIR}/boot.img" ]]; then
    read -rp "Flash boot.img? (Y/n): " answer
    if [[ "${answer,,}" != "n" ]]; then
        fastboot flash boot "${SCRIPT_DIR}/boot.img"
        echo "    Kernel flashed."
    else
        echo "    Skipping boot.img flash."
    fi
else
    echo "ERROR: boot.img not found!"
    exit 1
fi
echo ""

# Step 3: Flash rootfs to userdata
echo "==> Step 3: Flashing root.img to userdata partition..."
echo "    WARNING: This will ERASE all data on the phone!"
read -rp "Continue? (y/N): " answer
if [[ "${answer,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
fi

if [[ -f "${SCRIPT_DIR}/root.img" ]]; then
    fastboot flash userdata "${SCRIPT_DIR}/root.img"
    echo "    Rootfs flashed."
else
    echo "ERROR: root.img not found!"
    exit 1
fi

echo ""
echo "==> Step 4: Rebooting..."
fastboot reboot

echo ""
echo "=============================================="
echo " Flashing complete!"
echo ""
echo " Default credentials:"
echo "   Root: root"
echo ""
echo " SSH is enabled by default."
echo " Connect via USB networking: ssh root@172.16.42.1"
echo ""
echo " If PXVIRT is installed:"
echo "   Web UI: https://<phone-ip>:8006"
echo "   Login:  root / root (Linux PAM)"
echo "=============================================="
FLASH_EOF
    chmod +x "${OUTPUT_DIR}/flash_debian.sh"

    log "Output packaged in: ${OUTPUT_DIR}/"
    ls -lh "${OUTPUT_DIR}/"
}

###############################################################################
# Main
###############################################################################
main() {
    check_root

    log "======================================================="
    log " Debian Bookworm ARM64 Image Builder"
    log " Device: Xiaomi Mi A2 Lite (${DEVICE_CODENAME} / ${SOC})"
    if [[ "${WITH_PXVIRT}" == "true" ]]; then
        log " PXVIRT: ENABLED"
    fi
    log "======================================================="

    mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}" "${SCRIPT_DIR}/configs"

    # Step 1: Dependencies
    if [[ "${SKIP_DEPS}" == false ]]; then
        install_deps
    else
        log "Skipping dependency installation."
    fi

    # Step 2-3: Kernel
    if [[ "${SKIP_KERNEL}" == false ]]; then
        prepare_kernel
        compile_kernel
    else
        log "Skipping kernel compilation."
        KERNEL_IMAGE="${KERNEL_DIR}/arch/arm64/boot/Image.gz"

        rm -f "${KERNEL_DIR}/arch/arm64/boot/dts/qcom/all-dtbs.img"
        for pattern in "${DEVICE_DTB_PATTERNS[@]}"; do
            for dtb in "${KERNEL_DIR}/arch/arm64/boot/dts/qcom/"${pattern}.dtb; do
                [[ -f "${dtb}" ]] && cat "${dtb}" >> "${KERNEL_DIR}/arch/arm64/boot/dts/qcom/all-dtbs.img"
            done
        done
        KERNEL_DTB="${KERNEL_DIR}/arch/arm64/boot/dts/qcom/all-dtbs.img"

        if [[ ! -s "${KERNEL_DTB}" ]]; then
            die "No DTBs found. Run without --skip-kernel first."
        fi
    fi

    # Step 4: lk2nd
    if [[ "${SKIP_LK2ND}" == false ]]; then
        build_lk2nd
    else
        log "Skipping lk2nd build."
        LK2ND_IMAGE=""
    fi

    # Step 5: Firmware
    fetch_firmware

    # Step 6: Rootfs
    if [[ "${SKIP_ROOTFS}" == false ]]; then
        create_rootfs
    else
        log "Skipping rootfs creation."
    fi

    # Step 7: Initramfs
    generate_initramfs

    # Step 8: Boot image
    create_boot_img

    # Step 9: Package
    package_output

    log "======================================================="
    log " BUILD COMPLETE!"
    log ""
    log " Output files:"
    log "   ${OUTPUT_DIR}/boot.img     - Kernel boot image"
    log "   ${OUTPUT_DIR}/root.img     - Debian Bookworm rootfs"
    [[ -n "${LK2ND_IMAGE:-}" ]] && \
    log "   ${OUTPUT_DIR}/lk2nd.img    - Secondary bootloader"
    log "   ${OUTPUT_DIR}/flash_debian.sh - Flash script"
    log ""
    log " To flash:"
    log "   cd ${OUTPUT_DIR} && sudo ./flash_debian.sh"
    if [[ "${WITH_PXVIRT}" == "true" ]]; then
        log ""
        log " PXVIRT Web UI: https://<phone-ip>:8006"
        log " Login: root / root (Linux PAM)"
    fi
    log "======================================================="
}

main "$@"
