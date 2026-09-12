#!/usr/bin/env bash
# ==============================================================================
# Umbriel Post-Install Script for Arch Linux
#
# Run this as your regular user AFTER a base install (e.g. archInstall.sh) and
# first login. It sets up a complete Umbriel + Noctalia desktop:
#
#   - Umbriel (wlroots Wayland compositor from the Noctalia project) via the
#     AUR (umbriel-git), which pulls in xdg-desktop-portal-umbriel-git for
#     portal screen capture / sharing. xwayland-satellite for X11 apps.
#   - Noctalia (bar, launcher, notifications, lock screen, wallpaper, OSD)
#   - Noctalia Greeter + greetd as the graphical login screen (AUR: noctalia-greeter)
#   - alacritty, JetBrainsMono Nerd Font
#   - Helium browser (AUR: helium-browser-bin), optional
#   - xdg-desktop-portal-gtk for file pickers
#   - ~/.config/umbriel/config.toml   <- copied from ./config/umbriel/config.toml
#     (keybinds/look ported from the niri setup + Noctalia integration)
#   - ~/.config/noctalia/config.toml  <- copied from ./config/noctalia/config.toml
#     (font/theme/wallpaper dir filled from env vars)
#   - ~/.config/alacritty/alacritty.toml <- copied from ./config/alacritty/alacritty.toml
#   - /etc/greetd/config.toml pointing at noctalia-greeter-session (Umbriel as
#     default session); greetd enabled for next boot
#   - Fallback: auto-start Umbriel on TTY1 login if you skip the greeter
#
# Docs: https://docs.noctalia.dev/umbriel/   https://docs.noctalia.dev/greeter/
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  INSTALL_GREETER=no INSTALL_BROWSER=no ./umbrielInstall.sh
# ==============================================================================

set -euo pipefail

# Directory containing this script; bundled config files live under ./config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
AUR_HELPER="${AUR_HELPER:-yay}"                      # yay|paru (bootstrapped from the AUR if missing)
UMBRIEL_PKG="${UMBRIEL_PKG:-umbriel-git}"            # AUR package for the compositor
INSTALL_GREETER="${INSTALL_GREETER:-yes}"            # yes|no|ask  (noctalia-greeter + greetd login screen)
GREETER_PKG="${GREETER_PKG:-noctalia-greeter}"       # noctalia-greeter (tagged) | noctalia-greeter-git
GREETER_PASSWORDLESS_SYNC="${GREETER_PASSWORDLESS_SYNC:-ask}" # yes|no|ask (let $USER sync Noctalia look to the greeter without a password prompt)
INSTALL_BROWSER="${INSTALL_BROWSER:-yes}"            # yes|no  (Helium browser from the AUR)
BROWSER_PKG="${BROWSER_PKG:-helium-browser-bin}"     # AUR package name
AUTOSTART_UMBRIEL="${AUTOSTART_UMBRIEL:-ask}"        # yes|no|ask  (TTY1 autostart; only offered when the greeter is skipped)
OVERWRITE_CONFIGS="${OVERWRITE_CONFIGS:-ask}"        # yes|no|ask  (replace existing umbriel/noctalia/alacritty configs; backups are made)
WALLPAPER_DIR="${WALLPAPER_DIR:-${HOME}/Pictures/Wallpapers}"
NOCTALIA_THEME="${NOCTALIA_THEME:-Tokyo-Night}"      # Ayu|Catppuccin|Dracula|Eldritch|Gruvbox|Kanagawa|Noctalia|Nord|Rosé Pine|Tokyo-Night
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

# ------------------------------------------------------------------------------
# Phase 2: Package Installation (official repos)
# ------------------------------------------------------------------------------
log_title "Phase 2: Package Installation"

PACKAGES=(
  # Needed to build AUR packages (umbriel-git, noctalia-greeter, ...)
  git
  base-devel

  # Compositor helpers (the compositor itself comes from the AUR in Phase 2b)
  xwayland-satellite           # X11 app support; Umbriel spawns it when general.xwayland = true

  # Desktop shell (bar, launcher, notifications, lock screen, wallpaper, OSD)
  noctalia

  # Terminal + fonts
  alacritty
  ttf-jetbrains-mono-nerd
  noto-fonts
  noto-fonts-emoji

  # Portals: screencast/screenshot come from xdg-desktop-portal-umbriel (AUR dep);
  # gtk backend covers file pickers and the rest.
  xdg-desktop-portal
  xdg-desktop-portal-gtk

  # Quality of life
  wl-clipboard                 # wl-copy / wl-paste
  playerctl                    # media keys
  xdg-user-dirs                # creates ~/Pictures etc.
  xdg-utils
  polkit                       # Noctalia ships a polkit agent; also needed for greeter sync
)

if [[ "${WANT_GREETER}" == "yes" ]]; then
  PACKAGES+=(
    greetd                     # display manager daemon; noctalia-greeter runs as its default_session
    accountsservice            # optional: user avatars on the login screen
  )
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
# Phase 2b: AUR packages (Umbriel, Noctalia Greeter, Helium)
# ------------------------------------------------------------------------------
log_title "Phase 2b: AUR Packages"

AUR_PACKAGES=("${UMBRIEL_PKG}")   # depends on xdg-desktop-portal-umbriel-git
if [[ "${WANT_GREETER}" == "yes" ]]; then
  AUR_PACKAGES+=("${GREETER_PKG}")
fi
if [[ "${INSTALL_BROWSER}" =~ ^[Yy] ]]; then
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

log_info "AUR packages to install (umbriel-git compiles from source; expect a few minutes):"
printf '  - %s\n' "${AUR_PACKAGES[@]}"
"${AUR_HELPER}" -S --needed --noconfirm "${AUR_PACKAGES[@]}"
log_success "AUR packages installed."

for bin in umbriel start-umbriel; do
  if ! command -v "${bin}" &>/dev/null; then
    log_error "'${bin}' not found on PATH after installing ${UMBRIEL_PKG}. Aborting."
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Phase 3: Directories
# ------------------------------------------------------------------------------
log_title "Phase 3: User Directories"

xdg-user-dirs-update 2>/dev/null || true
mkdir -p "${HOME}/.config/umbriel" \
         "${HOME}/.config/noctalia" \
         "${HOME}/.config/alacritty" \
         "${HOME}/Pictures/Screenshots" \
         "${WALLPAPER_DIR}"
log_success "Directories ready (wallpapers: ${WALLPAPER_DIR})."

# ------------------------------------------------------------------------------
# Phase 4: Umbriel configuration
# ------------------------------------------------------------------------------
log_title "Phase 4: Umbriel Configuration"

UMBRIEL_CONFIG="${HOME}/.config/umbriel/config.toml"
UMBRIEL_CONFIG_SRC="${SCRIPT_DIR}/config/umbriel/config.toml"
require_bundled "${UMBRIEL_CONFIG_SRC}"

if should_write_config "${UMBRIEL_CONFIG}"; then
  # config/umbriel/config.toml is based on Umbriel's packaged examples/config.toml
  # with the niri setup's keybinds/look ported over and Noctalia's recommended
  # integration (autostart, window/layer rules, IPC keybinds). Umbriel
  # hot-reloads the installed copy on save.
  install -m 0644 "${UMBRIEL_CONFIG_SRC}" "${UMBRIEL_CONFIG}"
  log_success "Installed ${UMBRIEL_CONFIG_SRC} -> ${UMBRIEL_CONFIG}"

  if umbriel validate -c "${UMBRIEL_CONFIG}" >/dev/null 2>&1; then
    log_success "Umbriel config validated."
  else
    log_warn "Umbriel reported a problem with the installed config:"
    umbriel validate -c "${UMBRIEL_CONFIG}" || true
  fi
fi

# ------------------------------------------------------------------------------
# Phase 5: Noctalia configuration
# ------------------------------------------------------------------------------
log_title "Phase 5: Noctalia Configuration"

NOCTALIA_CONFIG="${HOME}/.config/noctalia/config.toml"
NOCTALIA_CONFIG_SRC="${SCRIPT_DIR}/config/noctalia/config.toml"
require_bundled "${NOCTALIA_CONFIG_SRC}"

if should_write_config "${NOCTALIA_CONFIG}"; then
  # config/noctalia/config.toml contains __UI_FONT__, __THEME__ and
  # __WALLPAPER_DIR__ placeholders which are filled from the variables at the
  # top of this script.
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
require_bundled "${ALACRITTY_CONFIG_SRC}"

if should_write_config "${ALACRITTY_CONFIG}"; then
  # config/alacritty/alacritty.toml contains a __MONO_FONT__ placeholder which
  # is filled from the MONO_FONT variable at the top of this script.
  install -m 0644 "${ALACRITTY_CONFIG_SRC}" "${ALACRITTY_CONFIG}"
  sed -i -e "s|__MONO_FONT__|${MONO_FONT}|g" "${ALACRITTY_CONFIG}"
  log_success "Installed ${ALACRITTY_CONFIG_SRC} -> ${ALACRITTY_CONFIG}"
fi

# ------------------------------------------------------------------------------
# Phase 7: Noctalia Greeter + greetd (login screen)
# ------------------------------------------------------------------------------
log_title "Phase 7: Login Screen"

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
  # The Arch greetd package creates a 'greeter' system user. Reuse whatever user
  # an existing config names, otherwise fall back to 'greeter'.
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
  # Umbriel's desktop entry is Name=Umbriel; --session pre-selects it in the
  # picker (case-insensitive). The user can still pick another session.
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
# Written by umbrielInstall.sh - https://docs.noctalia.dev/greeter/installation/
[terminal]
vt = 1

[default_session]
# greetd must run the session wrapper, not the noctalia-greeter binary itself.
command = "${GREETER_SESSION_BIN} -- --session umbriel"
user = "${GREETD_USER}"
GREETD_EOF
    sudo chmod 0644 "${GREETD_CONFIG}"
    log_success "Wrote ${GREETD_CONFIG} (session: Umbriel, user: ${GREETD_USER})"
  fi

  # --- greeter state directory ------------------------------------------------
  # Holds greeter.toml, sync.toml and synced wallpapers; must be owned by the
  # greetd session user. The package ships a tmpfiles.d rule for this, but make
  # sure it exists now rather than only after the next boot.
  sudo systemd-tmpfiles --create noctalia-greeter.conf 2>/dev/null || true
  sudo install -d -m 0750 -o "${GREETD_USER}" -g "${GREETD_USER}" "${GREETER_STATE_DIR}"
  log_success "Greeter state directory ready: ${GREETER_STATE_DIR}"

  # --- optional: user avatars ---------------------------------------------------
  sudo systemctl enable --now accounts-daemon.service 2>/dev/null \
    || log_warn "Could not enable accounts-daemon (avatars will use a fallback)."

  # --- replace any other display manager --------------------------------------
  current_dm="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
  if [[ -n "${current_dm}" && "${current_dm}" != "display-manager.service" && "${current_dm}" != "greetd.service" ]]; then
    log_warn "Another display manager is enabled: ${current_dm}. Disabling it so greetd can own the login screen."
    sudo systemctl disable "${current_dm}" || log_warn "Could not disable ${current_dm}; check manually before rebooting."
  fi

  # Enable (not --now): starting greetd immediately would take over VT1 while
  # you are still logged in there. It starts on the next boot.
  sudo systemctl enable greetd.service
  GREETER_ENABLED="yes"
  log_success "greetd enabled. Noctalia Greeter will appear on the next boot."

  # --- optional: passwordless appearance sync -----------------------------------
  # Lets Noctalia's "Sync Now" / "Auto-Sync Greeter" push wallpaper, palette and
  # monitor layout to the login screen without an admin prompt. Narrow polkit
  # rule managed by the greeter CLI (needs greeter >= 1.5.0).
  if resolve_choice "${GREETER_PASSWORDLESS_SYNC}" "Allow '${USER}' to sync the Noctalia look to the greeter without a password prompt?" "y"; then
    if sudo noctalia-greeter passwordless-sync enable "${USER}"; then
      log_success "Passwordless greeter sync enabled for ${USER}."
    else
      log_warn "Could not enable passwordless sync (older greeter?). Sync will ask for admin auth instead."
    fi
  else
    log_info "Greeter sync will prompt for administrator authentication (Noctalia's polkit agent handles it)."
  fi
else
  log_info "Skipping Noctalia Greeter / greetd."
fi

# ------------------------------------------------------------------------------
# Phase 8: Start Umbriel automatically on TTY1 (fallback when no greeter)
# ------------------------------------------------------------------------------
log_title "Phase 8: Session Autostart"

BASH_PROFILE="${HOME}/.bash_profile"
AUTOSTART_MARKER="# >>> umbrielInstall.sh: start Umbriel on TTY1 >>>"

if [[ "${GREETER_ENABLED}" == "yes" ]]; then
  log_info "greetd handles login; skipping TTY1 autostart."
  # Remove a stale TTY1 autostart block so it does not fight the greeter on VT1.
  if [[ -f "${BASH_PROFILE}" ]] && grep -qF "${AUTOSTART_MARKER}" "${BASH_PROFILE}"; then
    sed -i "/${AUTOSTART_MARKER}/,/# <<< umbrielInstall.sh <<</d" "${BASH_PROFILE}"
    log_warn "Removed previous TTY1 autostart block from ${BASH_PROFILE}"
  fi
elif resolve_choice "${AUTOSTART_UMBRIEL}" "Start Umbriel automatically when you log in on TTY1?" "y"; then
  if [[ -f "${BASH_PROFILE}" ]] && grep -qF "${AUTOSTART_MARKER}" "${BASH_PROFILE}"; then
    log_info "TTY1 autostart already present in ${BASH_PROFILE}"
  else
    # If no .bash_profile exists yet, keep bash sourcing ~/.bashrc for login shells.
    if [[ ! -f "${BASH_PROFILE}" ]]; then
      printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n\n' > "${BASH_PROFILE}"
    fi
    cat >> "${BASH_PROFILE}" <<'PROFILE_EOF'

# >>> umbrielInstall.sh: start Umbriel on TTY1 >>>
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec start-umbriel
fi
# <<< umbrielInstall.sh <<<
PROFILE_EOF
    log_success "TTY1 autostart added to ${BASH_PROFILE}"
  fi
else
  log_info "Skipping autostart. Start Umbriel manually with: start-umbriel"
fi

# ------------------------------------------------------------------------------
# Phase 9: Summary
# ------------------------------------------------------------------------------
log_title "Phase 9: Done"

echo
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}               Umbriel Desktop Setup Completed Successfully!             ${COLOR_RESET}"
echo -e "${COLOR_SUCCESS}========================================================================${COLOR_RESET}"
echo
echo "Installed:"
echo "  - ${UMBRIEL_PKG} + xdg-desktop-portal-umbriel + xwayland-satellite  (compositor)"
echo "  - noctalia                       (bar / launcher / notifications / lock / wallpaper)"
[[ "${GREETER_ENABLED}" == "yes" ]] && echo "  - ${GREETER_PKG} + greetd        (login screen, enabled for next boot)"
echo "  - alacritty"
[[ "${INSTALL_BROWSER}" =~ ^[Yy] ]] && echo "  - ${BROWSER_PKG} (AUR, via ${AUR_HELPER})"
echo "  - JetBrainsMono Nerd Font, Noto fonts, xdg-desktop-portal-gtk"
[[ "${IS_LAPTOP}" == "yes" ]] && echo "  - brightnessctl, upower, power-profiles-daemon (laptop)"
echo
echo "Config files:"
echo "  - ${UMBRIEL_CONFIG}"
echo "  - ${NOCTALIA_CONFIG}"
echo "  - ${ALACRITTY_CONFIG}"
[[ "${GREETER_ENABLED}" == "yes" ]] && echo "  - ${GREETD_CONFIG}   (greeter settings: ${GREETER_STATE_DIR}/greeter.toml)"
echo
echo "Keybinds (Mod = Super):"
echo "  Mod+Return / Mod+T   Terminal            Mod+Space      Noctalia launcher"
echo "  Mod+N                Control center      Mod+V          Clipboard"
echo "  Mod+Q                Close window        Mod+O          Overview"
echo "  Mod+H/J/K/L          Focus               Mod+Ctrl+HJKL  Move"
echo "  Mod+1-9              Workspace           Mod+Shift+1-9  Move column to workspace"
echo "  Mod+F / Mod+Shift+F  Maximize / Fullscreen               Mod+W  Cycle layout"
echo "  Print / Ctrl+Print   Screenshot region / screen          Mod+Alt+L  Lock"
echo "  Mod+Escape           Session menu        Mod+Shift+E    Quit Umbriel"
echo "  Mod+Shift+/          Show all keybinds (cheatsheet)"
echo
echo "Next Steps:"
echo "  1. Put some wallpapers in: ${WALLPAPER_DIR}"
if [[ "${GREETER_ENABLED}" == "yes" ]]; then
  echo "  2. Reboot. Noctalia Greeter will start on VT1; pick 'Umbriel' and log in."
  echo "     If it fails, switch to a TTY (Ctrl+Alt+F2) and run: journalctl -u greetd -b | grep noctalia-greeter"
  echo "  3. Match the login screen to your desktop: Noctalia Settings -> Security -> Noctalia Greeter -> Sync Now"
else
  echo "  2. Start Umbriel: log out and back in on TTY1 (if autostart enabled), or run: start-umbriel"
  echo "  3. Want a graphical login later? Re-run with: INSTALL_GREETER=yes ./umbrielInstall.sh"
fi
echo "  4. Multi-monitor / HiDPI? Run 'umbriel outputs' and add an [output.<name>] block to config.toml."
echo "  5. Noctalia settings UI: Mod+N -> gear icon, or run: noctalia msg settings-toggle"
echo "     Enable Settings -> Templates -> Compositors -> Umbriel to theme borders from your palette."
echo "  Logs: ~/.cache/umbriel/umbriel.log   ~/.cache/noctalia/noctalia.log"
echo
