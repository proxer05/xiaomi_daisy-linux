#!/usr/bin/env bash
#
# chroot_setup_debian.sh — Runs inside the Debian Bookworm arm64 rootfs via chroot.
# Configures APT, installs packages, enables services, and optionally installs PXVIRT.
#
# Usage (called by build_debian.sh):
#   chroot /path/to/rootfs /bin/bash /tmp/chroot_setup_debian.sh [true|false]
#
set -euo pipefail

WITH_PXVIRT="${1:-false}"

echo "=== Debian Bookworm ARM64 chroot setup ==="
echo "    PXVIRT: ${WITH_PXVIRT}"

###############################################################################
# Configure APT sources
###############################################################################
echo "Configuring APT sources..."
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

###############################################################################
# Update and install essential packages
###############################################################################
echo "Updating package lists..."
apt-get update

###############################################################################
# Configure Locale First (prevents Perl warnings during package installs)
###############################################################################
echo "Configuring locale..."
apt-get install -y locales
sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
/usr/sbin/locale-gen 2>/dev/null || true
/usr/sbin/update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo "Installing essential packages..."
apt-get install -y --no-install-recommends \
    sudo \
    openssh-server \
    vim \
    nano \
    htop \
    curl \
    wget \
    git \
    net-tools \
    iproute2 \
    systemd-resolved \
    dbus \
    ca-certificates \
    gnupg \
    usbutils \
    e2fsprogs \
    wpasupplicant \
    wireless-tools \
    firmware-misc-nonfree \
    python3 \
    passwd \
    systemd-timesyncd \
    lsb-release

###############################################################################
# Enable services
###############################################################################
echo "Enabling systemd services..."
systemctl enable ssh.service 2>/dev/null || true
systemctl enable systemd-networkd.service 2>/dev/null || true
systemctl enable systemd-resolved.service 2>/dev/null || true
systemctl enable systemd-timesyncd.service 2>/dev/null || true
systemctl enable usb-gadget.service 2>/dev/null || true
systemctl enable resize-rootfs.service 2>/dev/null || true
systemctl enable serial-getty@ttyMSM0.service 2>/dev/null || true
systemctl enable wpa_supplicant@wlan0.service 2>/dev/null || true

###############################################################################
# User setup
###############################################################################
echo "Setting up users..."

# Set root password
echo "root:root" | /usr/sbin/chpasswd

###############################################################################
# PXVIRT Installation (conditional)
###############################################################################
if [[ "${WITH_PXVIRT}" == "true" ]]; then
    echo ""
    echo "=========================================="
    echo " Installing PXVIRT (Proxmox VE for ARM64)"
    echo "=========================================="
    echo ""

    # 1. Add PXVIRT GPG key and repository
    echo "Adding PXVIRT repository..."
    curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg \
        -o /etc/apt/trusted.gpg.d/lierfang.gpg

    echo "deb https://mirrors.lierfang.com/pxcloud/pxvirt bookworm main" \
        > /etc/apt/sources.list.d/pxvirt-sources.list

    apt-get update

    # 2. Install ifupdown2 (required by Proxmox for network management)
    echo "Installing ifupdown2..."
    # Disable NetworkManager if present
    systemctl disable NetworkManager.service 2>/dev/null || true
    systemctl stop NetworkManager.service 2>/dev/null || true

    apt-get install -y ifupdown2
    rm -f /etc/network/interfaces.new 2>/dev/null || true

    # Configure network interfaces for PXVIRT
    # USB gadget is managed by systemd-networkd for DHCP, but we'll define a bridge stub for Proxmox GUI
    cat > /etc/network/interfaces << 'IFACE_EOF'
# Loopback
auto lo
iface lo inet loopback

# Proxmox default bridge (requires manual assignment of physical ports like eth0 in GUI)
auto vmbr0
iface vmbr0 inet static
    address 172.16.42.2/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
IFACE_EOF

    # 3. Install backports dependencies explicitly
    echo "Installing dependencies from backports..."
    apt-get install -y -t bookworm-backports python3-virt-firmware

    # 4. Install PXVIRT packages
    echo "Installing PXVIRT packages (this may take a while)..."
    apt-get install -y \
        proxmox-ve \
        pve-manager \
        qemu-server \
        pve-cluster

    echo "Explicitly enabling PVE services..."
    systemctl enable pve-cluster pvedaemon pveproxy pvestatd lxc lxc-net 2>/dev/null || true

    echo ""
    echo "=========================================="
    echo " PXVIRT installation complete!"
    echo " Web UI: https://<phone-ip>:8006"
    echo " Login:  root / root (Linux PAM)"
    echo "=========================================="
    echo ""

else
    echo "Skipping PXVIRT installation (--with-pxvirt not set)."

    # Install NetworkManager for non-PXVIRT Debian images
    apt-get install -y --no-install-recommends network-manager
    systemctl enable NetworkManager.service 2>/dev/null || true
fi

###############################################################################
# Cleanup
###############################################################################
echo "Cleaning up APT cache..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo ""
echo "=== Debian chroot setup complete ==="
