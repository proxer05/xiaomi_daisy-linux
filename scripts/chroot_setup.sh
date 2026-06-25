#!/usr/bin/env bash
#
# chroot_setup.sh — Runs inside the ALARM rootfs via chroot.
# Initializes pacman, installs essential packages, enables services.
#
set -euo pipefail

WITH_PLASMA="${1:-false}"

echo "=== Arch Linux ARM chroot setup ==="

# Temporarily disable pacman sandboxing to avoid Landlock errors under QEMU
if grep -q "#DisableSandbox" /etc/pacman.conf; then
    sed -i 's/#DisableSandbox/DisableSandbox/' /etc/pacman.conf
elif ! grep -q "^DisableSandbox" /etc/pacman.conf; then
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

###############################################################################
# Initialize pacman
###############################################################################
echo "Initializing pacman keyring..."
pacman-key --init
pacman-key --populate archlinuxarm

###############################################################################
# Update system (skip if network is unavailable in chroot)
###############################################################################
echo "Updating system..."
pacman -Syu --noconfirm

# Remove massive unneeded desktop GPU firmware that might be bundled in the rootfs tarball
echo "Removing unneeded desktop firmware..."
pacman -Rdd --noconfirm linux-firmware-radeon linux-firmware-nvidia 2>/dev/null || true

##############################################################################
# Install essential packages
###############################################################################
echo "Installing essential packages..."
pacman -S --noconfirm --needed \
    --assume-installed linux-firmware-radeon \
    --assume-installed linux-firmware-nvidia \
    base \
    linux-firmware \
    linux-firmware-qcom \
    wireless-regdb \
    networkmanager \
    iwd \
    openssh \
    sudo \
    nano \
    vim \
    git \
    make \
    base-devel \
    usbutils \
    iproute2 \
    dhcpcd \
    ntp \
    wget \
    curl \
    git

###############################################################################
# Enable services
###############################################################################
echo "Enabling systemd services..."
systemctl enable sshd.service 2>/dev/null || true
systemctl enable systemd-networkd.service 2>/dev/null || true
systemctl enable systemd-resolved.service 2>/dev/null || true
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl enable iwd.service 2>/dev/null || true
systemctl enable usb-gadget.service 2>/dev/null || true
systemctl enable resize-rootfs.service 2>/dev/null || true
systemctl enable serial-getty@ttyMSM0.service 2>/dev/null || true
systemctl enable dhcpcd.service 2>/dev/null || true

###############################################################################
# User setup
###############################################################################
echo "Setting up users..."

# Set root password
echo "root:root" | chpasswd

# Ensure 'alarm' user exists with proper groups
if id alarm &>/dev/null; then
    usermod -aG wheel,audio,video,input,render alarm 2>/dev/null || true
else
    useradd -m -G wheel,audio,video,input,render -s /bin/bash alarm
    echo "alarm:alarm" | chpasswd
fi

# Allow wheel group to sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || true
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers 2>/dev/null || true

###############################################################################
# Compile and install custom PKGBUILDs
###############################################################################
if [[ "$WITH_PLASMA" == "true" ]]; then
    echo "Installing Plasma Mobile and related applications..."
    pacman -S --noconfirm \
        plasma-mobile \
        kdeplasma-addons \
        angelfish \
        kclock \
        kweather \
        plasmatube \
        audiotube \
        kalk \
        discover \
        neochat \
        tokodon \
        koko \
        qmlkonsole \
        okular \
        elisa

    if [[ -d /opt/pkgbuilds/tinydm-git ]]; then
        echo "Compiling and installing tinydm..."
        chown -R alarm:alarm /opt/pkgbuilds
        # Build package as alarm user
        su - alarm -c 'cd /opt/pkgbuilds/tinydm-git && makepkg -sc --noconfirm'
        # Install the generated package as root
        pacman -U --noconfirm /opt/pkgbuilds/tinydm-git/*.pkg.tar.*
        systemctl disable tinydm.service 2>/dev/null || true
        
        # Set plasma-mobile as the default session for tinydm
        tinydm-set-session -f -s /usr/share/wayland-sessions/plasma-mobile.desktop || true
        
        # Cleanup
        rm -rf /opt/pkgbuilds
    fi
else
    echo "Skipping Plasma Mobile installation (--with-plasma not set)."
    rm -rf /opt/pkgbuilds 2>/dev/null || true
fi

###############################################################################
# Locale
###############################################################################
echo "Configuring locale..."
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
locale-gen 2>/dev/null || true

###############################################################################
# First-boot setup script
###############################################################################
cat > /usr/local/bin/first-boot-setup.sh << 'FIRSTBOOT_EOF'
#!/bin/bash
#
# First boot setup for Arch Linux ARM on Mi A2 Lite
#
echo ""
echo "=========================================="
echo " Welcome to Arch Linux ARM"
echo " Xiaomi Mi A2 Lite (daisy)"
echo "=========================================="
echo ""
echo "First-boot setup:"
echo ""

# Initialize pacman keyring if not done
if [ ! -f /etc/pacman.d/gnupg/trustdb.gpg ]; then
    echo "Initializing pacman keyring..."
    pacman-key --init
    pacman-key --populate archlinuxarm
fi

# Set timezone
echo "Setting timezone to UTC (change with: timedatectl set-timezone <ZONE>)"
timedatectl set-timezone UTC 2>/dev/null || true

# Resize rootfs if possible
echo "Checking if rootfs can be expanded..."
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [ -n "${ROOT_DEV}" ]; then
    ROOT_PART_NUM=$(echo "${ROOT_DEV}" | grep -o '[0-9]*$')
    ROOT_DISK=$(echo "${ROOT_DEV}" | sed 's/p[0-9]*$//')
    if command -v growpart &>/dev/null && command -v resize2fs &>/dev/null; then
        growpart "${ROOT_DISK}" "${ROOT_PART_NUM}" 2>/dev/null || true
        resize2fs "${ROOT_DEV}" 2>/dev/null || true
        echo "Rootfs expanded."
    else
        echo "Install cloud-guest-utils for automatic partition expansion."
    fi
fi

echo ""
echo "Setup complete. Disabling first-boot service."
systemctl disable first-boot-setup.service 2>/dev/null || true
rm -f /etc/systemd/system/first-boot-setup.service

echo ""
echo "Default credentials:"
echo "  User: alarm / alarm"
echo "  Root: root  / root"
echo ""
echo "IMPORTANT: Change passwords with 'passwd' command!"
echo ""
FIRSTBOOT_EOF
chmod +x /usr/local/bin/first-boot-setup.sh

cat > /etc/systemd/system/first-boot-setup.service << 'EOF'
[Unit]
Description=First Boot Setup
After=network.target
ConditionPathExists=/usr/local/bin/first-boot-setup.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-setup.sh
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF
systemctl enable first-boot-setup.service 2>/dev/null || true

###############################################################################
# Done
###############################################################################
# Re-enable pacman sandboxing for the target system
sed -i 's/^DisableSandbox/#DisableSandbox/' /etc/pacman.conf

echo ""
echo "=== Chroot setup complete ==="
echo ""
