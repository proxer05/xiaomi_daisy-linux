#!/usr/bin/env bash
#
# configure_rootfs_debian.sh — Apply Xiaomi Mi A2 Lite specific configurations
# to a Debian Bookworm arm64 rootfs.
#
# Usage: WITH_PXVIRT=true|false WIFI_SSID=... WIFI_PASS=... ./configure_rootfs_debian.sh /path/to/rootfs
#
set -euo pipefail

ROOTFS="${1}"
WITH_PXVIRT="${WITH_PXVIRT:-false}"

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
VMBR_ADDRESS="${VMBR_ADDRESS:-10.10.10.1/24}"
NETMAP_HOME_RANGE="${NETMAP_HOME_RANGE:-192.168.1.200/26}"
TIMEZONE="${TIMEZONE:-UTC}"

# Derive the bare IP (without CIDR suffix) for /etc/hosts
WLAN_IP="${WLAN_ADDRESS%%/*}"
USB_IP="${USB_ADDRESS%%/*}"
VMBR_IP="${VMBR_ADDRESS%%/*}"
VMBR_SUBNET="${VMBR_ADDRESS##*/}"
VMBR_NETWORK="$(echo ${VMBR_IP} | sed 's/\.[0-9]*$/.0/')/${VMBR_SUBNET}"

if [[ ! -d "${ROOTFS}" ]]; then
    echo "ERROR: Rootfs path does not exist: ${ROOTFS}"
    exit 1
fi

echo "Configuring Debian rootfs at ${ROOTFS}..."

###############################################################################
# fstab
###############################################################################
cat > "${ROOTFS}/etc/fstab" << 'EOF'
# /etc/fstab - Xiaomi Mi A2 Lite (daisy) - Debian Bookworm
#
# <device>              <mount>     <type>  <options>           <dump> <pass>
/dev/mmcblk0p54         /           ext4    rw,relatime         0      1
tmpfs                   /tmp        tmpfs   defaults,nosuid     0      0
EOF

###############################################################################
# Hostname
###############################################################################
if [[ "${WITH_PXVIRT}" == "true" ]]; then
    echo "daisy-pxvirt" > "${ROOTFS}/etc/hostname"
    cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1       localhost
${WLAN_IP}     daisy-pxvirt.local daisy-pxvirt
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
else
    echo "daisy-debian" > "${ROOTFS}/etc/hostname"
    cat > "${ROOTFS}/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   daisy-debian
::1         localhost ip6-localhost ip6-loopback
EOF
fi

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

# Proxmox Container Bridge (vmbr0) — NETMAP networking
# Note: vmbr0 is now managed by ifupdown2 in /etc/network/interfaces,
# NOT by systemd-networkd. This gives containers real IPs on the home
# Wi-Fi network via NETMAP (based on ThomasRives/Proxmox-over-wifi).
if [[ "${WITH_PXVIRT}" == "true" ]]; then

# Write /etc/network/interfaces with NETMAP rules
cat > "${ROOTFS}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet static
    address ${WLAN_ADDRESS}
    gateway ${WLAN_GATEWAY}
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto vmbr0
iface vmbr0 inet static
    address ${VMBR_ADDRESS}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s '${VMBR_NETWORK}' -o wlan0 -j NETMAP --to '${NETMAP_HOME_RANGE}'
    post-up iptables -t nat -A PREROUTING -d '${NETMAP_HOME_RANGE}' -j NETMAP --to '${VMBR_NETWORK}'
    post-up ip route add local '${NETMAP_HOME_RANGE}' dev wlan0
    post-up iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t nat -D POSTROUTING -s '${VMBR_NETWORK}' -o wlan0 -j NETMAP --to '${NETMAP_HOME_RANGE}'
    post-down iptables -t nat -D PREROUTING -d '${NETMAP_HOME_RANGE}' -j NETMAP --to '${VMBR_NETWORK}'
    post-down ip route del local '${NETMAP_HOME_RANGE}' dev wlan0
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF

# Configure dnsmasq to serve DHCP on vmbr0
mkdir -p "${ROOTFS}/etc/dnsmasq.d"
cat > "${ROOTFS}/etc/dnsmasq.d/vmbr0.conf" << EOF
# DHCP for Proxmox containers on vmbr0
interface=vmbr0
except-interface=lo
except-interface=wlan0
bind-interfaces
dhcp-range=10.10.10.100,10.10.10.200,24h
dhcp-option=option:router,${VMBR_IP}
dhcp-option=option:dns-server,${WLAN_DNS// /,}
EOF

# Enable dnsmasq via manual symlink (systemctl enable doesn't work in chroot)
mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/dnsmasq.service "${ROOTFS}/etc/systemd/system/multi-user.target.wants/dnsmasq.service"

cat > "${ROOTFS}/usr/local/bin/pxvirt-firstboot.sh" << 'PVE_EOF'
#!/bin/bash
set -e

# Wait for pve-cluster to be ready
until pvecm status >/dev/null 2>&1; do
    echo "Waiting for pve-cluster (pmxcfs) to be ready..."
    sleep 2
done

echo "pmxcfs is ready. Initializing Proxmox node..."

# Generate default storage.cfg if missing
if [ ! -f /etc/pve/storage.cfg ]; then
    cat > /etc/pve/storage.cfg << 'CFG_EOF'
dir: local
        path /var/lib/vz
        content iso,vztmpl,backup,images,rootdir
        maxfiles 1
CFG_EOF
fi

# Generate SSL certificates
pvecm updatecerts -f || true

# Apply tteck post-install script features (No-Nag & Repo cleanup)
echo "Disabling subscription nag screen..."
sed -i.bak "s/data.status !== 'Active'/false/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true

echo "Removing invalid ARM64 enterprise repositories..."
rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/ceph.list 2>/dev/null || true

# Restart Proxmox proxy to pick up certificates and UI changes
systemctl restart pveproxy || true

echo "PXVIRT initialization complete. Disabling first-boot service."
systemctl disable pxvirt-firstboot.service
PVE_EOF
chmod +x "${ROOTFS}/usr/local/bin/pxvirt-firstboot.sh"

cat > "${ROOTFS}/etc/systemd/system/pxvirt-firstboot.service" << 'PVE_EOF'
[Unit]
Description=PXVIRT First-boot Initialization
After=pve-cluster.service
Requires=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pxvirt-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
PVE_EOF
ln -s /etc/systemd/system/pxvirt-firstboot.service "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pxvirt-firstboot.service"
fi

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
echo "Debian ARM64"       > strings/0x409/manufacturer
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
mkdir -p "${ROOTFS}/etc/udev/rules.d"
cat > "${ROOTFS}/etc/udev/rules.d/99-gpu.rules" << 'EOF'
# Adreno 506 GPU permissions
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF

###############################################################################
# Kernel module loading
###############################################################################
mkdir -p "${ROOTFS}/etc/modules-load.d"
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

###############################################################################
###############################################################################
# Timezone defaults
###############################################################################
ln -sf /usr/share/zoneinfo/${TIMEZONE} "${ROOTFS}/etc/localtime" 2>/dev/null || true

###############################################################################
# SSH config (allow root login for initial setup)
###############################################################################
mkdir -p "${ROOTFS}/etc/ssh"
cat >> "${ROOTFS}/etc/ssh/sshd_config" 2>/dev/null << 'EOF' || true

# Allow root login for initial setup (disable after configuring)
PermitRootLogin yes
EOF

# Prevent client locale variables from breaking the server's locale
sed -i 's/^AcceptEnv LANG LC_*/#AcceptEnv LANG LC_*/g' "${ROOTFS}/etc/ssh/sshd_config" 2>/dev/null || true

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

# Get the root block device
ROOT_DEV=$(findmnt -n -o SOURCE /)
echo "Root device: ${ROOT_DEV}"

# Resize the ext4 filesystem to fill the partition
echo "Resizing filesystem on ${ROOT_DEV}..."
resize2fs "${ROOT_DEV}" || true

# Mark as done
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

    if [[ "${WITH_PXVIRT}" == "true" ]]; then
        # PXVIRT uses ifupdown2 — write wpa_supplicant config
        mkdir -p "${ROOTFS}/etc/wpa_supplicant"
        cat > "${ROOTFS}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" << EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
    key_mgmt=WPA-PSK
}
EOF
        chmod 600 "${ROOTFS}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

    else
        # Non-PXVIRT: use NetworkManager
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
dns=${WLAN_DNS//  /;};

[ipv6]
method=auto
EOF
        chmod 600 "${ROOTFS}/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
    fi

    echo "Wi-Fi configurations generated."
fi

echo "Debian rootfs configuration complete."
