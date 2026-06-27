# Mainline Linux for Xiaomi Mi A2 Lite (daisy)

Build system for creating **Arch Linux ARM** or **Debian Bookworm** images for the Xiaomi Mi A2 Lite (codename: `daisy`), based on the Qualcomm Snapdragon 625 (MSM8953) SoC.

The Debian variant optionally includes **PXVIRT** (Proxmox VE for ARM64), turning the phone into a pocket-sized hypervisor capable of running LXC containers.

## Credits & References

- **[KlipperPhonesLinux](https://github.com/umeiko/KlipperPhonesLinux/)** — Firmware blobs, kernel config, and boot image methodology for MSM8953 phones
- **[PostmarketOS](https://wiki.postmarketos.org/wiki/Xiaomi_Mi_A2_Lite_(xiaomi-daisy))** — Device tree, mainline kernel support, and lk2nd bootloader
- **[msm8953-mainline](https://github.com/msm8953-mainline/linux)** — Mainline Linux kernel port for MSM8953 devices
- **[Arch Linux ARM](https://archlinuxarm.org/)** — AArch64 root filesystem
- **[PXVIRT / Proxmox VE ARM64](https://mirrors.lierfang.com/pxcloud/pxvirt/)** — Community Proxmox VE port for ARM64

## Device Specifications

| Feature | Detail |
|---------|--------|
| **SoC** | Qualcomm Snapdragon 625 (MSM8953) |
| **CPU** | 8× Cortex-A53 @ 2.0 GHz |
| **GPU** | Adreno 506 |
| **RAM** | 3/4 GB |
| **Storage** | 32/64 GB eMMC |
| **Display** | 5.84" 1080×2280 IPS LCD |
| **WiFi** | Qualcomm WCN36xx (wcn36xx driver) |
| **Architecture** | AArch64 (arm64) |

## Prerequisites

- Linux host (Arch Linux, Ubuntu 22.04+, Fedora)
- Root access (for chroot, loop mounts)
- ~10 GB free disk space
- Unlocked bootloader on the Mi A2 Lite
- `fastboot` installed (`android-tools`)
- For Debian builds: `debootstrap` and `qemu-user-static`

## Quick Start

### Arch Linux ARM

```bash
git clone <this-repo> && cd daisy-archlinux
chmod +x build.sh scripts/*.sh
sudo ./build.sh
cd output/ && sudo ./flash_archlinux.sh
```

### Debian Bookworm (with Proxmox VE)

```bash
git clone <this-repo> && cd daisy-archlinux

# 1. Configure your network settings
cp example-network.config network.config
nano network.config   # Edit Wi-Fi IP, gateway, timezone, etc.

# 2. Build the image
sudo ./build_debian.sh --with-pxvirt

# 3. Flash to device
cd output/ && sudo ./flash_debian.sh
```

## Network Configuration

All network settings are stored in `network.config` (gitignored). Copy the example template and edit it before building:

```bash
cp example-network.config network.config
```

| Variable | Description | Default |
|----------|-------------|---------|
| `WIFI_SSID` | Your Wi-Fi network name | `MyWiFiNetwork` |
| `WIFI_PASS` | Your Wi-Fi password | `MyWiFiPassword` |
| `WIFI_COUNTRY` | ISO 3166-1 country code for regulatory domain | `US` |
| `WLAN_ADDRESS` | Static IP for Wi-Fi interface (CIDR) | `192.168.1.100/24` |
| `WLAN_GATEWAY` | Wi-Fi default gateway | `192.168.1.1` |
| `WLAN_DNS` | DNS servers for Wi-Fi | `8.8.8.8 8.8.4.4` |
| `USB_ADDRESS` | Static IP for USB RNDIS gadget (CIDR) | `172.16.42.1/24` |
| `VMBR_ADDRESS` | Internal Proxmox bridge subnet (CIDR) | `10.10.10.1/24` |
| `NETMAP_HOME_RANGE` | Home network range for 1:1 container mapping | `192.168.1.200/26` |
| `TIMEZONE` | System timezone | `UTC` |

### NETMAP Container Networking (PXVIRT)

With `--with-pxvirt`, containers get **real IPs on your home Wi-Fi network** using 1:1 NETMAP NAT. No port forwarding or reverse proxy required!

The `NETMAP_HOME_RANGE` variable reserves a block of IPs on your home network for containers. The default `192.168.1.200/26` maps like this:

| Container Internal IP | Home Network IP | Access from any device |
|---|---|---|
| `10.10.10.100` | `192.168.1.200` | `http://192.168.1.200:8080` |
| `10.10.10.105` | `192.168.1.205` | `http://192.168.1.205:8080` |
| `10.10.10.115` | `192.168.1.215` | `http://192.168.1.215:8080` |

> **Note:** Make sure the NETMAP range doesn't overlap with other devices on your network (routers, printers, etc).

## Build Options

### Arch Linux (`build.sh`)

```
sudo ./build.sh [OPTIONS]

  --skip-deps          Skip installing host dependencies
  --skip-kernel        Skip kernel compilation
  --skip-rootfs        Skip rootfs creation
  --skip-lk2nd         Skip lk2nd compilation
  --rootfs-size SIZE   Root filesystem size in MB (default: 4096)
  --kernel-branch BR   Kernel git branch
  --help               Show help
```

### Debian (`build_debian.sh`)

```
sudo ./build_debian.sh [OPTIONS]

  --with-pxvirt        Install Proxmox VE (PXVIRT) for ARM64
  --skip-deps          Skip installing host dependencies
  --skip-kernel        Skip kernel compilation
  --skip-rootfs        Skip rootfs creation
  --skip-lk2nd         Skip lk2nd compilation
  --rootfs-size SIZE   Root filesystem size in MB (default: 8192)
  --kernel-branch BR   Kernel git branch
  --help               Show help
```

## Output Files

| File | Description |
|------|-------------|
| `boot.img` | Kernel + DTB + initramfs (flash to boot via lk2nd) |
| `root.img` | Root filesystem (ext4, flash to userdata) |
| `lk2nd.img` | Secondary bootloader (flash to boot partition first) |
| `flash_*.sh` | Convenience script to flash all images |

## Flashing Procedure

### Step 1: Flash lk2nd (one-time)

lk2nd is a secondary bootloader that replaces the stock Android boot image and provides a standard fastboot interface for booting mainline kernels.

```bash
# Phone in fastboot mode (Vol Down + Power + USB)
fastboot flash boot output/lk2nd.img
fastboot reboot
# Wait for lk2nd fastboot screen
```

### Step 2: Flash the Image

```bash
cd output/
sudo ./flash_debian.sh    # or ./flash_archlinux.sh
```

### Step 3: First Boot

| Variant | Login | SSH Access |
|---------|-------|------------|
| Arch Linux ARM | `alarm` / `alarm` (root: `root`) | `ssh alarm@172.16.42.1` |
| Debian / PXVIRT | `root` / `root` | `ssh root@172.16.42.1` |

- USB RNDIS networking is always available via USB cable
- Wi-Fi connects automatically if credentials were provided at build time
- **Proxmox Web UI** (PXVIRT only): `https://<phone-ip>:8006`

## Project Structure

```
daisy-archlinux/
├── build.sh                         # Arch Linux ARM build orchestrator
├── build_debian.sh                  # Debian Bookworm build orchestrator
├── example-network.config           # Network config template (committed)
├── network.config                   # User network config (gitignored)
├── .gitignore
├── configs/
│   └── msm8953_defconfig            # Custom kernel config (optional)
├── scripts/
│   ├── ensure_kernel_config.sh      # Patches kernel .config for LXC/Proxmox
│   ├── configure_rootfs.sh          # Arch Linux rootfs configuration
│   ├── configure_rootfs_debian.sh   # Debian rootfs configuration
│   ├── chroot_setup.sh              # Arch Linux chroot package setup
│   └── chroot_setup_debian.sh       # Debian chroot package setup + PXVIRT
├── output/                          # Build output (gitignored)
│   ├── boot.img
│   ├── root.img
│   ├── lk2nd.img
│   └── flash_debian.sh
└── work/                            # Build working directory (gitignored)
    ├── linux/                       # Kernel source
    ├── lk2nd/                       # lk2nd source
    └── ...
```

## Customization

### Custom Kernel Config

Place your custom kernel `.config` at `configs/msm8953_defconfig`. The build script will use it instead of the default.

```bash
sudo ./build_debian.sh --skip-kernel
cd work/linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
cp .config ../../configs/msm8953_defconfig
sudo ./build_debian.sh --skip-deps
```

### Rootfs Size

Default rootfs is 8 GB for Debian (4 GB for Arch). Adjust with:

```bash
sudo ./build_debian.sh --rootfs-size 16384  # 16 GB
```

### Adding Packages

- **Debian:** Edit `scripts/chroot_setup_debian.sh` to add packages to the `apt-get install` command.
- **Arch:** Edit `scripts/chroot_setup.sh` to add packages to the `pacman -S` command.

## License

Scripts in this repository are licensed under GPL-3.0, consistent with the Linux kernel and referenced projects.
