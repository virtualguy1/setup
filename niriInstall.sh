#!/usr/bin/env bash
# ==============================================================================
# Niri Post-Install Script for Arch Linux
#
# Run this as your regular user AFTER a base install (e.g. archInstall.sh) and
# first login. It sets up a complete niri desktop following Tony's guide
# (https://tonybtw.com/tutorial/niri/), updated for the current state of the
# Arch repos and Noctalia v5:
#
#   - niri (scrollable-tiling Wayland compositor) + xwayland-satellite
#   - Noctalia (bar, launcher, notifications, lock screen, wallpaper, OSD)
#   - alacritty, swaybg, JetBrainsMono Nerd Font
#   - Helium browser (AUR: helium-browser-bin) via yay, bootstrapped if missing
#   - xdg-desktop-portal (gnome + gtk) for screen sharing / file pickers
#   - ~/.config/niri/config.kdl  <- copied from ./config/niri/config.kdl
#     (tutorial keybinds/look + Noctalia integration; edit that file to customise)
#   - ~/.config/noctalia/config.toml  <- copied from ./config/noctalia/config.toml
#     (tutorial bar layout & theme; font/theme/wallpaper dir filled from env vars)
#   - ~/.config/alacritty/alacritty.toml  <- copied from ./config/alacritty/alacritty.toml
#     (font filled from MONO_FONT)
#   - Optional: auto-start niri when logging in on TTY1
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  AUTOSTART_NIRI=no INSTALL_BROWSER=no ./niriInstall.sh
# ==============================================================================

set -euo pipefail

# Directory containing this script; bundled config files live under ./config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
INSTALL_BROWSER="${INSTALL_BROWSER:-yes}"        # yes|no  (Helium browser from the AUR)
BROWSER_PKG="${BROWSER_PKG:-helium-browser-bin}" # AUR package name
AUR_HELPER="${AUR_HELPER:-yay}"                  # yay|paru (bootstrapped from the AUR if missing)
AUTOSTART_NIRI="${AUTOSTART_NIRI:-ask}"          # yes|no|ask  (start niri-session on TTY1 login)
OVERWRITE_CONFIGS="${OVERWRITE_CONFIGS:-ask}"    # yes|no|ask  (replace existing niri/noctalia/alacritty configs; backups are made)
WALLPAPER_DIR="${WALLPAPER_DIR:-${HOME}/Pictures/Wallpapers}"
NOCTALIA_THEME="${NOCTALIA_THEME:-Tokyo-Night}"  # Ayu|Catppuccin|Dracula|Eldritch|Gruvbox|Kanagawa|Noctalia|Nord|Rosé Pine|Tokyo-Night
UI_FONT="${UI_FONT:-JetBrainsMono Nerd Font Propo}"
MONO_FONT="${MONO_FONT:-JetBrainsMono Nerd Font}"

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

trap 'log_error "Script failed on line $LINENO."' ERR

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# ask_yes_no "<prompt>" "<default y|n>" -> returns 0 for yes, 1 for no
ask_yes_no() {
  local prompt="$1" default="$2" answer hint
  if [[ "${default}" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -rp "${prompt} ${hint}: " answer
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]$ ]]
}

# resolve_choice "<yes|no|ask>" "<prompt>" "<default y|n>" -> 0 = yes, 1 = no
resolve_choice() {
  local value="$1" prompt="$2" default="$3"
  case "${value}" in
    yes|YES|y|Y) return 0 ;;
    no|NO|n|N)   return 1 ;;
    *)           ask_yes_no "${prompt}" "${default}" ;;
  esac
}

# Move an existing file aside with a timestamp suffix.
backup_file() {
  local file="$1"
  if [[ -e "${file}" ]]; then
    local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    mv "${file}" "${backup}"
    log_warn "Existing $(basename "${file}") backed up to ${backup}"
  fi
}

# Decide whether a config file should be (re)written.
should_write_config() {
  local file="$1"
  if [[ ! -e "${file}" ]]; then
    return 0
  fi
  if resolve_choice "${OVERWRITE_CONFIGS}" "Replace existing ${file}? (a backup will be kept)" "n"; then
    backup_file "${file}"
    return 0
  fi
  log_info "Keeping existing ${file}"
  return 1
}

# ------------------------------------------------------------------------------
# Phase 1: Pre-flight Checks
# ------------------------------------------------------------------------------
log_title "Phase 1: Pre-flight Checks"

if [[ "${EUID}" -eq 0 ]]; then
  log_error "Do not run this script as root. Run it as your normal user; it will call sudo when needed."
  exit 1
fi
log_success "Running as user '${USER}'."

if ! command -v pacman &>/dev/null; then
  log_error "pacman not found. This script is for Arch Linux."
  exit 1
fi

if ! command -v sudo &>/dev/null; then
  log_error "sudo is not installed. Install it as root first: pacman -S sudo"
  exit 1
fi

log_info "Checking sudo access (you may be prompted for your password)..."
if ! sudo -v; then
  log_error "sudo authentication failed. Is '${USER}' in the wheel group?"
  exit 1
fi
log_success "sudo access verified."

log_info "Verifying internet connection..."
if ! (ping -c 1 -W 3 archlinux.org &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null); then
  log_error "No internet connection. Connect first (e.g. nmtui) and re-run."
  exit 1
fi
log_success "Internet connectivity active."

IS_LAPTOP="no"
if compgen -G "/sys/class/power_supply/BAT*" >/dev/null; then
  IS_LAPTOP="yes"
  log_info "Battery detected: laptop extras (brightness, power profiles) will be installed."
fi

# ------------------------------------------------------------------------------
# Phase 2: Package Installation
# ------------------------------------------------------------------------------
log_title "Phase 2: Package Installation"

PACKAGES=(
  # Compositor
  niri
  xwayland-satellite           # X11 app support; niri auto-launches it when installed

  # Desktop shell (bar, launcher, notifications, lock screen, wallpaper, OSD)
  noctalia

  # Tutorial extras
  alacritty                    # terminal
  swaybg                       # manual wallpaper fallback
  ttf-jetbrains-mono-nerd

  # Portals (screen sharing, file pickers). niri ships a portals.conf preferring gnome;gtk.
  xdg-desktop-portal
  xdg-desktop-portal-gnome
  xdg-desktop-portal-gtk

  # Quality of life
  wl-clipboard                 # wl-copy / wl-paste
  playerctl                    # media keys
  xdg-user-dirs                # creates ~/Pictures etc. (screenshots go there)
  xdg-utils
  noto-fonts
  noto-fonts-emoji
  polkit
)

AUR_PACKAGES=()
if [[ "${INSTALL_BROWSER}" =~ ^[Yy] ]]; then
  AUR_PACKAGES+=("${BROWSER_PKG}")
  PACKAGES+=(git base-devel)   # needed to build the AUR helper
fi

if [[ "${IS_LAPTOP}" == "yes" ]]; then
  PACKAGES+=(brightnessctl upower power-profiles-daemon)
fi

log_info "Packages to install:"
printf '  - %s\n' "${PACKAGES[@]}"

log_info "Synchronizing package databases and installing (this may take a while)..."
sudo pacman -Syu --needed --noconfirm "${PACKAGES[@]}"
log_success "Packages installed."

if [[ "${IS_LAPTOP}" == "yes" ]]; then
  sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null \
    || log_warn "Could not enable power-profiles-daemon; continuing."
fi

# ------------------------------------------------------------------------------
# Phase 2b: AUR packages (Helium browser)
# ------------------------------------------------------------------------------
if [[ ${#AUR_PACKAGES[@]} -gt 0 ]]; then
  log_title "Phase 2b: AUR Packages"

  if ! command -v "${AUR_HELPER}" &>/dev/null; then
    log_info "AUR helper '${AUR_HELPER}' not found. Bootstrapping ${AUR_HELPER}-bin from the AUR..."
    AUR_BUILD_DIR=$(mktemp -d)
    git clone --depth 1 "https://aur.archlinux.org/${AUR_HELPER}-bin.git" "${AUR_BUILD_DIR}/${AUR_HELPER}-bin"
    (cd "${AUR_BUILD_DIR}/${AUR_HELPER}-bin" && makepkg -si --noconfirm --needed)
    rm -rf "${AUR_BUILD_DIR}"
    log_success "${AUR_HELPER} installed."
  else
    log_success "AUR helper '${AUR_HELPER}' already present."
  fi

  log_info "AUR packages to install:"
  printf '  - %s\n' "${AUR_PACKAGES[@]}"
  "${AUR_HELPER}" -S --needed --noconfirm "${AUR_PACKAGES[@]}"
  log_success "AUR packages installed."
fi

# ------------------------------------------------------------------------------
# Phase 3: Directories
# ------------------------------------------------------------------------------
log_title "Phase 3: User Directories"

xdg-user-dirs-update 2>/dev/null || true
mkdir -p "${HOME}/.config/niri" \
         "${HOME}/.config/noctalia" \
         "${HOME}/.config/alacritty" \
         "${HOME}/Pictures/Screenshots" \
         "${WALLPAPER_DIR}"
log_success "Directories ready (wallpapers: ${WALLPAPER_DIR})."

# ------------------------------------------------------------------------------
# Phase 4: niri configuration
# ------------------------------------------------------------------------------
log_title "Phase 4: niri Configuration"

NIRI_CONFIG="${HOME}/.config/niri/config.kdl"
NIRI_CONFIG_SRC="${SCRIPT_DIR}/config/niri/config.kdl"

if [[ ! -f "${NIRI_CONFIG_SRC}" ]]; then
  log_error "Bundled niri config not found: ${NIRI_CONFIG_SRC}"
  log_error "Run this script from a full checkout of the repository (config/niri/config.kdl must exist)."
  exit 1
fi

if should_write_config "${NIRI_CONFIG}"; then
  # config/niri/config.kdl is niri's default config with the tutorial's changes
  # applied, plus Noctalia's recommended niri integration. Edit that file in the
  # repo to change the defaults; niri reloads the installed copy on save.
  install -m 0644 "${NIRI_CONFIG_SRC}" "${NIRI_CONFIG}"
  log_success "Installed ${NIRI_CONFIG_SRC} -> ${NIRI_CONFIG}"

  if command -v niri &>/dev/null; then
    if niri validate -c "${NIRI_CONFIG}" >/dev/null 2>&1; then
      log_success "niri config validated."
    else
      log_warn "niri reported a problem with the installed config:"
      niri validate -c "${NIRI_CONFIG}" || true
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Phase 5: Noctalia configuration
# ------------------------------------------------------------------------------
log_title "Phase 5: Noctalia Configuration"

NOCTALIA_CONFIG="${HOME}/.config/noctalia/config.toml"
NOCTALIA_CONFIG_SRC="${SCRIPT_DIR}/config/noctalia/config.toml"

if [[ ! -f "${NOCTALIA_CONFIG_SRC}" ]]; then
  log_error "Bundled Noctalia config not found: ${NOCTALIA_CONFIG_SRC}"
  log_error "Run this script from a full checkout of the repository (config/noctalia/config.toml must exist)."
  exit 1
fi

if should_write_config "${NOCTALIA_CONFIG}"; then
  # config/noctalia/config.toml is the tutorial's (v4) settings.json translated
  # to Noctalia v5 TOML. It contains __UI_FONT__, __THEME__ and __WALLPAPER_DIR__
  # placeholders which are filled from the variables at the top of this script.
  install -m 0644 "${NOCTALIA_CONFIG_SRC}" "${NOCTALIA_CONFIG}"
  sed -i \
    -e "s|__UI_FONT__|${UI_FONT}|g" \
    -e "s|__THEME__|${NOCTALIA_THEME}|g" \
    -e "s|__WALLPAPER_DIR__|${WALLPAPER_DIR}|g" \
    "${NOCTALIA_CONFIG}"
  log_success "Installed ${NOCTALIA_CONFIG_SRC} -> ${NOCTALIA_CONFIG}"
fi

# ------------------------------------------------------------------------------
# Phase 6: Alacritty configuration
# ------------------------------------------------------------------------------
log_title "Phase 6: Alacritty Configuration"

ALACRITTY_CONFIG="${HOME}/.config/alacritty/alacritty.toml"
ALACRITTY_CONFIG_SRC="${SCRIPT_DIR}/config/alacritty/alacritty.toml"

if [[ ! -f "${ALACRITTY_CONFIG_SRC}" ]]; then
  log_error "Bundled Alacritty config not found: ${ALACRITTY_CONFIG_SRC}"
  log_error "Run this script from a full checkout of the repository (config/alacritty/alacritty.toml must exist)."
  exit 1
fi

if should_write_config "${ALACRITTY_CONFIG}"; then
  # config/alacritty/alacritty.toml contains a __MONO_FONT__ placeholder which
  # is filled from the MONO_FONT variable at the top of this script.
  install -m 0644 "${ALACRITTY_CONFIG_SRC}" "${ALACRITTY_CONFIG}"
  sed -i -e "s|__MONO_FONT__|${MONO_FONT}|g" "${ALACRITTY_CONFIG}"
  log_success "Installed ${ALACRITTY_CONFIG_SRC} -> ${ALACRITTY_CONFIG}"
fi

# ------------------------------------------------------------------------------
# Phase 7: Start niri automatically on TTY1 (optional)
# ------------------------------------------------------------------------------
log_title "Phase 7: Session Autostart"

BASH_PROFILE="${HOME}/.bash_profile"
AUTOSTART_MARKER="# >>> niriInstall.sh: start niri on TTY1 >>>"

if resolve_choice "${AUTOSTART_NIRI}" "Start niri automatically when you log in on TTY1?" "y"; then
  if [[ -f "${BASH_PROFILE}" ]] && grep -qF "${AUTOSTART_MARKER}" "${BASH_PROFILE}"; then
    log_info "TTY1 autostart already present in ${BASH_PROFILE}"
  else
    # If no .bash_profile exists yet, keep bash sourcing ~/.bashrc for login shells.
    if [[ ! -f "${BASH_PROFILE}" ]]; then
      printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n\n' > "${BASH_PROFILE}"
    fi
    cat >> "${BASH_PROFILE}" <<'PROFILE_EOF'

# >>> niriInstall.sh: start niri on TTY1 >>>
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec niri-session
fi
# <<< niriInstall.sh <<<
PROFILE_EOF
    log_success "TTY1 autostart added to ${BASH_PROFILE}"
  fi
else
  log_info "Skipping autostart. Start niri manually with: niri-session"
fi

# ------------------------------------------------------------------------------
# Phase 8: Summary
# ------------------------------------------------------------------------------
log_title "Phase 8: Done"

echo
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}                 Niri Desktop Setup Completed Successfully!             ${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo
echo "Installed:"
echo "  - niri + xwayland-satellite      (compositor)"
echo "  - noctalia                       (bar / launcher / notifications / lock / wallpaper)"
echo "  - alacritty, swaybg"
[[ "${INSTALL_BROWSER}" =~ ^[Yy] ]] && echo "  - ${BROWSER_PKG} (AUR, via ${AUR_HELPER})"
echo "  - JetBrainsMono Nerd Font, Noto fonts, xdg-desktop-portal (gnome/gtk)"
[[ "${IS_LAPTOP}" == "yes" ]] && echo "  - brightnessctl, upower, power-profiles-daemon (laptop)"
echo
echo "Config files:"
echo "  - ${NIRI_CONFIG}"
echo "  - ${NOCTALIA_CONFIG}"
echo "  - ${ALACRITTY_CONFIG}"
echo
echo "Keybinds (Mod = Super):"
echo "  Mod+Return / Mod+T   Terminal            Mod+Space      Noctalia launcher"
echo "  Mod+N                Noctalia control center"
echo "  Mod+Q                Close window        Mod+O          Overview"
echo "  Mod+H/J/K/L          Focus               Mod+Ctrl+HJKL  Move"
echo "  Mod+1-9              Workspace           Mod+Shift+1-9  Move to workspace"
echo "  Mod+F / Mod+Shift+F  Maximize / Fullscreen               Mod+S  Screenshot"
echo "  Super+Alt+L          Lock                Mod+Shift+E    Quit niri"
echo "  Mod+Shift+/          Show all hotkeys"
echo
echo "Next Steps:"
echo "  1. Put some wallpapers in: ${WALLPAPER_DIR}"
echo "  2. Start niri: log out and back in on TTY1 (if autostart enabled), or run: niri-session"
echo "  3. Multi-monitor? Run 'niri msg outputs' and edit the output block in config.kdl."
echo "  4. Noctalia settings UI: Mod+N -> gear icon, or run: noctalia msg settings-toggle"
echo
