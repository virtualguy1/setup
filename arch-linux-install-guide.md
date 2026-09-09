# Arch Linux Installation Guide (UEFI / GPT)

A complete, step-by-step guide to installing Arch Linux with the Cinnamon Desktop Environment, based on Tony's tutorial (*"How to Install Arch Linux | Full Guide"*).

---

## 1. Prerequisites & Boot Setup

- **Target System:** Modern 64-bit UEFI computer (most machines manufactured after 2012).
- **Partition Table:** GPT (GUID Partition Table).
- **Installation Medium:** Live Arch Linux USB drive.

1. Insert your prepared Arch Linux live USB into the machine.
2. Power on and enter your boot menu (commonly `F12`, `F11`, `F10`, `F2`, or `Del`).
3. Select the Arch Linux UEFI boot entry and press **Enter** to boot into the live console environment.

---

## 2. Pre-Installation Configuration

### Set Keymap (Optional)
If you are using a non-US keyboard layout, set your keymap before typing complex commands:
```bash
# Example for French keyboard:
loadkeys fr

# For default US keyboard:
loadkeys us
```

### Verify Internet Connection
Ethernet connections configure automatically via DHCP. Verify connectivity by pinging Arch Linux:
```bash
ping archlinux.org
```
*(Press `Ctrl + C` to interrupt and stop the ping test).*

> **Tip:** If you are on Wi-Fi instead of Ethernet, use the interactive `iwctl` tool:
> ```bash
> iwctl
> device list
> station <device> scan
> station <device> get-networks
> station <device> connect <SSID>
> exit
> ```

### Terminal Readability Tips
Make the console font larger and easier to read:
```bash
setfont dd
```
- Clear screen shortcut: `Ctrl + L`
- Cancel running command: `Ctrl + C`

---

## 3. Partitioning the Disk (`cfdisk`)

Tony recommends using `cfdisk` for a visual, user-friendly partition manager:

```bash
cfdisk
```

1. **Select Label Type:** Choose **`gpt`** and press Enter.
2. **Wipe Existing Partitions (Fresh Install):**
   - Use the **Up/Down** arrow keys to highlight each partition.
   - Navigate to **Delete** with Left/Right arrows and hit **Enter**.
   - Repeat until the disk is entirely free space.
3. **Create Required Partitions:**
   - **Boot (EFI) Partition:**
     - Select **New** $ightarrow$ Size: `1G` (1 GB) $ightarrow$ `/dev/sda1`
     - Change Type to `EFI System` (optional but recommended).
   - **Swap Partition:**
     - Select Free Space $ightarrow$ **New** $ightarrow$ Size: `4G` (4 GB) $ightarrow$ `/dev/sda2`
     - Change Type to `Linux swap`.
   - **Root Partition:**
     - Select remaining Free Space $ightarrow$ **New** $ightarrow$ Size: *Leave default (entire disk remainder)* $ightarrow$ `/dev/sda3`
     - Type: `Linux filesystem`.
4. **Write Changes:**
   - Navigate to **Write**, press Enter, type `yes`, and hit Enter.
   - Navigate to **Quit** and press Enter.

Verify the partition layout:
```bash
lsblk
```

---

## 4. Formatting the Partitions

Create the filesystems for each partition:

```bash
# 1. Format Root partition to ext4
mkfs.ext4 /dev/sda3

# 2. Format EFI Boot partition to FAT32
mkfs.fat -F32 /dev/sda1

# 3. Initialize Swap partition
mkswap /dev/sda2
```

---

## 5. Mounting File Systems & Enabling Swap

Mount the partitions to `/mnt` in the correct hierarchical order:

```bash
# Mount root filesystem
mount /dev/sda3 /mnt

# Create boot EFI directory and mount boot partition
mkdir -p /mnt/boot/efi
mount /dev/sda1 /mnt/boot/efi

# Enable the swap partition
swapon /dev/sda2
```

Confirm mounts are properly mapped:
```bash
lsblk
```

---

## 6. Installing Base System Packages (`pacstrap`)

Use `pacstrap` to install the base system, kernel, firmware, bootloader, build essentials, and network utilities into `/mnt`:

```bash
pacstrap /mnt base linux linux-firmware sof-firmware base-devel grub efibootmgr networkmanager vim
```

### Package Details:
- `base`: Core Arch Linux system packages.
- `linux`: Standard Linux kernel.
- `linux-firmware` & `sof-firmware`: Hardware and modern soundcard drivers.
- `base-devel`: Essential compilation tools (required for AUR packages).
- `grub` & `efibootmgr`: GRUB bootloader and UEFI boot manager utilities.
- `networkmanager`: Network connection management daemon.
- `vim`: Text editor for system configuration files.

---

## 7. Generating the File System Table (`fstab`)

Generate the persistent fstab file using UUIDs:

```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Inspect the generated file to verify all three partitions (root, EFI, swap) are registered:
```bash
cat /mnt/etc/fstab
```

---

## 8. System Configuration (in `arch-chroot`)

Enter your newly installed system environment:

```bash
arch-chroot /mnt
```

### 8.1 Timezone & Hardware Clock
Set your local timezone (e.g., `America/New_York` or `Asia/Kolkata`):
```bash
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc
```

### 8.2 Localization
1. Open `/etc/locale.gen` in vim:
   ```bash
   vim /etc/locale.gen
   ```
   *(Uncomment `en_US.UTF-8 UTF-8` by removing the `#` symbol. Save and exit with `:wq`).*
2. Generate the configured locales:
   ```bash
   locale-gen
   ```
3. Set your system language:
   ```bash
   echo "LANG=en_US.UTF-8" > /etc/locale.conf
   ```

### 8.3 Network Hostname
Define your computer's network name:
```bash
echo "archlinux" > /etc/hostname
```

### 8.4 Set Root Password
Set the superuser (root) password:
```bash
passwd
```

### 8.5 Create a Regular User & Sudo Privileges
Create a standard user with administrative privileges via the `wheel` group:
```bash
useradd -m -G wheel -s /bin/bash tony
passwd tony
```
*(Replace `tony` with your preferred username).*

Enable `sudo` permissions for the `wheel` group:
```bash
EDITOR=vim visudo
```
Search for and uncomment the following line:
```
%wheel ALL=(ALL:ALL) ALL
```
*(Save and exit with `:wq`).*

---

## 9. Enable Core Services & Configure GRUB

### Enable NetworkManager Service
Ensure the network service starts automatically at boot:
```bash
systemctl enable NetworkManager
```

### Install & Configure GRUB Bootloader
Install GRUB to the disk and generate its configuration file:
```bash
grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg
```
*(You can safely ignore any warning regarding `os-prober` if you are not dual-booting).*

---

## 10. Exit Chroot & Reboot

Leave the chroot environment, unmount all partitions, and reboot into your new Arch Linux install:

```bash
exit
umount -a
reboot
```
*(Remove your live USB drive when the system restarts).*

---

## 11. Post-Installation: Desktop Environment & Daily Utilities

Log in with your created user account and password.

### 11.1 Verify Internet Connection
```bash
ping archlinux.org
```
*(Press `Ctrl + C` to stop).*

### 11.2 Install Desktop Environment & Display Manager
Install the Cinnamon desktop environment, LightDM login greeter, and Xorg:
```bash
sudo pacman -S cinnamon lightdm lightdm-gtk-greeter xorg
```
*(Press **Enter** to accept all default package selections).*

### 11.3 Install Terminal & Web Browser
Install the Alacritty GPU-accelerated terminal and Firefox:
```bash
sudo pacman -S alacritty firefox
```

### 11.4 Enable and Start LightDM
Enable and start LightDM immediately to launch the graphical desktop:
```bash
sudo systemctl enable --now lightdm
```

### 11.5 Final Verification (`neofetch`)
Log into the Cinnamon desktop, launch Alacritty, and celebrate your install:
```bash
sudo pacman -S neofetch
neofetch
```
