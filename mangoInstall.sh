#!/usr/bin/env bash
# ==============================================================================
# MangoWC / MangoWM Post-Install Script for Arch Linux
#
# Run this as your regular user AFTER a base install (e.g. archInstall.sh) and
# first login. It sets up a complete Mango + Noctalia desktop:
#
#   - Mango (mangowm / mangowc: lightweight wlroots+scenefx Wayland compositor)
#     via the AUR (default: mangowm-git)
#   - Noctalia shell (bar, launcher, notifications, lock screen, wallpaper, OSD)
#     from the official Arch [extra] repository
#   - Noctalia Greeter + greetd as the graphical login screen (AUR: noctalia-greeter)
#   - Alacritty terminal, JetBrainsMono Nerd Font & Bibata cursor theme
#   - PipeWire audio stack (pipewire, pipewire-pulse, wireplumber)
#   - Portals (xdg-desktop-portal, xdg-desktop-portal-wlr, xdg-desktop-portal-gtk)
#   - XWayland for seamless X11 applications
#   - Desktop wayland session entry (/usr/share/wayland-sessions/mango.desktop)
#     (shipped by the package; created only if missing)
#   - ~/.config/mango/config.conf      <- copied from ./config/mango/config.conf
#     (SceneFX blur/shadows tuned for Noctalia + IPC keybinds & window controls)
#   - ~/.config/noctalia/config.toml   <- copied from ./config/noctalia/config.mango.toml
#     (font/theme/wallpaper dir + Mango layer shadow optimizations)
#   - ~/.config/alacritty/alacritty.toml <- copied from ./config/alacritty/alacritty.toml
#   - Bundled wallpapers from ./config/Wallpapers copied to $WALLPAPER_DIR
#   - /etc/greetd/config.toml pointing at noctalia-greeter-session (Mango as
#     pre-selected default session); greetd enabled for next boot
#   - Optional passwordless appearance sync from Noctalia to Noctalia Greeter
#   - Fallback: auto-start Mango on TTY1 login if you skip the greeter
#
# Docs:
#   Mango:            https://mangowm.github.io/docs
#   Noctalia Shell:   https://docs.noctalia.dev/noctalia/
#   Noctalia Greeter: https://docs.noctalia.dev/greeter/
#   Noctalia + Mango: https://docs.noctalia.dev/noctalia/compositor-settings/mango/
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  INSTALL_GREETER=no INSTALL_BROWSER=no ./mangoInstall.sh
# ==============================================================================

set -euo pipefail

# Directory containing this script; bundled config files live under ./config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
AUR_HELPER="${AUR_HELPER:-yay}"                          # yay|paru (bootstrapped from the AUR if missing)
MANGO_PKG="${MANGO_PKG:-mangowm-git}"                    # mangowm-git | mangowm (AUR package for the compositor)
INSTALL_GREETER="${INSTALL_GREETER:-yes}"                # yes|no|ask (noctalia-greeter + greetd login screen)
GREETER_PKG="${GREETER_PKG:-noctalia-greeter}"           # noctalia-greeter (tagged) | noctalia-greeter-git
GREETER_PASSWORDLESS_SYNC="${GREETER_PASSWORDLESS_SYNC:-ask}" # yes|no|ask (let $USER sync Noctalia look to greeter without password)
INSTALL_BROWSER="${INSTALL_BROWSER:-yes}"                # yes|no|ask (browser from the AUR)
BROWSER_PKG="${BROWSER_PKG:-helium-browser-bin}"         # AUR package name
CURSOR_PKG="${CURSOR_PKG:-bibata-cursor-theme-bin}"      # AUR cursor theme (referenced by cursor_theme= in config.conf)
AUTOSTART_MANGO="${AUTOSTART_MANGO:-ask}"                # yes|no|ask (TTY1 autostart; only offered when greeter is skipped)
OVERWRITE_CONFIGS="${OVERWRITE_CONFIGS:-ask}"            # yes|no|ask (replace existing configs; backups are made)
WALLPAPER_DIR="${WALLPAPER_DIR:-${HOME}/Pictures/Wallpapers}"
NOCTALIA_THEME="${NOCTALIA_THEME:-Tokyo-Night}"          # Ayu|Catppuccin|Dracula|Eldritch|Gruvbox|Kanagawa|Noctalia|Nord|Rosé Pine|Tokyo-Night
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
# Falls back to the default when stdin is not a terminal (piped / CI runs).
ask_yes_no() {
  local prompt="$1" default="$2" answer hint
  if [[ "${default}" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ ! -t 0 ]]; then
    log_info "${prompt} ${hint}: (non-interactive, using default '${default}')"
    answer="${default}"
  else
    read -rp "${prompt} ${hint}: " answer
    answer="${answer:-$default}"
  fi
  [[ "${answer}" =~ ^[Yy]$ ]]
}

# Escape a string for use as the replacement side of a sed s|..|..| expression.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# Keep the sudo timestamp fresh for the lifetime of the script so long AUR
# builds do not re-prompt for the password.
start_sudo_keepalive() {
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
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

# Abort with a clear message if a bundled config file is missing.
require_bundled() {
  local src="$1"
  if [[ ! -f "${src}" ]]; then
    log_error "Bundled config not found: ${src}"
    log_error "Run this script from a full checkout of the repository (${src#"${SCRIPT_DIR}"/} must exist)."
    exit 1
  fi
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
start_sudo_keepalive

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

# Decide early whether the greeter is wanted so package lists are complete.
WANT_GREETER="no"
if resolve_choice "${INSTALL_GREETER}" "Install Noctalia Greeter + greetd as the login screen?" "y"; then
  WANT_GREETER="yes"
fi

WANT_BROWSER="no"
if resolve_choice "${INSTALL_BROWSER}" "Install the ${BROWSER_PKG} web browser from the AUR?" "y"; then
  WANT_BROWSER="yes"
fi

# ------------------------------------------------------------------------------
# Phase 2: Package Installation (official Arch repos)
# ------------------------------------------------------------------------------
log_title "Phase 2: Package Installation"

PACKAGES=(
  # Build tools for AUR packages (mangowm, noctalia-greeter, etc.)
  git
  base-devel

  # Desktop shell (Noctalia v5+ is available in official Arch [extra] repository)
  noctalia

  # Terminal & fonts
  alacritty
  ttf-jetbrains-mono-nerd
  noto-fonts
  noto-fonts-emoji

  # XWayland support for X11 applications
  xorg-xwayland

  # Audio: a base install has no sound server. Noctalia's volume/media widgets
  # talk to PipeWire/WirePlumber, and xdg-desktop-portal-wlr needs PipeWire for
  # screen sharing (https://mangowm.github.io/docs/configuration/xdg-portals).
  pipewire
  pipewire-pulse
  pipewire-alsa
  wireplumber

  # Portals: wlr portal for wlroots screen sharing/recording; gtk for file dialogs
  # (Mango ships /usr/share/xdg-desktop-portal/mango-portals.conf to select them)
  xdg-desktop-portal
  xdg-desktop-portal-wlr
  xdg-desktop-portal-gtk

  # Desktop essentials & audio control
  wl-clipboard                 # wl-copy / wl-paste
  playerctl                    # media key controls
  xdg-user-dirs                # default standard directories
  xdg-utils
  polkit                       # polkit agent authentication
)

if [[ "${WANT_GREETER}" == "yes" ]]; then
  PACKAGES+=(
    greetd                     # display manager daemon; noctalia-greeter runs as its default_session
    accountsservice            # user avatar integration for login screen
  )
fi

if [[ "${IS_LAPTOP}" == "yes" ]]; then
  PACKAGES+=(brightnessctl upower power-profiles-daemon)
fi

log_info "Packages to install from official repos:"
printf '  - %s\n' "${PACKAGES[@]}"

log_info "Synchronizing package databases and installing packages..."
sudo pacman -Syu --needed --noconfirm "${PACKAGES[@]}"
log_success "Official repository packages installed."

if [[ "${IS_LAPTOP}" == "yes" ]]; then
  sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null \
    || log_warn "Could not enable power-profiles-daemon; continuing."
fi

# ------------------------------------------------------------------------------
# Phase 2b: AUR Packages (Mango Compositor, Noctalia Greeter, Browser)
# ------------------------------------------------------------------------------
log_title "Phase 2b: AUR Packages"

AUR_PACKAGES=("${MANGO_PKG}" "${CURSOR_PKG}")
if [[ "${WANT_GREETER}" == "yes" ]]; then
  AUR_PACKAGES+=("${GREETER_PKG}")
fi
if [[ "${WANT_BROWSER}" == "yes" ]]; then
  AUR_PACKAGES+=("${BROWSER_PKG}")
fi

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

# Verify the compositor binary is installed (both mangowm and mangowm-git ship /usr/bin/mango)
MANGO_BIN="$(command -v mango || true)"
if [[ -z "${MANGO_BIN}" ]]; then
  log_error "'mango' executable not found on PATH after installing ${MANGO_PKG}."
  exit 1
fi
log_success "Mango executable found: ${MANGO_BIN}"

# ------------------------------------------------------------------------------
# Phase 3: User Directories & Session Setup
# ------------------------------------------------------------------------------
log_title "Phase 3: User Directories & Wayland Session Entry"

xdg-user-dirs-update 2>/dev/null || true
mkdir -p "${HOME}/.config/mango" \
         "${HOME}/.config/noctalia" \
         "${HOME}/.config/alacritty" \
         "${HOME}/Pictures/Screenshots" \
         "${WALLPAPER_DIR}"
log_success "Directories ready (wallpapers: ${WALLPAPER_DIR})."

# Seed the wallpaper directory with the bundled images (never overwrite user files)
WALLPAPER_SRC_DIR="${SCRIPT_DIR}/config/Wallpapers"
if compgen -G "${WALLPAPER_SRC_DIR}/*" >/dev/null; then
  copied=0
  for src in "${WALLPAPER_SRC_DIR}"/*; do
    [[ -f "${src}" ]] || continue
    dest="${WALLPAPER_DIR}/$(basename "${src}")"
    if [[ ! -e "${dest}" ]]; then
      install -m 0644 "${src}" "${dest}"
      copied=$((copied + 1))
    fi
  done
  log_success "Copied ${copied} bundled wallpaper(s) to ${WALLPAPER_DIR}."
else
  log_warn "No bundled wallpapers found in ${WALLPAPER_SRC_DIR}; add images to ${WALLPAPER_DIR} yourself."
fi

# The mangowm package ships /usr/share/wayland-sessions/mango.desktop. Create a
# matching entry only if it is missing so greetd / Noctalia Greeter can list Mango.
WAYLAND_SESSIONS_DIR="/usr/share/wayland-sessions"
MANGO_DESKTOP_FILE="${WAYLAND_SESSIONS_DIR}/mango.desktop"

if [[ ! -f "${MANGO_DESKTOP_FILE}" ]]; then
  log_warn "${MANGO_DESKTOP_FILE} not shipped by ${MANGO_PKG}; creating it."
  sudo install -d -m 0755 "${WAYLAND_SESSIONS_DIR}"
  sudo tee "${MANGO_DESKTOP_FILE}" >/dev/null <<EOF
[Desktop Entry]
Encoding=UTF-8
Name=Mango
DesktopNames=mango;wlroots
Comment=mango WM
Exec=mango
Icon=mango
Type=Application
EOF
  sudo chmod 0644 "${MANGO_DESKTOP_FILE}"
  log_success "Wayland session entry created."
else
  log_success "Wayland session entry present: ${MANGO_DESKTOP_FILE}"
fi

# ------------------------------------------------------------------------------
# Phase 4: Mango Configuration
# ------------------------------------------------------------------------------
log_title "Phase 4: Mango Configuration"

MANGO_CONFIG="${HOME}/.config/mango/config.conf"
MANGO_CONFIG_SRC="${SCRIPT_DIR}/config/mango/config.conf"
require_bundled "${MANGO_CONFIG_SRC}"

if should_write_config "${MANGO_CONFIG}"; then
  install -m 0644 "${MANGO_CONFIG_SRC}" "${MANGO_CONFIG}"
  log_success "Installed ${MANGO_CONFIG_SRC} -> ${MANGO_CONFIG}"

  # Validate without launching the compositor (documented flag:
  # https://mangowm.github.io/docs/configuration/basics#validate-configuration)
  if validation_output="$(mango -c "${MANGO_CONFIG}" -p 2>&1)"; then
    log_success "Mango configuration validated successfully."
  else
    log_warn "mango -p reported problems with ${MANGO_CONFIG}:"
    printf '%s\n' "${validation_output}" | sed 's/^/    /'
    log_warn "Continuing; fix the lines above before starting Mango."
  fi
fi

# ------------------------------------------------------------------------------
# Phase 5: Noctalia Configuration
# ------------------------------------------------------------------------------
log_title "Phase 5: Noctalia Configuration"

NOCTALIA_CONFIG="${HOME}/.config/noctalia/config.toml"
# Mango-specific variant: layer-surface shadows are already disabled in the file
# per https://docs.noctalia.dev/noctalia/compositor-settings/mango/#blur-and-shadows
NOCTALIA_CONFIG_SRC="${SCRIPT_DIR}/config/noctalia/config.mango.toml"
require_bundled "${NOCTALIA_CONFIG_SRC}"

if should_write_config "${NOCTALIA_CONFIG}"; then
  install -m 0644 "${NOCTALIA_CONFIG_SRC}" "${NOCTALIA_CONFIG}"
  sed -i \
    -e "s|__UI_FONT__|$(sed_escape "${UI_FONT}")|g" \
    -e "s|__THEME__|$(sed_escape "${NOCTALIA_THEME}")|g" \
    -e "s|__WALLPAPER_DIR__|$(sed_escape "${WALLPAPER_DIR}")|g" \
    "${NOCTALIA_CONFIG}"
  log_success "Installed ${NOCTALIA_CONFIG_SRC} -> ${NOCTALIA_CONFIG} (tuned for Mango)"
fi

# ------------------------------------------------------------------------------
# Phase 6: Alacritty Configuration
# ------------------------------------------------------------------------------
log_title "Phase 6: Alacritty Configuration"

ALACRITTY_CONFIG="${HOME}/.config/alacritty/alacritty.toml"
ALACRITTY_CONFIG_SRC="${SCRIPT_DIR}/config/alacritty/alacritty.toml"
require_bundled "${ALACRITTY_CONFIG_SRC}"

if should_write_config "${ALACRITTY_CONFIG}"; then
  install -m 0644 "${ALACRITTY_CONFIG_SRC}" "${ALACRITTY_CONFIG}"
  sed -i -e "s|__MONO_FONT__|$(sed_escape "${MONO_FONT}")|g" "${ALACRITTY_CONFIG}"
  log_success "Installed ${ALACRITTY_CONFIG_SRC} -> ${ALACRITTY_CONFIG}"
fi

# ------------------------------------------------------------------------------
# Phase 7: Noctalia Greeter + greetd (Login Screen)
# ------------------------------------------------------------------------------
log_title "Phase 7: Login Screen (Noctalia Greeter + greetd)"

GREETD_CONFIG="/etc/greetd/config.toml"
GREETER_STATE_DIR="/var/lib/noctalia-greeter"
GREETER_ENABLED="no"

if [[ "${WANT_GREETER}" == "yes" ]]; then
  GREETER_SESSION_BIN="$(command -v noctalia-greeter-session || true)"
  if [[ -z "${GREETER_SESSION_BIN}" ]]; then
    log_error "noctalia-greeter-session not found on PATH after installing ${GREETER_PKG}. Aborting greeter setup."
    exit 1
  fi
  log_success "Greeter session wrapper: ${GREETER_SESSION_BIN}"

  # --- greetd user ------------------------------------------------------------
  # The Arch greetd package creates a 'greeter' system user. Reuse existing or create.
  GREETD_USER="greeter"
  if [[ -f "${GREETD_CONFIG}" ]]; then
    existing_user="$(sudo sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${GREETD_CONFIG}" | head -n1 || true)"
    [[ -n "${existing_user}" ]] && GREETD_USER="${existing_user}"
  fi
  if ! id -u "${GREETD_USER}" &>/dev/null; then
    log_warn "User '${GREETD_USER}' does not exist; creating a system account for greetd."
    sudo useradd -r -M -G video -s /usr/bin/nologin "${GREETD_USER}"
  fi

  # --- /etc/greetd/config.toml -------------------------------------------------
  # --session mango pre-selects Mango in the Noctalia Greeter session list
  if sudo test -f "${GREETD_CONFIG}" && sudo grep -qF "noctalia-greeter-session" "${GREETD_CONFIG}"; then
    log_info "${GREETD_CONFIG} already launches noctalia-greeter-session; leaving it untouched."
  else
    if sudo test -f "${GREETD_CONFIG}"; then
      backup="${GREETD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
      sudo cp -a "${GREETD_CONFIG}" "${backup}"
      log_warn "Existing greetd config backed up to ${backup}"
    fi
    sudo install -d -m 0755 /etc/greetd
    sudo tee "${GREETD_CONFIG}" >/dev/null <<GREETD_EOF
# Written by mangoInstall.sh - https://docs.noctalia.dev/greeter/installation/
[terminal]
vt = 1

[default_session]
# greetd must run the session wrapper, not the noctalia-greeter binary itself.
command = "${GREETER_SESSION_BIN} -- --session mango"
user = "${GREETD_USER}"
GREETD_EOF
    sudo chmod 0644 "${GREETD_CONFIG}"
    log_success "Wrote ${GREETD_CONFIG} (session: Mango, user: ${GREETD_USER})"
  fi

  # --- greeter state directory ------------------------------------------------
  # Holds greeter.toml, sync.toml and synced wallpapers; owned by greeter session user.
  sudo systemd-tmpfiles --create noctalia-greeter.conf 2>/dev/null || true
  sudo install -d -m 0750 -o "${GREETD_USER}" -g "${GREETD_USER}" "${GREETER_STATE_DIR}"
  log_success "Greeter state directory ready: ${GREETER_STATE_DIR}"

  # --- optional: user avatars -------------------------------------------------
  sudo systemctl enable --now accounts-daemon.service 2>/dev/null \
    || log_warn "Could not enable accounts-daemon (avatars will use a fallback)."

  # --- replace any other display manager safely -------------------------------
  current_dm="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
  if [[ -n "${current_dm}" && "${current_dm}" != "display-manager.service" && "${current_dm}" != "greetd.service" ]]; then
    log_warn "Another display manager is enabled: ${current_dm}. Disabling it so greetd can own the login screen."
    sudo systemctl disable "${current_dm}" || log_warn "Could not disable ${current_dm}; check manually before rebooting."
  fi

  # Enable greetd (without --now so it does not interrupt current TTY session)
  sudo systemctl enable greetd.service
  GREETER_ENABLED="yes"
  log_success "greetd enabled. Noctalia Greeter will launch on next boot."

  # --- optional: passwordless appearance sync ---------------------------------
  # Requires Noctalia Greeter >= 1.5.0 AND a Noctalia release newer than 5.0.1
  # (https://docs.noctalia.dev/greeter/sync/#authorization). Older pairs fall
  # back to the administrator-authenticated sync path automatically.
  if resolve_choice "${GREETER_PASSWORDLESS_SYNC}" "Allow '${USER}' to sync the Noctalia look to the greeter without a password prompt?" "y"; then
    if sync_output="$(sudo noctalia-greeter passwordless-sync enable "${USER}" 2>&1)"; then
      log_success "Passwordless greeter sync enabled for ${USER}."
    else
      log_warn "Could not enable passwordless sync; Sync Now will prompt for administrator authentication instead."
      [[ -n "${sync_output}" ]] && printf '%s\n' "${sync_output}" | sed 's/^/    /'
      log_warn "Passwordless sync needs noctalia-greeter >= 1.5.0 and a Noctalia release newer than 5.0.1."
      log_warn "Installed: greeter $(pacman -Q "${GREETER_PKG}" 2>/dev/null | awk '{print $2}' || echo '?'), noctalia $(pacman -Q noctalia 2>/dev/null | awk '{print $2}' || echo '?')."
      log_warn "Retry later with: sudo noctalia-greeter passwordless-sync enable ${USER}"
    fi
  else
    log_info "Greeter sync will prompt for administrator authentication when invoked."
  fi
else
  log_info "Skipping Noctalia Greeter / greetd."
fi

# ------------------------------------------------------------------------------
# Phase 8: Autostart Mango on TTY1 (fallback when greeter is skipped)
# ------------------------------------------------------------------------------
log_title "Phase 8: Session Autostart"

AUTOSTART_MARKER_BEGIN="# >>> mangoInstall.sh: start Mango on TTY1 >>>"
AUTOSTART_MARKER_END="# <<< mangoInstall.sh <<<"

# Pick the login-shell startup file and the matching snippet for $SHELL so the
# autostart actually runs (a ~/.bash_profile block is ignored by zsh/fish).
LOGIN_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "${LOGIN_SHELL}" in
  zsh)
    PROFILE_FILE="${HOME}/.zprofile"
    PROFILE_INIT=""
    AUTOSTART_SNIPPET='if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec mango
fi'
    ;;
  fish)
    PROFILE_FILE="${HOME}/.config/fish/config.fish"
    PROFILE_INIT=""
    AUTOSTART_SNIPPET='if status is-login; and test -z "$WAYLAND_DISPLAY"; and test (tty) = /dev/tty1
    exec mango
end'
    ;;
  *)
    PROFILE_FILE="${HOME}/.bash_profile"
    PROFILE_INIT='[[ -f ~/.bashrc ]] && . ~/.bashrc'
    AUTOSTART_SNIPPET='if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec mango
fi'
    ;;
esac

# Remove any autostart block previously written by this script.
remove_autostart_block() {
  local file="$1"
  if [[ -f "${file}" ]] && grep -qF "${AUTOSTART_MARKER_BEGIN}" "${file}"; then
    sed -i "/${AUTOSTART_MARKER_BEGIN}/,/${AUTOSTART_MARKER_END}/d" "${file}"
    log_warn "Removed previous TTY1 autostart block from ${file}"
  fi
}

if [[ "${GREETER_ENABLED}" == "yes" ]]; then
  log_info "greetd handles login; skipping TTY1 autostart."
  remove_autostart_block "${HOME}/.bash_profile"
  remove_autostart_block "${HOME}/.zprofile"
  remove_autostart_block "${HOME}/.config/fish/config.fish"
elif resolve_choice "${AUTOSTART_MANGO}" "Start Mango automatically when you log in on TTY1 (${LOGIN_SHELL})?" "y"; then
  if [[ -f "${PROFILE_FILE}" ]] && grep -qF "${AUTOSTART_MARKER_BEGIN}" "${PROFILE_FILE}"; then
    log_info "TTY1 autostart already present in ${PROFILE_FILE}"
  else
    mkdir -p "$(dirname "${PROFILE_FILE}")"
    if [[ ! -f "${PROFILE_FILE}" && -n "${PROFILE_INIT}" ]]; then
      printf '%s\n\n' "${PROFILE_INIT}" > "${PROFILE_FILE}"
    fi
    {
      printf '\n%s\n' "${AUTOSTART_MARKER_BEGIN}"
      printf '%s\n' "${AUTOSTART_SNIPPET}"
      printf '%s\n' "${AUTOSTART_MARKER_END}"
    } >> "${PROFILE_FILE}"
    log_success "TTY1 autostart added to ${PROFILE_FILE}"
  fi
else
  log_info "Skipping autostart. Start Mango manually from TTY with: mango"
fi

# ------------------------------------------------------------------------------
# Phase 9: Summary & Next Steps
# ------------------------------------------------------------------------------
log_title "Phase 9: Completed"

echo
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}               Mango + Noctalia Desktop Setup Completed!               ${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo
echo "Installed Components:"
echo "  - Mango Compositor:       ${MANGO_PKG} (command: mango)"
echo "  - Shell Environment:      noctalia (bar, launcher, control center, notifications, lock)"
[[ "${GREETER_ENABLED}" == "yes" ]] && echo "  - Login Screen:           ${GREETER_PKG} + greetd (enabled for next boot)"
echo "  - Terminal, Fonts, Cursor: alacritty, JetBrainsMono Nerd Font, Noto fonts, ${CURSOR_PKG}"
echo "  - Audio:                  pipewire, pipewire-pulse, wireplumber"
echo "  - Portals & XWayland:     xdg-desktop-portal-{wlr,gtk}, xorg-xwayland"
[[ "${WANT_BROWSER}" == "yes" ]] && echo "  - Web Browser:            ${BROWSER_PKG}"
[[ "${IS_LAPTOP}" == "yes" ]] && echo "  - Laptop Power & OSD:     brightnessctl, upower, power-profiles-daemon"
echo
echo "Configuration Files:"
echo "  - Mango:                  ${MANGO_CONFIG}"
echo "  - Noctalia:               ${NOCTALIA_CONFIG}"
echo "  - Alacritty:              ${ALACRITTY_CONFIG}"
[[ "${GREETER_ENABLED}" == "yes" ]] && echo "  - greetd & Greeter:       ${GREETD_CONFIG} (state: ${GREETER_STATE_DIR})"
echo
echo "Essential Keybindings (Super = Mod):"
echo "  Super+Return / Super+T    Launch Alacritty terminal"
echo "  Super+Space               Toggle Noctalia App Launcher"
echo "  Super+S / Super+N         Toggle Noctalia Control Center"
echo "  Super+Comma               Toggle Noctalia Settings GUI"
echo "  Super+V                   Toggle Noctalia Clipboard Manager"
echo "  Super+Escape              Toggle Noctalia Session Menu (power/logout)"
echo "  Super+Alt+L               Lock screen immediately"
echo "  Super+Q                   Close focused window"
echo "  Super+F                   Toggle fullscreen"
echo "  Super+Backslash           Toggle floating mode"
echo "  Super+H / J / K / L       Focus Left / Down / Up / Right"
echo "  Super+Shift+H / J / K / L Move / Swap window direction"
echo "  Super+1 .. 9              Switch to Tag / Workspace 1 .. 9"
echo "  Super+Shift+1 .. 9        Send window to Tag 1 .. 9"
echo "  Super+W                   Cycle layout (tile, scroller, dwindle, monocle)"
echo "  Super+R                   Hot-reload Mango configuration"
echo "  Super+Shift+Q             Exit Mango compositor"
echo "  Print / Shift+Print       Screenshot focused monitor / select a region"
echo
echo "Next Steps:"
echo "  1. Wallpapers rotate from: ${WALLPAPER_DIR} (bundled images copied; add your own)"
if [[ "${GREETER_ENABLED}" == "yes" ]]; then
  echo "  2. Reboot system (sudo reboot). Noctalia Greeter will welcome you on VT1."
  echo "     Select 'Mango' from the session menu and log in."
  echo "  3. Sync appearance with login screen: open Noctalia Settings -> Security -> Noctalia Greeter -> Sync Now."
else
  echo "  2. Start Mango: log out and log in to TTY1, or run: mango"
fi
echo "  4. Adjust displays / resolutions: edit ~/.config/mango/config.conf or configure via Noctalia."
echo "  5. Enjoy your super lightweight, animated Wayland desktop!"
echo
