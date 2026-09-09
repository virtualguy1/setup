# Arch Linux Automated Installer

A personal, interactive Arch Linux installation script with sane defaults, built following the UEFI/GPT architecture described in Tony's Arch Linux installation guide.

## Features & Sane Defaults

- **UEFI & GPT:** Automatic GPT partitioning using `sgdisk` (`1G` FAT32 EFI partition, `4G` Linux Swap, remainder `ext4` Root).
- **Drive Safety:** Dynamically handles NVMe (`/dev/nvme0n1pX`) and SATA/SCSI/VirtIO (`/dev/sdXX`) naming. Requires explicit uppercase `YES` confirmation before any destructive disk modifications.
- **Microcode & Drivers:** Automatically detects CPU vendor (`intel-ucode` or `amd-ucode`) and GPU hardware (`mesa`, Intel Vulkan/media drivers, AMD Vulkan, or Nvidia DKMS).
- **Audio Stack:** Modern PipeWire audio stack (`pipewire`, `pipewire-pulse`, `wireplumber`).
- **Base CLI System:** Clean base system without graphical desktop bloat, ready for custom window managers or desktop environments.
- **Secure Configuration:** Prompts for passwords securely via `read -s` and pipes them directly into `chpasswd`.
- **Sudoers:** Enables `sudo` privileges for the `wheel` group cleanly via `/etc/sudoers.d/10-wheel`.
- **Network:** Enables `NetworkManager` for auto-dhcp and Wi-Fi management (`nmcli`/`nmtui`).
- **Default Locale & Timezone:** `Asia/Kolkata` and `en_US.UTF-8` (customizable via environment variables).

---

## How to Use from Arch Live USB

1. Boot into the Arch Linux live USB in **UEFI mode**.
2. Connect to the internet (or let the script launch `iwctl` for you).
3. Download or copy `install.sh`:
   ```bash
   curl -O https://raw.githubusercontent.com/<your-username>/<repo>/main/install.sh
   # or mount a secondary flash drive containing install.sh
   ```
4. Make the script executable and run it:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```

### Overriding Defaults via Environment Variables

You can override defaults without editing the script by passing environment variables before running:

```bash
TIMEZONE="America/New_York" DEFAULT_HOSTNAME="myarchbox" SWAP_SIZE="8G" ./install.sh
```

| Variable | Default | Description |
| :--- | :--- | :--- |
| `TIMEZONE` | `Asia/Kolkata` | System timezone (path under `/usr/share/zoneinfo/`) |
| `LOCALE` | `en_US.UTF-8` | System locale generated in `/etc/locale.gen` |
| `KEYMAP` | `us` | Live console keyboard layout |
| `DEFAULT_HOSTNAME` | `archlinux` | Default hostname suggested during prompt |
| `EFI_SIZE` | `1G` | Size allocated to the EFI system partition |
| `SWAP_SIZE` | `4G` | Size allocated to the dedicated swap partition |
| `BOOTLOADER_ID` | `GRUB` | UEFI boot entry name registered in NVRAM |
