#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Personal Installation Script (UEFI / GPT)
#
# Follows the ArchWiki Installation Guide with personal defaults:
#   - GPT layout: 1G EFI + ext4 root (remainder of disk); swap is zram
#     (zram-generator, zstd) instead of a swap partition
#   - GRUB (x86_64-efi) with a --removable fallback entry, 3 s menu timeout
#   - NetworkManager, systemd-timesyncd, PipeWire, Bluetooth, fstrim.timer
#   - Auto-detected CPU microcode and AMD/Intel GPU drivers
#   - pacman with Color + ParallelDownloads (optionally multilib)
#   - neovim (EDITOR), mpv, lazygit, man pages
#   - git (so this repo can be cloned after first boot to run niriInstall.sh)
#   - zsh as the regular user's login shell (root keeps bash for recovery),
#     with starship / eza / bat / fastfetch and these dotfiles pre-installed:
#       ~/.zshrc                <- ./config/.zshrc
#       ~/.config/starship.toml <- ./config/starship.toml
#     (skipped with a warning if ./config is missing, e.g. when the script is
#     run standalone via curl rather than from a checkout)
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  KEYMAP=de-latin1 EFI_SIZE=512M ./archInstall.sh
#
# Unattended runs: every interactive prompt can be pre-answered from the
# environment (see "Unattended answers" below). Example for a QEMU test VM:
#   DISK=vda TARGET_HOSTNAME=testvm TARGET_USER=abhinav \
#   USER_PASSWORD=pw ROOT_PASSWORD=pw CONFIRM_WIPE=YES ./archInstall.sh
# ==============================================================================

set -Eeuo pipefail

# Directory containing this script; bundled dotfiles live under ./config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-archlinux}"
EFI_SIZE="${EFI_SIZE:-1G}"                       # <N>M or <N>G
MIN_ROOT_SIZE="${MIN_ROOT_SIZE:-8G}"             # refuse disks that leave less than this for /
ZRAM_SIZE="${ZRAM_SIZE:-min(ram / 2, 4096)}"     # zram-generator expression, in MiB
BOOTLOADER_ID="${BOOTLOADER_ID:-GRUB}"
GRUB_TIMEOUT="${GRUB_TIMEOUT:-3}"                # seconds the GRUB menu is shown
ENABLE_MULTILIB="${ENABLE_MULTILIB:-no}"         # yes|no  (32-bit repo for Steam/Wine)
EDITOR_CMD="${EDITOR_CMD:-nvim}"                 # written to /etc/environment as EDITOR/VISUAL

# Unattended answers (leave empty to be prompted)
TARGET_HOSTNAME="${TARGET_HOSTNAME:-}"
TARGET_USER="${TARGET_USER:-}"
USER_PASSWORD="${USER_PASSWORD:-}"               # NOTE: env passwords may end up in shell history
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
DISK="${DISK:-}"                                 # e.g. nvme0n1 or /dev/sda
CONFIRM_WIPE="${CONFIRM_WIPE:-}"                 # set to YES to skip the wipe confirmation

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
# Colors only when stdout is a terminal (and NO_COLOR is unset), so
# `./archInstall.sh | tee install.log` does not fill the log with escape codes.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_INFO=$'\033[1;34m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_ERROR=$'\033[1;31m'
  COLOR_SUCCESS=$'\033[1;32m'
  COLOR_TITLE=$'\033[1;36m'
else
  COLOR_RESET="" COLOR_INFO="" COLOR_WARN="" COLOR_ERROR="" COLOR_SUCCESS="" COLOR_TITLE=""
fi

log_info()    { printf '%s[INFO]%s %s\n'  "${COLOR_INFO}"    "${COLOR_RESET}" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n'  "${COLOR_WARN}"    "${COLOR_RESET}" "$*"; }
log_error()   { printf '%s[ERROR]%s %s\n' "${COLOR_ERROR}"   "${COLOR_RESET}" "$*" >&2; }
log_success() { printf '%s[OK]%s %s\n'    "${COLOR_SUCCESS}" "${COLOR_RESET}" "$*"; }
log_title()   { printf '\n%s=== %s ===%s\n' "${COLOR_TITLE}" "$*" "${COLOR_RESET}"; }

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------
# Release the target: unmount everything under /mnt. Safe to call repeatedly.
release_target() {
  if mountpoint -q /mnt 2>/dev/null; then
    log_warn "Unmounting filesystems under /mnt..."
    umount -R /mnt 2>/dev/null || log_warn "Could not fully unmount /mnt; run manually: umount -R /mnt"
  fi
}

# On any failure: report the line, release the target, exit with the original
# status. `set -E` makes this fire inside functions and subshells too.
cleanup_on_err() {
  local exit_code=$? line="$1"
  trap - ERR INT TERM
  log_error "Installation failed on line ${line} with exit code ${exit_code}."
  release_target
  exit "${exit_code}"
}
trap 'cleanup_on_err $LINENO' ERR

# Ctrl-C / kill during pacstrap etc. must not leave /mnt mounted.
cleanup_on_signal() {
  trap - ERR INT TERM
  echo
  log_error "Interrupted."
  release_target
  exit 130
}
trap cleanup_on_signal INT TERM

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

# "512M" / "1G" -> bytes. Caller must have validated the format.
size_to_bytes() {
  local n="${1%[MG]}" unit="${1: -1}"
  case "${unit}" in
    M) echo $(( n * 1024 * 1024 )) ;;
    G) echo $(( n * 1024 * 1024 * 1024 )) ;;
  esac
}

# Escape a string for use in a basic regex (grep / sed pattern).
escape_regex() {
  printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g'
}

# Enable Color and ParallelDownloads in a pacman.conf; optionally multilib.
# $1 = path to pacman.conf, $2 = "yes" to also enable [multilib].
tune_pacman_conf() {
  local conf="$1" multilib="${2:-no}"
  sed -i -e 's/^#Color$/Color/' \
         -e 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "${conf}"
  if [[ "${multilib}" == "yes" ]]; then
    # Uncomment the two-line "[multilib]" + "Include = ..." block.
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "${conf}"
  fi
}

# ------------------------------------------------------------------------------
# Phase 1: Pre-flight Verification
# ------------------------------------------------------------------------------
log_title "Phase 1: Pre-flight Checks"

# 1. Root privileges
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be executed with root privileges. Run with: sudo ./archInstall.sh"
  exit 1
fi
log_success "Running as root."

# 2. Configuration validation. Everything here fails BEFORE the disk is touched;
#    a typo in TIMEZONE or LOCALE must not surface only inside the chroot.
if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" || "${TIMEZONE}" == *..* ]]; then
  log_error "Invalid TIMEZONE='${TIMEZONE}' (no such file under /usr/share/zoneinfo). Example: Europe/Berlin"
  exit 1
fi
if ! grep -qE "^#?$(escape_regex "${LOCALE}") " /etc/locale.gen; then
  log_error "Invalid LOCALE='${LOCALE}' (not listed in /etc/locale.gen). Example: en_US.UTF-8"
  exit 1
fi
for size_var in EFI_SIZE MIN_ROOT_SIZE; do
  if [[ ! "${!size_var}" =~ ^[0-9]+[MG]$ ]]; then
    log_error "Invalid ${size_var}='${!size_var}'. Use <number>M or <number>G, e.g. 512M or 1G."
    exit 1
  fi
done
if [[ ! "${GRUB_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  log_error "Invalid GRUB_TIMEOUT='${GRUB_TIMEOUT}'. Must be a whole number of seconds."
  exit 1
fi
ENABLE_MULTILIB="${ENABLE_MULTILIB,,}"
if [[ "${ENABLE_MULTILIB}" != "yes" && "${ENABLE_MULTILIB}" != "no" ]]; then
  log_error "Invalid ENABLE_MULTILIB='${ENABLE_MULTILIB}'. Allowed values: yes, no"
  exit 1
fi
if [[ -n "${CONFIRM_WIPE}" && "${CONFIRM_WIPE}" != "YES" ]]; then
  log_error "Invalid CONFIRM_WIPE='${CONFIRM_WIPE}'. Leave it empty to be prompted, or set exactly YES."
  exit 1
fi
log_success "Configuration options valid."

# 3. UEFI mode and firmware bitness
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

# 4. Console keymap (live session only; persisted to the target in Phase 6)
log_info "Applying keymap: ${KEYMAP}"
loadkeys "${KEYMAP}" 2>/dev/null || log_warn "Could not load keymap '${KEYMAP}', continuing with system default."

# 5. Internet connectivity
check_internet

# 6. System clock
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

# 7. Pacman mirrors (best-effort; falls back to the ISO default list)
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

# 8. Live-ISO pacman: parallel downloads speed up pacstrap considerably.
tune_pacman_conf /etc/pacman.conf no
log_success "Live pacman.conf: Color + ParallelDownloads enabled."

# ------------------------------------------------------------------------------
# Phase 2: User Inputs & Credential Gathering
# ------------------------------------------------------------------------------
log_title "Phase 2: System Credentials & Preferences"

# 1. Hostname
#    Per hostname(7): 1-63 chars, lowercase a-z, 0-9 and hyphen; must not
#    start or end with a hyphen.
HOSTNAME_FROM_ENV="${TARGET_HOSTNAME}"
while true; do
  if [[ -z "${TARGET_HOSTNAME}" ]]; then
    read -rp "Enter system hostname [${DEFAULT_HOSTNAME}]: " input_hostname
    TARGET_HOSTNAME="${input_hostname:-$DEFAULT_HOSTNAME}"
  fi
  if [[ "${TARGET_HOSTNAME}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    break
  fi
  log_warn "Invalid hostname '${TARGET_HOSTNAME}'. Use only lowercase letters, digits and hyphens (1-63 chars, no leading/trailing hyphen)."
  [[ -n "${HOSTNAME_FROM_ENV}" ]] && exit 1   # unattended: do not loop on a bad env value
  TARGET_HOSTNAME=""
done
log_info "Hostname set to: ${TARGET_HOSTNAME}"

# 2. Username
USER_FROM_ENV="${TARGET_USER}"
while true; do
  if [[ -z "${TARGET_USER}" ]]; then
    read -rp "Enter username for standard user account: " TARGET_USER
  fi
  if [[ -z "${TARGET_USER}" ]]; then
    log_warn "Username cannot be empty."
  elif [[ ! "${TARGET_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_warn "Invalid username '${TARGET_USER}'. Must begin with a lowercase letter or underscore, followed by lowercase letters, numbers, hyphens, or underscores."
  elif [[ "${TARGET_USER}" == "root" ]]; then
    log_warn "Username cannot be 'root'."
  else
    break
  fi
  [[ -n "${USER_FROM_ENV}" ]] && exit 1
  TARGET_USER=""
done
log_info "Username set to: ${TARGET_USER}"

# 3. Passwords (prompted unless supplied via USER_PASSWORD / ROOT_PASSWORD)
if [[ -z "${USER_PASSWORD}" ]]; then
  log_info "Configure password for regular user '${TARGET_USER}':"
  USER_PASSWORD=$(prompt_secure_password "user (${TARGET_USER})")
else
  log_info "Using USER_PASSWORD from environment."
fi
if [[ -z "${ROOT_PASSWORD}" ]]; then
  log_info "Configure password for system 'root':"
  ROOT_PASSWORD=$(prompt_secure_password "root")
else
  log_info "Using ROOT_PASSWORD from environment."
fi

# ------------------------------------------------------------------------------
# Phase 3: Disk Selection & Partitioning
# ------------------------------------------------------------------------------
log_title "Phase 3: Disk Selection & Partitioning"

# 1. Target disk selection
#    Minimum size = EFI + MIN_ROOT_SIZE; checked here so a too-small disk is
#    rejected before anything is wiped (sgdisk would otherwise fail half-way).
REQUIRED_BYTES=$(( $(size_to_bytes "${EFI_SIZE}") + $(size_to_bytes "${MIN_ROOT_SIZE}") ))

DISK_FROM_ENV="${DISK}"
if [[ -z "${DISK}" ]]; then
  echo "Available block devices:"
  lsblk -d -e 7,11 -o NAME,SIZE,TYPE,MODEL,TRAN
  echo
fi

while true; do
  if [[ -z "${DISK}" ]]; then
    read -rp "Enter target disk name to install Arch Linux on (e.g. nvme0n1, sda, vda): " DISK
  fi

  # Accept either "sda" or "/dev/sda".
  target_name="${DISK#/dev/}"
  DISK=""
  if [[ -z "${target_name}" ]]; then
    log_warn "Disk name cannot be empty."
  elif [[ ! -b "/dev/${target_name}" ]]; then
    log_error "Block device '/dev/${target_name}' not found."
  else
    DISK="/dev/${target_name}"

    # Refuse to wipe the disk backing the running live environment.
    LIVE_MEDIUM_DEV=""
    if mountpoint -q /run/archiso/bootmnt 2>/dev/null; then
      LIVE_MEDIUM_DEV=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
      LIVE_MEDIUM_DEV=$(lsblk -no PKNAME "${LIVE_MEDIUM_DEV}" 2>/dev/null || true)
    fi
    DISK_BYTES=$(blockdev --getsize64 "${DISK}")
    if [[ -n "${LIVE_MEDIUM_DEV}" && "/dev/${LIVE_MEDIUM_DEV}" == "${DISK}" ]]; then
      log_error "${DISK} is the live installation medium you are currently booted from. Choose a different disk."
      DISK=""
    elif (( DISK_BYTES < REQUIRED_BYTES )); then
      log_error "${DISK} is $(( DISK_BYTES / 1024 / 1024 / 1024 )) GiB; need at least ${EFI_SIZE} (EFI) + ${MIN_ROOT_SIZE} (root)."
      DISK=""
    else
      break
    fi
  fi
  [[ -n "${DISK_FROM_ENV}" ]] && exit 1
done

# 2. Destructive-action confirmation
echo
printf '%s%s\n' "${COLOR_WARN}" "========================================================================"
printf ' CRITICAL WARNING: ALL DATA ON %s WILL BE PERMANENTLY WIPED!\n' "${DISK}"
printf '%s%s\n' "========================================================================" "${COLOR_RESET}"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${DISK}"
echo
if [[ "${CONFIRM_WIPE}" == "YES" ]]; then
  log_warn "CONFIRM_WIPE=YES supplied; skipping confirmation prompt."
else
  read -rp "Type 'YES' in all capital letters to permanently wipe and format ${DISK}: " confirm_wipe
  if [[ "${confirm_wipe}" != "YES" ]]; then
    log_error "Installation cancelled by user. No disk modifications were made."
    exit 1
  fi
fi

# 3. Partition layout
PART_EFI=$(get_partition_device "${DISK}" 1)
PART_ROOT=$(get_partition_device "${DISK}" 2)

log_info "Target partition scheme:"
echo "  - EFI Boot Partition : ${PART_EFI} (${EFI_SIZE})"
echo "  - Root Partition     : ${PART_ROOT} (Remainder of disk)"
echo "  - Swap               : zram (${ZRAM_SIZE} MiB, zstd) - no swap partition"

# 4. Release anything still using the target disk
#    Children are processed deepest-first so stacked LVM / LUKS mappings are
#    torn down before their parents; otherwise wipefs reports "device busy".
log_info "Releasing existing mounts, swap and device-mapper layers on ${DISK}..."
swapoff -a 2>/dev/null || true
while read -r dev type; do
  [[ "${dev}" == "${DISK}" ]] && continue
  umount -l "${dev}" 2>/dev/null || true
  case "${type}" in
    crypt|lvm) dmsetup remove "${dev}" 2>/dev/null || true ;;
  esac
done < <(lsblk -lnpo NAME,TYPE "${DISK}" | tac)
udevadm settle

# 5. Wipe existing partition table and filesystem signatures
log_info "Wiping existing partition table and signatures on ${DISK}..."
wipefs -af "${DISK}"
sgdisk -Z "${DISK}"

# 6. Create GPT partitions
#    Type codes: ef00 = EFI System, 8304 = Linux x86-64 root (Discoverable
#    Partitions Specification), as used in the Installation Guide's example.
log_info "Creating GPT partition table..."
sgdisk -n 1:0:+"${EFI_SIZE}" -t 1:ef00 -c 1:"EFI System Partition" "${DISK}"
sgdisk -n 2:0:0              -t 2:8304 -c 2:"Linux Root"           "${DISK}"

# 7. Re-read the partition table and wait for device nodes
log_info "Informing kernel of partition changes..."
partprobe "${DISK}" 2>/dev/null || true
udevadm settle
for part in "${PART_EFI}" "${PART_ROOT}"; do
  if [[ ! -b "${part}" ]]; then
    log_error "Partition device ${part} did not appear after partitioning."
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Phase 4: Formatting & Mounting
# ------------------------------------------------------------------------------
log_title "Phase 4: Formatting & Mounting Partitions"

# 1. Format (with labels, so `lsblk -f` and recovery are self-explanatory)
log_info "Formatting EFI partition (${PART_EFI}) as FAT32..."
mkfs.fat -F32 -n EFI "${PART_EFI}"

log_info "Formatting Root partition (${PART_ROOT}) as ext4..."
mkfs.ext4 -F -L root "${PART_ROOT}"

# 2. Mount
log_info "Mounting filesystems to /mnt..."
mount "${PART_ROOT}" /mnt
mkdir -p /mnt/boot/efi
mount "${PART_EFI}" /mnt/boot/efi

log_success "Filesystems successfully mounted."
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "${DISK}"

# ------------------------------------------------------------------------------
# Phase 5: Hardware Detection & Base Installation (pacstrap)
# ------------------------------------------------------------------------------
log_title "Phase 5: Hardware Detection & Pacstrap"

# 1. CPU microcode
CPU_UCODE=""
if grep -qi "AuthenticAMD" /proc/cpuinfo; then
  log_info "AMD processor detected. Selected microcode: amd-ucode"
  CPU_UCODE="amd-ucode"
elif grep -qi "GenuineIntel" /proc/cpuinfo; then
  log_info "Intel processor detected. Selected microcode: intel-ucode"
  CPU_UCODE="intel-ucode"
else
  log_info "Unknown or virtual CPU vendor. Skipping microcode package."
fi

# 2. GPU drivers (AMD / Intel only; NVIDIA intentionally unsupported)
GPU_PACKAGES=()
GPU_INFO=$(lspci -nnk 2>/dev/null | grep -i -E "vga|3d|display" || true)
if echo "${GPU_INFO}" | grep -qi "AMD"; then
  log_info "AMD GPU detected. Installing mesa and vulkan-radeon."
  GPU_PACKAGES+=(mesa vulkan-radeon)
elif echo "${GPU_INFO}" | grep -qi "Intel"; then
  log_info "Intel GPU detected. Installing mesa, vulkan-intel, and intel-media-driver."
  GPU_PACKAGES+=(mesa vulkan-intel intel-media-driver)
else
  log_info "Generic or Virtual Machine GPU detected. Installing default mesa drivers."
  GPU_PACKAGES+=(mesa)
fi

# 3. Package list
BASE_PACKAGES=(
  # Core system
  base
  base-devel
  linux
  linux-firmware
  sof-firmware

  # Filesystem tools (fsck for ext4 / FAT32)
  e2fsprogs
  dosfstools

  # Boot
  grub
  efibootmgr

  # Swap (compressed RAM block device; configured in the chroot)
  zram-generator

  # Networking
  networkmanager

  # Bluetooth
  bluez
  bluez-utils

  # Audio
  pipewire
  pipewire-pulse
  wireplumber

  # Documentation
  man-db
  man-pages

  # Editor & everyday tools
  neovim                       # set as EDITOR/VISUAL in /etc/environment
  mpv
  lazygit

  # Needed after first boot to clone this repo and run niriInstall.sh
  git

  # Login shell for the regular user and what the bundled ~/.zshrc relies on
  # (bash stays installed; `base` depends on it)
  zsh
  starship                     # prompt
  eza                          # ls/ll/la/lt aliases
  bat                          # cat alias
  fastfetch                    # shown on shell startup
)

if [[ -n "${CPU_UCODE}" ]]; then
  BASE_PACKAGES+=("${CPU_UCODE}")
fi
BASE_PACKAGES+=("${GPU_PACKAGES[@]}")

log_info "Packages to be installed via pacstrap:"
printf '  - %s\n' "${BASE_PACKAGES[@]}"

# 4. Install
log_info "Running pacstrap on /mnt (this may take a few minutes)..."
pacstrap -K /mnt "${BASE_PACKAGES[@]}"
log_success "Base system packages installed successfully."

# 5. fstab
log_info "Generating fstab using persistent UUIDs..."
genfstab -U /mnt >> /mnt/etc/fstab
log_success "fstab generated. Contents:"
cat /mnt/etc/fstab

# 6. Target pacman.conf (Color, ParallelDownloads, optional multilib)
tune_pacman_conf /mnt/etc/pacman.conf "${ENABLE_MULTILIB}"
log_success "Target pacman.conf tuned (multilib: ${ENABLE_MULTILIB})."

# ------------------------------------------------------------------------------
# Phase 6: System Configuration (arch-chroot)
# ------------------------------------------------------------------------------
log_title "Phase 6: System Configuration (Chroot)"

log_info "Configuring timezone, locale, keymap, initramfs, hostname, user, zram, services and GRUB in chroot..."

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

# 5. System-wide default editor
cat <<ENV_EOF > /etc/environment
EDITOR=${EDITOR_CMD}
VISUAL=${EDITOR_CMD}
ENV_EOF

# 6. User account & sudo (wheel group via a drop-in, not /etc/sudoers)
#    zsh is the login shell (/usr/bin/zsh is the path listed in /etc/shells;
#    /bin is a symlink to /usr/bin on Arch). Root intentionally keeps bash so a
#    broken ~/.zshrc can never lock you out of recovery.
useradd -m -G wheel -s /usr/bin/zsh "${TARGET_USER}"
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# 7. zram swap (zram-generator is a systemd generator; nothing to enable)
#    Sysctl values follow the ArchWiki zram recommendations for a swap device
#    that is far faster than disk.
cat <<ZRAM_EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = zstd
ZRAM_EOF
cat <<SYSCTL_EOF > /etc/sysctl.d/99-vm-zram-parameters.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
SYSCTL_EOF

# 8. Services
systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable bluetooth
systemctl enable fstrim.timer

# 9. GRUB bootloader
#    The primary install registers an NVRAM boot entry. The additional
#    --removable install places a copy at the UEFI fallback path
#    (EFI/BOOT/BOOTX64.EFI) for firmware that ignores or loses NVRAM entries.
sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=${GRUB_TIMEOUT}/" /etc/default/grub
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
  TARGET_USER="${TARGET_USER}" \
  EDITOR_CMD="${EDITOR_CMD}" \
  ZRAM_SIZE="${ZRAM_SIZE}" \
  BOOTLOADER_ID="${BOOTLOADER_ID}" \
  GRUB_TIMEOUT="${GRUB_TIMEOUT}" \
  bash -euo pipefail -c "${CHROOT_SCRIPT}"

# Passwords are piped into chpasswd so they never appear on a command line,
# and are dropped from this shell's memory immediately afterwards.
log_info "Setting account passwords..."
printf '%s:%s\n' "root" "${ROOT_PASSWORD}" | arch-chroot /mnt chpasswd
printf '%s:%s\n' "${TARGET_USER}" "${USER_PASSWORD}" | arch-chroot /mnt chpasswd
unset USER_PASSWORD ROOT_PASSWORD
log_success "Passwords securely configured for 'root' and '${TARGET_USER}'."

# ------------------------------------------------------------------------------
# Phase 7: User Dotfiles (zsh + starship)
# ------------------------------------------------------------------------------
log_title "Phase 7: User Dotfiles"

# Installing ~/.zshrc now means the first login goes straight to a configured
# shell instead of the zsh-newuser-install wizard. This is best-effort: a
# missing dotfile must never abort an otherwise successful disk install.
USER_HOME_MNT="/mnt/home/${TARGET_USER}"
DOTFILES_INSTALLED="no"
if [[ -f "${SCRIPT_DIR}/config/.zshrc" && -f "${SCRIPT_DIR}/config/starship.toml" ]]; then
  install -D -m 0644 "${SCRIPT_DIR}/config/.zshrc"        "${USER_HOME_MNT}/.zshrc"
  install -D -m 0644 "${SCRIPT_DIR}/config/starship.toml" "${USER_HOME_MNT}/.config/starship.toml"
  # The UID/GID only exist inside the target system, so chown from the chroot.
  # "user:" (empty group) means the user's login group, whatever it is named.
  arch-chroot /mnt chown -R "${TARGET_USER}:" "/home/${TARGET_USER}/.zshrc" "/home/${TARGET_USER}/.config"
  DOTFILES_INSTALLED="yes"
  log_success "Installed ~/.zshrc and ~/.config/starship.toml for '${TARGET_USER}'."
else
  log_warn "config/.zshrc or config/starship.toml not found next to this script; skipping dotfiles."
  log_warn "zsh will show its first-run wizard on login (press 'q' to skip). niriInstall.sh can install them later."
fi

# ------------------------------------------------------------------------------
# Phase 8: Cleanup & Completion
# ------------------------------------------------------------------------------
log_title "Phase 8: Cleanup & Wrap-Up"

log_info "Unmounting all filesystems under /mnt..."
umount -R /mnt

echo
printf '%s%s%s\n' "${COLOR_SUCCESS}" "========================================================================" "${COLOR_RESET}"
printf '%s%s%s\n' "${COLOR_SUCCESS}" "           Arch Linux Installation Completed Successfully!              " "${COLOR_RESET}"
printf '%s%s%s\n' "${COLOR_SUCCESS}" "========================================================================" "${COLOR_RESET}"
echo
echo "System Summary:"
echo "  - Hostname  : ${TARGET_HOSTNAME}"
echo "  - User      : ${TARGET_USER} (member of wheel / sudo enabled, shell: zsh)"
echo "  - Timezone  : ${TIMEZONE}"
echo "  - Locale    : ${LOCALE}"
echo "  - Keymap    : ${KEYMAP}"
echo "  - Disk      : ${DISK} -> ${PART_EFI} (EFI, ${EFI_SIZE}) + ${PART_ROOT} (ext4 root)"
echo "  - Swap      : zram (${ZRAM_SIZE} MiB, zstd)"
echo "  - Boot      : GRUB UEFI (/boot/efi, removable fallback, ${GRUB_TIMEOUT}s timeout)"
echo "  - Network   : NetworkManager enabled"
echo "  - Bluetooth : bluez enabled"
echo "  - Time      : systemd-timesyncd enabled"
echo "  - Audio     : PipeWire / WirePlumber"
echo "  - Editor    : ${EDITOR_CMD} (EDITOR/VISUAL in /etc/environment)"
echo "  - pacman    : Color, ParallelDownloads=5, multilib=${ENABLE_MULTILIB}"
if [[ "${DOTFILES_INSTALLED}" == "yes" ]]; then
  echo "  - Shell     : zsh + starship (~/.zshrc, ~/.config/starship.toml installed)"
else
  echo "  - Shell     : zsh + starship (dotfiles NOT installed; see warning above)"
fi
echo
echo "Next Steps:"
echo "  1. Remove your Arch Linux live USB drive."
echo "  2. Reboot your computer with: reboot"
echo "  3. Log in with user '${TARGET_USER}'."
echo "  4. For the niri desktop: clone this repo and run ./niriInstall.sh"
echo
