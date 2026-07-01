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

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

echo "=== Debian Trixie ARM64 chroot setup ==="
echo "    PXVIRT: ${WITH_PXVIRT}"

# Prevent services from starting during package installation in chroot
cat > /usr/sbin/policy-rc.d << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

###############################################################################
# Configure APT sources
###############################################################################
echo "Configuring APT sources..."
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
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
    lsb-release \
    xz-utils

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

    # 1. Download and configure eWloYW8/pve-arm64-builder tarball repository
    echo "Fetching latest PVE9 ARM64 repository from GitHub..."
    TARBALL_URL=$(curl -sL https://api.github.com/repos/eWloYW8/pve-arm64-builder/releases/latest | grep "browser_download_url" | grep "proxmox-arm64" | cut -d '"' -f 4)
    if [[ -z "${TARBALL_URL}" ]]; then
        echo "Failed to fetch tarball URL. Using hardcoded fallback."
        TARBALL_URL="https://github.com/eWloYW8/pve-arm64-builder/releases/download/20260601/proxmox-arm64-20260601.tar.xz"
    fi

    echo "Downloading ${TARBALL_URL}..."
    wget -qO /tmp/pve-arm64.tar.xz "${TARBALL_URL}"

    echo "Extracting PVE repository..."
    mkdir -p /opt/pve-arm64
    tar -xf /tmp/pve-arm64.tar.xz -C /opt/pve-arm64 --strip-components=1

    echo "deb [trusted=yes arch=arm64] file:/opt/pve-arm64 ./" > /etc/apt/sources.list.d/pve-arm64-local.list
    apt-get update

    # 2. Install ifupdown2 + dnsmasq (required by Proxmox for network management)
    echo "Installing ifupdown2 and dnsmasq..."
    # Disable NetworkManager if present
    systemctl disable NetworkManager.service 2>/dev/null || true
    systemctl stop NetworkManager.service 2>/dev/null || true

    apt-get install -y ifupdown2 dnsmasq
    rm -f /etc/network/interfaces.new 2>/dev/null || true

    # Note: /etc/network/interfaces and /etc/dnsmasq.d/ config are written by
    # configure_rootfs_debian.sh which has access to the network.config variables.

    # 3. Install dependencies explicitly
    echo "Installing python3-virt-firmware..."
    apt-get install -y python3-virt-firmware

    # 4. Install PXVIRT packages
    echo "Installing PXVIRT packages (this may take a while)..."
    apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        install \
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

    echo "Cleaning up PVE install artifacts..."
    rm -rf /opt/pve-arm64
    rm -f /tmp/pve-arm64.tar.xz
    rm -f /etc/apt/sources.list.d/pve-arm64-local.list
    apt-get update

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
rm -f /usr/sbin/policy-rc.d

echo ""
echo "=== Debian chroot setup complete ==="
