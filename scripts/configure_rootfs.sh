#!/usr/bin/env bash
#
# configure_rootfs.sh — Apply Xiaomi Mi A2 Lite specific configurations
# to the Arch Linux ARM rootfs.
#
# Usage: ./configure_rootfs.sh /path/to/rootfs_mount
#
set -euo pipefail

ROOTFS="${1}"

# Source user network config (fallback to sane defaults)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_CONFIG="${SCRIPT_DIR}/../network.config"
if [[ -f "${NETWORK_CONFIG}" ]]; then
    echo "Loading network config from ${NETWORK_CONFIG}..."
    source "${NETWORK_CONFIG}"
else
    echo "WARNING: network.config not found, using defaults."
    echo "         Copy example-network.config to network.config and edit it."
fi

# Apply defaults for any unset variables
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
WLAN_ADDRESS="${WLAN_ADDRESS:-192.168.1.100/24}"
WLAN_GATEWAY="${WLAN_GATEWAY:-192.168.1.1}"
WLAN_DNS="${WLAN_DNS:-8.8.8.8 8.8.4.4}"
USB_ADDRESS="${USB_ADDRESS:-172.16.42.1/24}"
USB_DHCP_POOL_OFFSET="${USB_DHCP_POOL_OFFSET:-100}"
USB_DHCP_POOL_SIZE="${USB_DHCP_POOL_SIZE:-50}"
USB_DNS="${USB_DNS:-8.8.8.8 8.8.4.4}"
TIMEZONE="${TIMEZONE:-UTC}"

# Derive bare IPs
WLAN_IP="${WLAN_ADDRESS%%/*}"
USB_IP="${USB_ADDRESS%%/*}"

if [[ ! -d "${ROOTFS}" ]]; then
    echo "ERROR: Rootfs path does not exist: ${ROOTFS}"
    exit 1
fi

echo "Configuring rootfs at ${ROOTFS}..."

###############################################################################
# fstab
###############################################################################
cat > "${ROOTFS}/etc/fstab" << 'EOF'
# /etc/fstab - Xiaomi Mi A2 Lite (daisy) - Arch Linux ARM
#
# <device>              <mount>     <type>  <options>           <dump> <pass>
/dev/mmcblk0p54         /           ext4    rw,relatime         0      1
tmpfs                   /tmp        tmpfs   defaults,nosuid     0      0
EOF

###############################################################################
# Hostname
###############################################################################
echo "daisy-archlinux" > "${ROOTFS}/etc/hostname"

cat > "${ROOTFS}/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   daisy-archlinux
::1         localhost
EOF

###############################################################################
# Network configuration — USB RNDIS gadget for initial setup
###############################################################################
mkdir -p "${ROOTFS}/etc/systemd/network"

# USB RNDIS network (shows up as usb0 on the phone)
cat > "${ROOTFS}/etc/systemd/network/10-usb0.network" << EOF
[Match]
Name=usb0

[Network]
Address=${USB_ADDRESS}
DHCPServer=yes

[DHCPServer]
PoolOffset=${USB_DHCP_POOL_OFFSET}
PoolSize=${USB_DHCP_POOL_SIZE}
EmitDNS=yes
DNS=${USB_DNS}
EOF

# WiFi (wlan0) — Static IP
cat > "${ROOTFS}/etc/systemd/network/20-wlan0.network" << EOF
[Match]
Name=wlan0

[Network]
Address=${WLAN_ADDRESS}
Gateway=${WLAN_GATEWAY}
DNS=${WLAN_DNS}
EOF

# Ethernet via USB tethering
cat > "${ROOTFS}/etc/systemd/network/30-eth0.network" << 'EOF'
[Match]
Name=eth*

[Network]
DHCP=yes
EOF

###############################################################################
# USB gadget setup service
###############################################################################
mkdir -p "${ROOTFS}/usr/local/bin"

cat > "${ROOTFS}/usr/local/bin/usb-gadget-setup.sh" << GADGET_EOF
#!/bin/bash
#
# Configure USB gadget for RNDIS networking (USB tethering to host PC)
#
set -e

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Wait for configfs
sleep 2

if [ ! -d /sys/kernel/config/usb_gadget ]; then
    modprobe libcomposite 2>/dev/null || true
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

if [ -d "\${GADGET_DIR}" ]; then
    echo "USB gadget already configured"
    exit 0
fi

mkdir -p "\${GADGET_DIR}"
cd "\${GADGET_DIR}"

echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "fedcba9876543210"   > strings/0x409/serialnumber
echo "Arch Linux ARM"     > strings/0x409/manufacturer
echo "Mi A2 Lite (daisy)" > strings/0x409/product

# RNDIS function
mkdir -p functions/rndis.usb0
echo "02:00:00:00:00:01" > functions/rndis.usb0/host_addr
echo "02:00:00:00:00:02" > functions/rndis.usb0/dev_addr

# Configuration
mkdir -p configs/c.1/strings/0x409
echo "RNDIS" > configs/c.1/strings/0x409/configuration
echo 250     > configs/c.1/MaxPower

ln -sf functions/rndis.usb0 configs/c.1/

# Find UDC and bind (wait up to 15 seconds for UDC driver to register)
for i in {1..15}; do
    UDC=\$(ls /sys/class/udc/ | head -1)
    if [ -n "\${UDC}" ]; then
        break
    fi
    echo "Waiting for UDC driver to register (attempt \$i/15)..."
    sleep 1
done

if [ -n "\${UDC}" ]; then
    echo "\${UDC}" > UDC
    echo "USB gadget configured with UDC: \${UDC}"

    # Wait briefly for usb0 to appear, then assign static IP
    sleep 1
    ip link set usb0 up 2>/dev/null || true
    ip addr add ${USB_ADDRESS} dev usb0 2>/dev/null || true
    echo "USB gadget network: usb0 = ${USB_ADDRESS}"
else
    echo "ERROR: No UDC found after 15 seconds"
    exit 1
fi
GADGET_EOF
chmod +x "${ROOTFS}/usr/local/bin/usb-gadget-setup.sh"

cat > "${ROOTFS}/etc/systemd/system/usb-gadget.service" << 'EOF'
[Unit]
Description=USB Gadget RNDIS Network Setup
After=sys-kernel-config.mount systemd-modules-load.service
Wants=sys-kernel-config.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gadget-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/usb-gadget.service "${ROOTFS}/etc/systemd/system/multi-user.target.wants/usb-gadget.service"

###############################################################################
# Serial console (for debug via UART)
###############################################################################
mkdir -p "${ROOTFS}/etc/systemd/system/serial-getty@ttyMSM0.service.d"
cat > "${ROOTFS}/etc/systemd/system/serial-getty@ttyMSM0.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 %I $TERM
EOF

###############################################################################
# GPU / DRM permissions
###############################################################################
cat > "${ROOTFS}/etc/udev/rules.d/99-gpu.rules" << 'EOF'
# Adreno 506 GPU permissions
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF



###############################################################################
# Kernel module loading
###############################################################################
cat > "${ROOTFS}/etc/modules-load.d/msm8953.conf" << 'EOF'
# MSM8953 WiFi
wcnss_ctrl
qcom_wcnss_pil
wcn36xx
# USB gadget
libcomposite
EOF

###############################################################################
# WiFi firmware path
###############################################################################
mkdir -p "${ROOTFS}/lib/firmware/ath10k/WCN3990/hw1.0"

# Workaround for KWin Wayland rendering bugs (GL_INVALID_OPERATION) on freedreno/Adreno 506
echo "KWIN_COMPOSE=O2ES" >> "${ROOTFS}/etc/environment"

###############################################################################
# Locale & timezone defaults
###############################################################################
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"
ln -sf /usr/share/zoneinfo/${TIMEZONE} "${ROOTFS}/etc/localtime" 2>/dev/null || true

###############################################################################
# SSH config (allow root login for initial setup)
###############################################################################
mkdir -p "${ROOTFS}/etc/ssh"
cat >> "${ROOTFS}/etc/ssh/sshd_config" 2>/dev/null << 'EOF' || true

# Allow root login for initial setup (disable after configuring)
PermitRootLogin yes
EOF

###############################################################################
# First boot rootfs resize service
###############################################################################
cat > "${ROOTFS}/usr/local/bin/resize-rootfs.sh" << 'EOF'
#!/bin/bash
set -e

MARKER="/.rootfs-resized"

if [ -f "${MARKER}" ]; then
    echo "Root filesystem already resized, skipping."
    exit 0
fi

ROOT_DEV=$(findmnt -n -o SOURCE /)
echo "Root device: ${ROOT_DEV}"
echo "Resizing filesystem on ${ROOT_DEV}..."
resize2fs "${ROOT_DEV}" || true

touch "${MARKER}"
echo "Root filesystem resize complete."
systemctl disable resize-rootfs.service || true
EOF
chmod +x "${ROOTFS}/usr/local/bin/resize-rootfs.sh"

cat > "${ROOTFS}/etc/systemd/system/resize-rootfs.service" << 'EOF'
[Unit]
Description=Expand Root Filesystem to Fill Partition
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target
ConditionPathExists=!/.rootfs-resized

[Service]
Type=oneshot
ExecStart=/usr/local/bin/resize-rootfs.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
mkdir -p "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/resize-rootfs.service "${ROOTFS}/etc/systemd/system/sysinit.target.wants/resize-rootfs.service"

###############################################################################
# Preloaded Wi-Fi Configuration
###############################################################################
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"

if [[ -n "${WIFI_SSID}" ]]; then
    echo "Pre-configuring Wi-Fi connection for SSID: ${WIFI_SSID}..."

    # 1. NetworkManager Profile
    mkdir -p "${ROOTFS}/etc/NetworkManager/system-connections"
    NM_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "d662c82b-65ff-4cb4-a3ad-bf9e1026046e")
    cat > "${ROOTFS}/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" << EOF
[connection]
id=${WIFI_SSID}
uuid=${NM_UUID}
type=wifi
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=manual
address1=${WLAN_ADDRESS},${WLAN_GATEWAY}
dns=${WLAN_DNS// /;}

[ipv6]
method=auto
EOF
    chmod 600 "${ROOTFS}/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"

    # Configure NetworkManager to use iwd backend to avoid needing wpa_supplicant
    mkdir -p "${ROOTFS}/etc/NetworkManager"
    cat > "${ROOTFS}/etc/NetworkManager/NetworkManager.conf" << EOF
[main]
plugins=keyfile

[device]
wifi.backend=iwd
EOF
    chmod 644 "${ROOTFS}/etc/NetworkManager/NetworkManager.conf"

    # 2. iwd Profile
    mkdir -p "${ROOTFS}/var/lib/iwd"
    cat > "${ROOTFS}/var/lib/iwd/${WIFI_SSID}.psk" << EOF
[Security]
Passphrase=${WIFI_PASS}
EOF
    chmod 600 "${ROOTFS}/var/lib/iwd/${WIFI_SSID}.psk"

    echo "Wi-Fi configurations generated."
fi

echo "Rootfs configuration complete."
