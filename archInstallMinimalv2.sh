#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Minimal Installation Script — Intel edition (UEFI / GPT)
#
# A variant of archInstallMinimal.sh tailored to Intel laptops with an Intel
# integrated GPU (validated on an 11th-gen Intel Core / Iris Xe Lenovo
# ThinkPad X1 Yoga, Gen 6). Same partitioning, bootloader and system
# configuration as the other scripts, but with two fixes over the generic
# minimal script:
#
#   1. AUDIO: the generic minimal script installed no audio server at all,
#      and its firmware auto-detection never installed `sof-firmware`. Many
#      recent Intel laptops (this ThinkPad included — confirmed on its
#      ArchWiki page) use a cAVS/SOF audio DSP and produce NO sound without
#      it, regardless of which HDA codec is present. This script installs
#      sof-firmware + alsa-ucm-conf + alsa-utils + pipewire/pipewire-pulse/
#      wireplumber, and globally enables the PipeWire user services so audio
#      works after first boot without any manual `systemctl --user` step.
#
#   2. GRAPHICS: mesa + vulkan-intel + intel-media-driver are now installed
#      unconditionally for the Iris Xe (or any Gen8+ Intel) iGPU, instead of
#      being left out entirely as in the generic minimal script.
#
# Vendor auto-detection for AMD CPUs/GPUs and Wi-Fi vendors other than
# Intel/Realtek has been removed on purpose — this script assumes an Intel
# platform. Use archInstallMinimal.sh if you need broader hardware coverage.
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  KEYMAP=de-latin1 SWAP_SIZE=8G ./archInstallMinimalIntel.sh
#
# Firmware overrides:
#   FULL_FIRMWARE=1                 install the full linux-firmware meta package
#                                   instead of the detected subset
#   EXTRA_FIRMWARE="pkg1 pkg2"      append firmware packages to the detected set
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-archlinux}"
EFI_SIZE="${EFI_SIZE:-1G}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
BOOTLOADER_ID="${BOOTLOADER_ID:-GRUB}"
KERNEL="${KERNEL:-linux-zen}"
FULL_FIRMWARE="${FULL_FIRMWARE:-0}"
EXTRA_FIRMWARE="${EXTRA_FIRMWARE:-}"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_SUCCESS="\033[1;32m"
COLOR_TITLE="\033[1;36m"

log_info()    { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2; }
log_success() { echo -e "${COLOR_SUCCESS}[OK]${COLOR_RESET} $*"; }
log_title()   { echo -e "\n${COLOR_TITLE}=== $* ===${COLOR_RESET}"; }

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------
# On any failure: report the line, unmount whatever is under /mnt, disable
# swap, and exit with the original status.
cleanup_on_err() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log_error "Installation failed on line $1 with exit code $exit_code."
    if mountpoint -q /mnt 2>/dev/null; then
      log_warn "Unmounting filesystems under /mnt..."
      umount -R /mnt 2>/dev/null || log_warn "Could not fully unmount /mnt; run manually: umount -R /mnt"
    fi
    swapoff -a 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap 'cleanup_on_err $LINENO' ERR

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# Verify connectivity; offer to launch iwctl for Wi-Fi if it is missing.
check_internet() {
  log_info "Verifying internet connection..."
  if ping -c 1 -W 3 ping.archlinux.org &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
    log_success "Internet connectivity active."
    return 0
  fi

  log_warn "No active internet connection detected."
  read -rp "Would you like to launch 'iwctl' to connect to Wi-Fi now? [y/N]: " launch_wifi
  if [[ "${launch_wifi}" =~ ^[Yy]$ ]]; then
    iwctl
  fi

  if ping -c 1 -W 3 ping.archlinux.org &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
    log_success "Internet connectivity established."
  else
    log_error "Unable to establish an internet connection. An active internet connection is required."
    exit 1
  fi
}

# Prompt twice for a password and print it on stdout.
#
# NOTE: This function is called via $(...), so ONLY the final password may go
# to stdout. All prompts, newlines and warnings must be sent to stderr.
prompt_secure_password() {
  local prompt_label="$1"
  local pass1 pass2
  while true; do
    read -rsp "Enter ${prompt_label} password: " pass1
    echo >&2
    read -rsp "Confirm ${prompt_label} password: " pass2
    echo >&2
    if [[ -z "${pass1}" ]]; then
      log_warn "Password cannot be empty. Please try again." >&2
    elif [[ "${pass1}" != "${pass2}" ]]; then
      log_warn "Passwords do not match. Please try again." >&2
    else
      printf '%s' "${pass1}"
      return 0
    fi
  done
}

# Build a partition device path, handling the "p" infix used by disks whose
# name ends in a digit (e.g. /dev/nvme0n1p1 vs /dev/sda1).
get_partition_device() {
  local disk="$1"
  local part_num="$2"
  if [[ "${disk}" =~ [0-9]$ ]]; then
    echo "${disk}p${part_num}"
  else
    echo "${disk}${part_num}"
  fi
}

# Print all PCI vendor IDs (lowercase hex, one per line) present on the system.
# Reads sysfs directly so this works even if pciutils is missing.
list_pci_vendors() {
  local f
  for f in /sys/bus/pci/devices/*/vendor; do
    [[ -r "${f}" ]] || continue
    local v
    v=$(< "${f}")
    echo "${v#0x}"
  done | sort -u
}

# Print all USB vendor IDs (lowercase hex, one per line) present on the system.
list_usb_vendors() {
  local f
  for f in /sys/bus/usb/devices/*/idVendor; do
    [[ -r "${f}" ]] || continue
    cat "${f}"
  done | sort -u
}

# Return 0 if any of the given vendor IDs appears in the supplied list.
has_vendor() {
  local list="$1"; shift
  local id
  for id in "$@"; do
    if grep -qx -- "${id}" <<< "${list}"; then
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------------------------
# Phase 1: Pre-flight Verification
# ------------------------------------------------------------------------------
log_title "Phase 1: Pre-flight Checks"

# 1. Root privileges
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be executed with root privileges. Run with: sudo ./archInstallMinimalIntel.sh"
  exit 1
fi
log_success "Running as root."

# 2. UEFI mode and firmware bitness
#    The Installation Guide checks /sys/firmware/efi/fw_platform_size, which
#    must read 64 for a 64-bit x64 UEFI. A value of 32 (IA32 UEFI) would need
#    the i386-efi GRUB target and is intentionally unsupported here.
if [[ ! -r /sys/firmware/efi/fw_platform_size ]]; then
  log_error "System is not booted in UEFI mode (BIOS/CSM detected). This script requires UEFI."
  exit 1
fi
UEFI_BITNESS=$(< /sys/firmware/efi/fw_platform_size)
if [[ "${UEFI_BITNESS}" != "64" ]]; then
  log_error "Detected ${UEFI_BITNESS}-bit UEFI firmware. This script only supports 64-bit (x64) UEFI."
  exit 1
fi
log_success "64-bit UEFI boot mode verified."

# 3. Console keymap (live session only; persisted to the target in Phase 6)
log_info "Applying keymap: ${KEYMAP}"
loadkeys "${KEYMAP}" 2>/dev/null || log_warn "Could not load keymap '${KEYMAP}', continuing with system default."

# 4. Internet connectivity
check_internet

# 5. System clock
#    An accurate clock avoids package signature and TLS failures during
#    pacstrap, so wait briefly (up to 15 s) for NTP to report sync.
log_info "Synchronizing system clock via NTP..."
timedatectl set-ntp true
NTP_SYNCED="no"
for _ in $(seq 1 15); do
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    NTP_SYNCED="yes"
    break
  fi
  sleep 1
done
if [[ "${NTP_SYNCED}" == "yes" ]]; then
  log_success "System clock synchronized via NTP."
else
  log_warn "NTP did not report synchronization within 15s. Continuing; package signature checks may fail if the clock is badly off."
fi

# 6. Pacman mirrors (best-effort; falls back to the ISO default list)
if command -v reflector &>/dev/null; then
  log_info "Ranking pacman mirrors with reflector (this may take a moment)..."
  if reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    log_success "Mirrorlist updated."
  else
    log_warn "reflector failed; continuing with the default mirrorlist."
  fi
else
  log_warn "reflector not available; continuing with the default mirrorlist."
fi

# ------------------------------------------------------------------------------
# Phase 2: User Inputs & Credential Gathering
# ------------------------------------------------------------------------------
log_title "Phase 2: System Credentials & Preferences"

# 1. Hostname
#    Per hostname(7): 1-63 chars, lowercase a-z, 0-9 and hyphen; must not
#    start or end with a hyphen.
while true; do
  read -rp "Enter system hostname [${DEFAULT_HOSTNAME}]: " input_hostname
  TARGET_HOSTNAME="${input_hostname:-$DEFAULT_HOSTNAME}"
  if [[ "${TARGET_HOSTNAME}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    break
  fi
  log_warn "Invalid hostname '${TARGET_HOSTNAME}'. Use only lowercase letters, digits and hyphens (1-63 chars, no leading/trailing hyphen)."
done
log_info "Hostname set to: ${TARGET_HOSTNAME}"

# 2. Username
while true; do
  read -rp "Enter username for standard user account: " USERNAME
  if [[ -z "${USERNAME}" ]]; then
    log_warn "Username cannot be empty."
  elif [[ ! "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_warn "Invalid username. Must begin with a lowercase letter or underscore, followed by lowercase letters, numbers, hyphens, or underscores."
  elif [[ "${USERNAME}" == "root" ]]; then
    log_warn "Username cannot be 'root'."
  else
    break
  fi
done

# 3. Passwords
log_info "Configure password for regular user '${USERNAME}':"
USER_PASSWORD=$(prompt_secure_password "user (${USERNAME})")

log_info "Configure password for system 'root':"
ROOT_PASSWORD=$(prompt_secure_password "root")

# ------------------------------------------------------------------------------
# Phase 3: Disk Selection & Partitioning
# ------------------------------------------------------------------------------
log_title "Phase 3: Disk Selection & Partitioning"

# 1. Target disk selection
echo "Available block devices:"
lsblk -d -e 7,11 -o NAME,SIZE,TYPE,MODEL,TRAN
echo

while true; do
  read -rp "Enter target disk name to install Arch Linux on (e.g. nvme0n1, sda, vda): " input_disk

  # Accept either "sda" or "/dev/sda".
  target_name="${input_disk#/dev/}"
  if [[ -z "${target_name}" ]]; then
    log_warn "Disk name cannot be empty."
    continue
  fi
  if [[ ! -b "/dev/${target_name}" ]]; then
    log_error "Block device '/dev/${target_name}' not found."
    continue
  fi
  DISK="/dev/${target_name}"

  # Refuse to wipe the disk backing the running live environment.
  LIVE_MEDIUM_DEV=""
  if mountpoint -q /run/archiso/bootmnt 2>/dev/null; then
    LIVE_MEDIUM_DEV=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    LIVE_MEDIUM_DEV=$(lsblk -no PKNAME "${LIVE_MEDIUM_DEV}" 2>/dev/null || true)
  fi
  if [[ -n "${LIVE_MEDIUM_DEV}" && "/dev/${LIVE_MEDIUM_DEV}" == "${DISK}" ]]; then
    log_error "${DISK} is the live installation medium you are currently booted from. Choose a different disk."
    continue
  fi
  break
done

# 2. Destructive-action confirmation
echo
echo -e "${COLOR_WARN}========================================================================"
echo -e " CRITICAL WARNING: ALL DATA ON ${DISK} WILL BE PERMANENTLY WIPED!"
echo -e "========================================================================${COLOR_RESET}"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${DISK}"
echo
read -rp "Type 'YES' in all capital letters to permanently wipe and format ${DISK}: " confirm_wipe
if [[ "${confirm_wipe}" != "YES" ]]; then
  log_error "Installation cancelled by user. No disk modifications were made."
  exit 1
fi

# 3. Partition layout
PART_EFI=$(get_partition_device "${DISK}" 1)
PART_SWAP=$(get_partition_device "${DISK}" 2)
PART_ROOT=$(get_partition_device "${DISK}" 3)

log_info "Target partition scheme:"
echo "  - EFI Boot Partition : ${PART_EFI} (${EFI_SIZE})"
echo "  - Swap Partition     : ${PART_SWAP} (${SWAP_SIZE})"
echo "  - Root Partition     : ${PART_ROOT} (Remainder of disk)"

# 4. Release any existing mounts / swap on the target disk
log_info "Ensuring disk partitions are unmounted..."
swapoff -a 2>/dev/null || true
for part in $(lsblk -ln -o NAME "${DISK}" | tail -n +2); do
  umount -l "/dev/${part}" 2>/dev/null || true
done

# 5. Wipe existing partition table and filesystem signatures
log_info "Wiping existing partition table and signatures on ${DISK}..."
wipefs -af "${DISK}"
sgdisk -Z "${DISK}"

# 6. Create GPT partitions
#    Type codes: ef00 = EFI System, 8200 = Linux swap,
#    8304 = Linux x86-64 root (Discoverable Partitions Specification), as used
#    in the Installation Guide's UEFI/GPT example layout.
log_info "Creating GPT partition table..."
sgdisk -n 1:0:+"${EFI_SIZE}"  -t 1:ef00 -c 1:"EFI System Partition" "${DISK}"
sgdisk -n 2:0:+"${SWAP_SIZE}" -t 2:8200 -c 2:"Linux Swap"           "${DISK}"
sgdisk -n 3:0:0               -t 3:8304 -c 3:"Linux Root"           "${DISK}"

# 7. Re-read the partition table and wait for device nodes
log_info "Informing kernel of partition changes..."
partprobe "${DISK}" 2>/dev/null || true
udevadm settle
for part in "${PART_EFI}" "${PART_SWAP}" "${PART_ROOT}"; do
  if [[ ! -b "${part}" ]]; then
    log_error "Partition device ${part} did not appear after partitioning."
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Phase 4: Formatting & Mounting
# ------------------------------------------------------------------------------
log_title "Phase 4: Formatting & Mounting Partitions"

# 1. Format
log_info "Formatting EFI partition (${PART_EFI}) as FAT32..."
mkfs.fat -F32 "${PART_EFI}"

log_info "Initializing Swap partition (${PART_SWAP})..."
mkswap "${PART_SWAP}"
swapon "${PART_SWAP}"

log_info "Formatting Root partition (${PART_ROOT}) as ext4..."
mkfs.ext4 -F "${PART_ROOT}"

# 2. Mount (swap is already active, so genfstab will pick it up too)
log_info "Mounting filesystems to /mnt..."
mount "${PART_ROOT}" /mnt
mkdir -p /mnt/boot/efi
mount "${PART_EFI}" /mnt/boot/efi

log_success "Filesystems successfully mounted."
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "${DISK}"

# ------------------------------------------------------------------------------
# Phase 5: Hardware Detection & Base Installation (pacstrap)
# ------------------------------------------------------------------------------
log_title "Phase 5: Hardware Detection & Pacstrap"

# 1. CPU vendor / microcode
#    This variant targets Intel platforms (validated on an 11th-gen Intel
#    Core / Iris Xe ThinkPad X1 Yoga). AMD is still detected so the correct
#    microcode is chosen if this script ends up run on the wrong machine, but
#    the graphics/audio package set below assumes Intel either way.
CPU_VENDOR="unknown"
CPU_UCODE=""
if grep -qi "GenuineIntel" /proc/cpuinfo; then
  CPU_VENDOR="intel"
  CPU_UCODE="intel-ucode"
  log_info "Intel processor detected. Selected microcode: intel-ucode"
elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
  CPU_VENDOR="amd"
  CPU_UCODE="amd-ucode"
  log_warn "AMD processor detected, but this script's graphics/audio package set is tailored for Intel. Continuing anyway."
else
  log_info "Unknown or virtual CPU vendor. Skipping microcode package."
fi
log_info "Detected CPU vendor: ${CPU_VENDOR}"

# 2. Graphics (Intel iGPU — Iris Xe / any Gen8+ Intel graphics)
#    mesa provides the 'iris' OpenGL driver, vulkan-intel the ANV Vulkan
#    driver, and intel-media-driver the modern iHD VAAPI driver used for
#    hardware video decode/encode. Installed unconditionally since this
#    script targets Intel-iGPU laptops.
GPU_PACKAGES=(mesa vulkan-intel intel-media-driver)
GPU_INFO=$(lspci -nnk 2>/dev/null | grep -i -E "vga|3d|display" || true)
if echo "${GPU_INFO}" | grep -qi "Intel"; then
  log_info "Intel GPU detected. Installing mesa, vulkan-intel, and intel-media-driver."
else
  log_warn "No Intel GPU detected via lspci, but installing the Intel graphics stack anyway (this script targets Intel iGPUs)."
fi

# 3. Firmware selection (Wi-Fi / Bluetooth / misc peripherals)
#    Same split-package approach as the generic minimal script, trimmed to
#    the vendors actually relevant to an Intel ThinkPad: Intel (always, for
#    Wi-Fi/BT/iGPU GuC-HuC), Realtek (some SKUs ship a Realtek Wi-Fi/BT
#    combo instead of Intel's), and Cirrus Logic (the smart amp used on
#    several recent ThinkPads' Dolby Atmos speaker setup, detected via ACPI).
FIRMWARE_PACKAGES=()
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  log_info "FULL_FIRMWARE=1: installing the complete linux-firmware meta package."
  FIRMWARE_PACKAGES+=(linux-firmware)
else
  PCI_VENDORS=$(list_pci_vendors)
  USB_VENDORS=$(list_usb_vendors)

  # Catch-all for miscellaneous devices not covered by a vendor package.
  FIRMWARE_PACKAGES+=(linux-firmware-other)

  # Intel: Wi-Fi (iwlwifi), Bluetooth, iGPU GuC/HuC. Always included.
  FIRMWARE_PACKAGES+=(linux-firmware-intel)

  # Realtek Wi-Fi/BT combo (rtw88/rtw89), if present instead of Intel's.
  if has_vendor "${PCI_VENDORS}" 10ec || has_vendor "${USB_VENDORS}" 0bda; then
    FIRMWARE_PACKAGES+=(linux-firmware-realtek)
    log_info "Realtek device detected; adding linux-firmware-realtek."
  fi

  # Cirrus Logic smart amp (CS35L41/CS35L56), sits on I2C/SPI so detect via
  # its ACPI ID rather than PCI/USB.
  CIRRUS_AMP_FOUND=0
  for acpi_dev in /sys/bus/acpi/devices/CSC35* /sys/bus/acpi/devices/CLSA*; do
    if [[ -e "${acpi_dev}" ]]; then
      CIRRUS_AMP_FOUND=1
      break
    fi
  done
  if [[ "${CIRRUS_AMP_FOUND}" -eq 1 ]]; then
    FIRMWARE_PACKAGES+=(linux-firmware-cirrus)
    log_info "Cirrus Logic smart amp detected; adding linux-firmware-cirrus."
  fi

  if [[ -n "${EXTRA_FIRMWARE}" ]]; then
    # shellcheck disable=SC2206
    FIRMWARE_PACKAGES+=(${EXTRA_FIRMWARE})
  fi

  log_info "Detected firmware set: ${FIRMWARE_PACKAGES[*]}"
fi

# 4. Audio (Sound Open Firmware + PipeWire stack)
#    THE FIX: the generic minimal script installed no audio server, and its
#    firmware detection never installed sof-firmware. This ThinkPad's own
#    ArchWiki page states it requires Sound Open Firmware for the soundcard
#    to work at all — the HDA codec alone is not enough on cAVS/SOF
#    platforms. alsa-ucm-conf supplies the UCM profile (sof-hda-dsp) that
#    PipeWire/WirePlumber use to route the speakers and microphone.
AUDIO_PACKAGES=(sof-firmware alsa-ucm-conf alsa-utils pipewire pipewire-pulse wireplumber)

# 5. Package list
BASE_PACKAGES=(
  # Core system
  base
  "${KERNEL}"

  # Privilege escalation (base-devel is intentionally omitted; sudo is the
  # only piece of it this install relies on)
  sudo

  # Filesystem tools (fsck for ext4 / FAT32)
  e2fsprogs
  dosfstools

  # Boot
  grub
  efibootmgr

  # Networking
  networkmanager
)

if [[ -n "${CPU_UCODE}" ]]; then
  BASE_PACKAGES+=("${CPU_UCODE}")
fi
BASE_PACKAGES+=("${FIRMWARE_PACKAGES[@]}")
BASE_PACKAGES+=("${GPU_PACKAGES[@]}")
BASE_PACKAGES+=("${AUDIO_PACKAGES[@]}")

log_info "Packages to be installed via pacstrap:"
printf '  - %s\n' "${BASE_PACKAGES[@]}"

# 6. Install
log_info "Running pacstrap on /mnt (this may take a few minutes)..."
pacstrap -K /mnt "${BASE_PACKAGES[@]}"
log_success "Base system packages installed successfully."

# 7. fstab
log_info "Generating fstab using persistent UUIDs..."
genfstab -U /mnt >> /mnt/etc/fstab
log_success "fstab generated. Contents:"
cat /mnt/etc/fstab

# ------------------------------------------------------------------------------
# Phase 6: System Configuration (arch-chroot)
# ------------------------------------------------------------------------------
log_title "Phase 6: System Configuration (Chroot)"

log_info "Configuring timezone, locale, keymap, initramfs, hostname, sudoers, services, audio, and GRUB bootloader in chroot..."

# The chroot script is stored in a variable and passed via `bash -c` (rather
# than piped on stdin) so that no command inside it can accidentally consume
# the remainder of this script. Variables are supplied through the environment
# by the arch-chroot call below; the heredoc is single-quoted so they are
# expanded inside the chroot, not here.
CHROOT_SCRIPT=$(cat <<'CHROOT_EOF'
# 1. Timezone & hardware clock
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# 2. Localization
#    Use fixed-string grep for matching and escape regex metacharacters for sed
#    so a locale such as "en_US.UTF-8" cannot match "en_USXUTF-8".
LOCALE_SED_ESCAPED=$(printf '%s' "${LOCALE}" | sed 's/[.[\*^$/]/\\&/g')
if grep -qF -- "#${LOCALE} " /etc/locale.gen; then
  sed -i "s/^#${LOCALE_SED_ESCAPED} /${LOCALE_SED_ESCAPED} /" /etc/locale.gen
elif ! grep -q -- "^${LOCALE_SED_ESCAPED} " /etc/locale.gen; then
  echo "${LOCALE} UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# 3. Console keymap
#    The initramfs built by pacstrap predates /etc/vconsole.conf and the keymap
#    hook embeds it at build time, so regenerate all presets afterwards.
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
mkinitcpio -P

# 4. Hostname & hosts file
echo "${TARGET_HOSTNAME}" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}
HOSTS_EOF

# 5. User account & sudo (wheel group via a drop-in, not /etc/sudoers)
useradd -m -G wheel -s /bin/bash "${USERNAME}"
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# 6. Services
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

# 7. Audio services
#    `--global` enables these user units for every user account without
#    needing an active login session (arch-chroot has no running systemd, so
#    a normal `systemctl --user enable` would fail here). This makes sure
#    PipeWire/WirePlumber come up automatically on first login instead of
#    requiring a manual `systemctl --user enable --now ...` afterwards.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# 8. GRUB bootloader
#    The primary install registers an NVRAM boot entry. The additional
#    --removable install places a copy at the UEFI fallback path
#    (EFI/BOOT/BOOTX64.EFI) for firmware that ignores or loses NVRAM entries.
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="${BOOTLOADER_ID}" --recheck
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck \
  || echo "[WARN] Fallback (--removable) GRUB install failed; primary NVRAM entry is still in place." >&2
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_EOF
)

arch-chroot /mnt /usr/bin/env \
  TIMEZONE="${TIMEZONE}" \
  LOCALE="${LOCALE}" \
  KEYMAP="${KEYMAP}" \
  TARGET_HOSTNAME="${TARGET_HOSTNAME}" \
  USERNAME="${USERNAME}" \
  BOOTLOADER_ID="${BOOTLOADER_ID}" \
  bash -euo pipefail -c "${CHROOT_SCRIPT}"

# Passwords are piped into chpasswd so they never appear on a command line.
log_info "Setting account passwords..."
printf '%s:%s\n' "root" "${ROOT_PASSWORD}" | arch-chroot /mnt chpasswd
printf '%s:%s\n' "${USERNAME}" "${USER_PASSWORD}" | arch-chroot /mnt chpasswd
log_success "Passwords securely configured for 'root' and '${USERNAME}'."

# ------------------------------------------------------------------------------
# Phase 7: Cleanup & Completion
# ------------------------------------------------------------------------------
log_title "Phase 7: Cleanup & Wrap-Up"

log_info "Unmounting all filesystems under /mnt..."
umount -R /mnt
swapoff -a 2>/dev/null || true

echo
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}     Arch Linux Minimal (Intel) Installation Completed Successfully!    ${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo
echo "System Summary:"
echo "  - Hostname : ${TARGET_HOSTNAME}"
echo "  - User     : ${USERNAME} (member of wheel / sudo enabled)"
echo "  - Timezone : ${TIMEZONE}"
echo "  - Locale   : ${LOCALE}"
echo "  - Keymap   : ${KEYMAP}"
echo "  - Kernel   : ${KERNEL}"
echo "  - Boot     : GRUB UEFI (/boot/efi, with removable fallback)"
echo "  - Network  : NetworkManager enabled"
echo "  - Time     : systemd-timesyncd enabled"
echo "  - Graphics : mesa, vulkan-intel, intel-media-driver (Intel iGPU)"
echo "  - Audio    : sof-firmware, alsa-ucm-conf, alsa-utils, PipeWire/WirePlumber (enabled)"
echo "  - Firmware : ${FIRMWARE_PACKAGES[*]}"
echo
echo "Not installed (add in a post-install step as needed):"
echo "  - Devel    : base-devel (needed for makepkg / AUR)"
echo "  - Editor   : nano or vim"
echo
echo "After first login, verify audio with:"
echo "  wpctl status        # confirm PipeWire sees the sink"
echo "  alsamixer            # press F6, select 'sof-hda-dsp', ensure Master/Speaker are unmuted"
echo
echo "This model also has a rotation sensor, IR camera, and webcam covered on its"
echo "ArchWiki page (Lenovo ThinkPad X1 Yoga (Gen 6)) if you install a DE later."
echo
echo "Next Steps:"
echo "  1. Remove your Arch Linux live USB drive."
echo "  2. Reboot your computer with: reboot"
echo "  3. Log in with user '${USERNAME}'."
echo
