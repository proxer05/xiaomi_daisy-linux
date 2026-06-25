#!/usr/bin/env bash
#
# ensure_kernel_config.sh — Ensure critical kernel config options are set
# for Xiaomi Mi A2 Lite (daisy / MSM8953) running Arch Linux ARM.
#
# Usage: ./ensure_kernel_config.sh /path/to/.config
#
set -euo pipefail

CONFIG_FILE="${1:-.config}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi

echo "Ensuring critical kernel config options in ${CONFIG_FILE}..."

# Helper: set a config option
set_config() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "${CONFIG_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_FILE}"
    elif grep -q "^# ${key} is not set" "${CONFIG_FILE}"; then
        sed -i "s|^# ${key} is not set|${key}=${value}|" "${CONFIG_FILE}"
    else
        echo "${key}=${value}" >> "${CONFIG_FILE}"
    fi
}

###############################################################################
# MSM8953 / Snapdragon 625 SoC support
###############################################################################
set_config "CONFIG_ARCH_QCOM"              "y"
set_config "CONFIG_ARM64"                   "y"

###############################################################################
# Storage (eMMC)
###############################################################################
set_config "CONFIG_MMC"                     "y"
set_config "CONFIG_MMC_SDHCI"               "y"
set_config "CONFIG_MMC_SDHCI_MSM"           "y"
set_config "CONFIG_MMC_SDHCI_PLTFM"         "y"
set_config "CONFIG_MMC_BLOCK"               "y"

###############################################################################
# Display (DRM/KMS)
###############################################################################
set_config "CONFIG_DRM"                     "y"
set_config "CONFIG_DRM_MSM"                 "y"
set_config "CONFIG_DRM_PANEL_SIMPLE"        "y"
set_config "CONFIG_DRM_PANEL_DSI_CMD_MODE"  "y"
set_config "CONFIG_BACKLIGHT_CLASS_DEVICE"   "y"
set_config "CONFIG_FB"                       "y"
set_config "CONFIG_FB_SIMPLE"                "y"
set_config "CONFIG_FRAMEBUFFER_CONSOLE"      "y"

###############################################################################
# Input (touchscreen)
###############################################################################
set_config "CONFIG_INPUT_TOUCHSCREEN"        "y"
set_config "CONFIG_TOUCHSCREEN_EDT_FT5X06"   "y"
set_config "CONFIG_TOUCHSCREEN_GOODIX"       "y"
set_config "CONFIG_TOUCHSCREEN_ATMEL_MXT"    "y"
set_config "CONFIG_TOUCHSCREEN_NOVATEK_NVT_TS" "y"
set_config "CONFIG_TOUCHSCREEN_S6SY761"      "y"

# Synaptics RMI4 touch (rmi-core, rmi-i2c)
set_config "CONFIG_RMI4_CORE"                "y"
set_config "CONFIG_RMI4_I2C"                 "y"
set_config "CONFIG_RMI4_F03"                 "y"
set_config "CONFIG_RMI4_2D_SENSOR"           "y"
set_config "CONFIG_RMI4_F11"                 "y"
set_config "CONFIG_RMI4_F12"                 "y"
set_config "CONFIG_RMI4_F30"                 "y"
set_config "CONFIG_RMI4_F3A"                 "y"

###############################################################################
# MFD & Chargers
###############################################################################
set_config "CONFIG_MFD_SIMPLE_I2C"           "y"
set_config "CONFIG_LEDS_CLASS_FLASH"         "y"
set_config "CONFIG_SM5708_POWER"             "y"
set_config "CONFIG_CHARGER_SM5708"           "y"

###############################################################################
# Display Panels (Force all to built-in instead of module)
###############################################################################
sed -i 's/^CONFIG_DRM_PANEL_\(.*\)=m/CONFIG_DRM_PANEL_\1=y/' "${CONFIG_FILE}"

###############################################################################
# USB (OTG, gadget for USB networking)
###############################################################################
set_config "CONFIG_USB"                      "y"
set_config "CONFIG_USB_DWC3"                 "y"
set_config "CONFIG_USB_DWC3_QCOM"            "y"
set_config "CONFIG_USB_GADGET"               "y"
set_config "CONFIG_USB_CONFIGFS"             "m"
set_config "CONFIG_USB_CONFIGFS_RNDIS"       "y"
set_config "CONFIG_USB_CONFIGFS_ECM"         "y"
set_config "CONFIG_USB_ETH"                  "m"

###############################################################################
# Networking
###############################################################################
set_config "CONFIG_NET"                      "y"
set_config "CONFIG_INET"                     "y"
set_config "CONFIG_WLAN"                     "y"
set_config "CONFIG_WLAN_VENDOR_ATH"          "y"
set_config "CONFIG_ATH10K"                   "m"
set_config "CONFIG_ATH10K_SNOC"              "m"
set_config "CONFIG_ATH10K_QMI"               "y"
set_config "CONFIG_QRTR"                     "y"
set_config "CONFIG_QRTR_SMD"                 "y"

###############################################################################
# Regulators & Power
###############################################################################
set_config "CONFIG_REGULATOR"                "y"
set_config "CONFIG_REGULATOR_QCOM_SPMI"      "y"
set_config "CONFIG_MFD_SPMI_PMIC"            "y"
set_config "CONFIG_SPMI"                     "y"
set_config "CONFIG_PINCTRL_MSM8953"          "y"
set_config "CONFIG_POWER_SUPPLY"             "y"
set_config "CONFIG_BATTERY_BMS"              "y"

###############################################################################
# Clock & Reset
###############################################################################
set_config "CONFIG_COMMON_CLK_QCOM"          "y"
set_config "CONFIG_QCOM_CLK_SMD_RPM"         "y"
set_config "CONFIG_MSM_GCC_8953"             "y"
set_config "CONFIG_QCOM_RPMCC"               "y"

###############################################################################
# Remoteproc (for WiFi, modem co-processors)
###############################################################################
set_config "CONFIG_REMOTEPROC"               "y"
set_config "CONFIG_QCOM_Q6V5_MSS"            "m"
set_config "CONFIG_QCOM_Q6V5_PAS"            "m"
set_config "CONFIG_QCOM_WCNSS_PIL"           "m"
set_config "CONFIG_RPMSG_QCOM_SMD"           "y"
set_config "CONFIG_RPMSG_QCOM_GLINK_SMEM"    "y"

###############################################################################
# Filesystems
###############################################################################
set_config "CONFIG_EXT4_FS"                  "y"
set_config "CONFIG_F2FS_FS"                  "m"
set_config "CONFIG_TMPFS"                    "y"
set_config "CONFIG_DEVTMPFS"                 "y"
set_config "CONFIG_DEVTMPFS_MOUNT"           "y"

###############################################################################
# Serial console (debug)
###############################################################################
set_config "CONFIG_SERIAL_MSM"               "y"
set_config "CONFIG_SERIAL_MSM_CONSOLE"       "y"

###############################################################################
# Misc
###############################################################################
set_config "CONFIG_PRINTK"                   "y"
set_config "CONFIG_BLK_DEV_INITRD"           "y"
set_config "CONFIG_RD_GZIP"                  "y"
set_config "CONFIG_MODULES"                  "y"
set_config "CONFIG_MODULE_UNLOAD"            "y"
set_config "CONFIG_FW_LOADER"                "y"
set_config "CONFIG_FW_LOADER_USER_HELPER"    "y"
set_config "CONFIG_CRYPTO_DEFLATE"           "y"

###############################################################################
# Containers (LXC — namespaces, cgroups)
###############################################################################
set_config "CONFIG_NAMESPACES"                "y"
set_config "CONFIG_UTS_NS"                    "y"
set_config "CONFIG_IPC_NS"                    "y"
set_config "CONFIG_PID_NS"                    "y"
set_config "CONFIG_NET_NS"                    "y"
set_config "CONFIG_USER_NS"                   "y"
set_config "CONFIG_CGROUP_PIDS"               "y"
set_config "CONFIG_CGROUP_FREEZER"            "y"
set_config "CONFIG_CGROUP_DEVICE"             "y"
set_config "CONFIG_CGROUP_CPUACCT"            "y"
set_config "CONFIG_CGROUP_PERF"               "y"
set_config "CONFIG_CGROUP_BPF"                "y"
set_config "CONFIG_MEMCG"                     "y"
set_config "CONFIG_CGROUP_SCHED"              "y"
set_config "CONFIG_CPUSETS"                   "y"
set_config "CONFIG_BLK_CGROUP"                "y"
set_config "CONFIG_CGROUP_NET_PRIO"           "y"
set_config "CONFIG_CGROUP_NET_CLASSID"        "y"
set_config "CONFIG_SECCOMP"                   "y"
set_config "CONFIG_SECCOMP_FILTER"            "y"
set_config "CONFIG_SECURITY_APPARMOR"         "y"
set_config "CONFIG_DEFAULT_SECURITY_APPARMOR" "y"
set_config "CONFIG_VETH"                      "y"
set_config "CONFIG_MACVLAN"                   "y"
set_config "CONFIG_BRIDGE"                    "y"
set_config "CONFIG_BRIDGE_VLAN_FILTERING"     "y"
set_config "CONFIG_BRIDGE_NETFILTER"          "y"
set_config "CONFIG_TUN"                       "y"

###############################################################################
# Filesystems (overlay for containers, FUSE for pmxcfs)
###############################################################################
set_config "CONFIG_OVERLAY_FS"                "y"
set_config "CONFIG_FUSE_FS"                   "y"

echo "Kernel config updated."
