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
#   - Noctalia (bar, launcher, notifications, lock screen, idle lock, wallpaper,
#     clipboard history, night light, OSD)
#   - alacritty, swaybg, JetBrainsMono Nerd Font, Noto fonts
#   - Helium browser (AUR: helium-browser-bin) via yay, bootstrapped if missing,
#     and registered as the default browser for http/https/html
#   - Login screen: greetd + Noctalia Greeter (AUR: noctalia-greeter);
#     /etc/greetd/config.toml pointed at noctalia-greeter-session, any other
#     display manager disabled, greetd enabled for the next boot
#   - xdg-desktop-portal (gnome + gtk) for screen sharing / file pickers
#   - Desktop basics: nautilus (files), imv (images), pavucontrol (audio mixer)
#   - Wayland plumbing: qt5-wayland, qt6-wayland, adwaita-icon-theme (GTK icons
#     + Adwaita cursor, matched by the cursor block in config.kdl)
#   - ~/.config/niri/config.kdl  <- ./config/niri/config.kdl
#     (tutorial keybinds/look + Noctalia integration; edit that file to customise)
#   - ~/.config/noctalia/config.toml  <- ./config/noctalia/config.toml
#     (tutorial bar layout & theme; font/theme/wallpaper dir filled from env vars)
#   - ~/.config/alacritty/alacritty.toml  <- ./config/alacritty/alacritty.toml
#     (font filled from MONO_FONT)
#   - $WALLPAPER_DIR seeded with the images in ./config/Wallpapers (never overwrites)
#
# Not done here (by design):
#   - Login shell (zsh + starship, ~/.zshrc, ~/.config/starship.toml) is set up
#     by archInstall.sh; this script is desktop-only.
#   - greetd is enabled but NOT started, so the current TTY session survives;
#     the greeter appears after a reboot. With INSTALL_GREETER=no, start niri
#     yourself with `niri-session` (or exec it from ~/.zprofile on TTY1).
#
# Every default in the "Configuration" section can be overridden from the
# environment, e.g.:  INSTALL_BROWSER=no INSTALL_GREETER=no ./niriInstall.sh
# ==============================================================================

set -Eeuo pipefail

# Directory containing this script; bundled config files live under ./config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Configuration (override via environment)
# ------------------------------------------------------------------------------
INSTALL_BROWSER="${INSTALL_BROWSER:-yes}"        # yes|no  (Helium browser from the AUR)
BROWSER_PKG="${BROWSER_PKG:-helium-browser-bin}" # AUR package name
INSTALL_GREETER="${INSTALL_GREETER:-yes}"        # yes|no  (greetd + Noctalia Greeter login screen)
GREETER_PKG="${GREETER_PKG:-noctalia-greeter}"   # AUR package name (noctalia-greeter | noctalia-greeter-git)
AUR_HELPER="${AUR_HELPER:-yay}"                  # yay|paru (bootstrapped from the AUR if missing)
OVERWRITE_CONFIGS="${OVERWRITE_CONFIGS:-ask}"    # yes|no|ask  (replace existing niri/noctalia/alacritty configs; backups are made)
LINK_CONFIGS="${LINK_CONFIGS:-no}"               # yes|no  (symlink placeholder-free configs to this repo instead of copying;
                                                 #          niri hot-reloads on save, so edits in the repo apply live)
WALLPAPER_DIR="${WALLPAPER_DIR:-${HOME}/Pictures/Wallpapers}"
NOCTALIA_THEME="${NOCTALIA_THEME:-Tokyo-Night}"  # see NOCTALIA_THEMES below
UI_FONT="${UI_FONT:-JetBrainsMono Nerd Font Propo}"
MONO_FONT="${MONO_FONT:-JetBrainsMono Nerd Font}"

# Built-in Noctalia palettes (exact, case-sensitive names from example.toml).
NOCTALIA_THEMES=("Ayu" "Catppuccin" "Dracula" "Eldritch" "Gruvbox" "Kanagawa" "Noctalia" "Nord" "Rosé Pine" "Tokyo-Night")

# Bundled config files: "<repo-relative source>|<destination>".
NIRI_CONFIG="${HOME}/.config/niri/config.kdl"
NOCTALIA_CONFIG="${HOME}/.config/noctalia/config.toml"
ALACRITTY_CONFIG="${HOME}/.config/alacritty/alacritty.toml"
NIRI_CONFIG_SRC="${SCRIPT_DIR}/config/niri/config.kdl"
NOCTALIA_CONFIG_SRC="${SCRIPT_DIR}/config/noctalia/config.toml"
ALACRITTY_CONFIG_SRC="${SCRIPT_DIR}/config/alacritty/alacritty.toml"
WALLPAPER_SRC="${SCRIPT_DIR}/config/Wallpapers"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
# Colors only when stdout is a terminal (and NO_COLOR is unset), so piping to a
# log file does not fill it with escape codes.
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

trap 'log_error "Script failed on line ${LINENO}: ${BASH_COMMAND}"' ERR

# Resources released on exit (success or failure).
AUR_BUILD_DIR=""
SUDO_KEEPALIVE_PID=""
cleanup() {
  [[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null
  [[ -n "${AUR_BUILD_DIR}" && -d "${AUR_BUILD_DIR}" ]] && rm -rf "${AUR_BUILD_DIR}"
  return 0
}
trap cleanup EXIT

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
    yes) return 0 ;;
    no)  return 1 ;;
    *)   ask_yes_no "${prompt}" "${default}" ;;
  esac
}

# Move an existing file (or symlink) aside with a timestamp suffix.
backup_file() {
  local file="$1"
  if [[ -e "${file}" || -L "${file}" ]]; then
    local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    mv "${file}" "${backup}"
    log_warn "Existing $(basename "${file}") backed up to ${backup}"
  fi
}

# Escape a string for use as a literal sed replacement (delimiter is '|').
# Newlines cannot be escaped this way; they are rejected in Phase 1.
escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Decide whether a config file should be (re)written.
should_write_config() {
  local file="$1"
  if [[ ! -e "${file}" && ! -L "${file}" ]]; then
    return 0
  fi
  # Already the symlink we would create -> nothing to do.
  if [[ -L "${file}" && -n "${2:-}" && "$(readlink -f "${file}")" == "$(readlink -f "$2")" ]]; then
    log_info "${file} already links to the repo copy"
    return 1
  fi
  if resolve_choice "${OVERWRITE_CONFIGS}" "Replace existing ${file}? (a backup will be kept)" "n"; then
    backup_file "${file}"
    return 0
  fi
  log_info "Keeping existing ${file}"
  return 1
}

# install_config <src> <dst> [sed-expression ...]
#
# Copies <src> to <dst> (mode 0644) and applies the given sed expressions to
# fill __PLACEHOLDER__ tokens, then asserts none are left. With LINK_CONFIGS=yes
# and no sed expressions, symlinks <dst> -> <src> instead so edits in the repo
# take effect immediately (niri hot-reloads its config on save).
install_config() {
  local src="$1" dst="$2"; shift 2
  local -a sed_args=("$@")

  if [[ "${LINK_CONFIGS}" == "yes" && ${#sed_args[@]} -eq 0 ]]; then
    should_write_config "${dst}" "${src}" || return 0
    mkdir -p "$(dirname "${dst}")"
    ln -sfn "${src}" "${dst}"
    log_success "Linked ${dst} -> ${src}"
    return 0
  fi
  if [[ "${LINK_CONFIGS}" == "yes" ]]; then
    log_info "$(basename "${dst}") contains placeholders; copying instead of linking."
  fi

  should_write_config "${dst}" || return 0
  install -D -m 0644 "${src}" "${dst}"
  if [[ ${#sed_args[@]} -gt 0 ]]; then
    sed -i "${sed_args[@]}" "${dst}"
  fi
  # Guard against adding a placeholder to a template and forgetting its -e.
  if grep -qE '__[A-Z_]+__' "${dst}"; then
    log_error "Unfilled placeholder(s) in ${dst}:"
    grep -nE '__[A-Z_]+__' "${dst}" >&2 || true
    exit 1
  fi
  log_success "Installed ${src} -> ${dst}"
}

# ------------------------------------------------------------------------------
# Phase 1: Pre-flight Checks
# ------------------------------------------------------------------------------
log_title "Phase 1: Pre-flight Checks"

# Validate environment overrides early so a typo fails before any prompts.
# Values are lower-cased in place so later checks can compare exact strings.
validate_option() {
  local name="$1" allowed="$2" value
  value="${!name,,}"
  if [[ " ${allowed} " != *" ${value} "* ]]; then
    log_error "Invalid ${name}='${!name}'. Allowed values: ${allowed// /, }"
    exit 1
  fi
  printf -v "${name}" '%s' "${value}"
}
validate_option INSTALL_BROWSER   "yes no"
validate_option INSTALL_GREETER   "yes no"
validate_option OVERWRITE_CONFIGS "yes no ask"
validate_option LINK_CONFIGS      "yes no"
validate_option AUR_HELPER        "yay paru"

# NOCTALIA_THEME must match a built-in palette exactly (case-sensitive).
theme_ok="no"
for t in "${NOCTALIA_THEMES[@]}"; do
  [[ "${NOCTALIA_THEME}" == "${t}" ]] && { theme_ok="yes"; break; }
done
if [[ "${theme_ok}" == "no" ]]; then
  log_error "Invalid NOCTALIA_THEME='${NOCTALIA_THEME}'. Allowed values: $(printf '%s, ' "${NOCTALIA_THEMES[@]}" | sed 's/, $//')"
  exit 1
fi

# Values substituted via sed must be single-line.
for v in UI_FONT MONO_FONT WALLPAPER_DIR NOCTALIA_THEME; do
  if [[ "${!v}" == *$'\n'* ]]; then
    log_error "${v} must not contain a newline."
    exit 1
  fi
done
log_success "Configuration options valid."

# Fail on a broken checkout now, not after a ten-minute package install.
for src in "${NIRI_CONFIG_SRC}" "${NOCTALIA_CONFIG_SRC}" "${ALACRITTY_CONFIG_SRC}"; do
  if [[ ! -f "${src}" ]]; then
    log_error "Bundled config not found: ${src}"
    log_error "Run this script from a full checkout of the repository."
    exit 1
  fi
done
log_success "Bundled config files present."

if [[ "${EUID}" -eq 0 ]]; then
  log_error "Do not run this script as root. Run it as your normal user; it will call sudo when needed."
  exit 1
fi
CURRENT_USER="$(id -un)"
log_success "Running as user '${CURRENT_USER}'."

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
  log_error "sudo authentication failed. Is '${CURRENT_USER}' in the wheel group?"
  exit 1
fi
log_success "sudo access verified."

# Keep the sudo timestamp fresh so long pacman/makepkg runs never re-prompt.
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!

log_info "Verifying internet connection..."
# HTTPS first (works where ICMP is filtered); ping as a fallback if curl is missing.
if ! ( curl -fsI --max-time 5 https://archlinux.org &>/dev/null \
    || ping -c 1 -W 3 1.1.1.1 &>/dev/null ); then
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

  # Desktop shell (bar, launcher, notifications, lock/idle, wallpaper, clipboard, OSD)
  noctalia
  upower                       # noctalia optdep: battery / power device integration
  # ddcutil is the remaining noctalia optdep (external-monitor brightness over
  # DDC/CI). Not installed by default: needs the i2c-dev module and
  # [brightness] enable_ddcutil = true in config.toml.

  # Tutorial extras
  alacritty                    # terminal
  swaybg                       # manual wallpaper fallback
  ttf-jetbrains-mono-nerd

  # Portals (screen sharing, file pickers). niri ships a portals.conf preferring gnome;gtk.
  xdg-desktop-portal
  xdg-desktop-portal-gnome
  xdg-desktop-portal-gtk

  # Desktop basics niri/Noctalia do not provide
  nautilus                     # file manager (pairs with the gnome portal)
  imv                          # image viewer
  pavucontrol                  # audio mixer / PipeWire troubleshooting

  # Wayland plumbing
  qt5-wayland                  # Qt apps on Wayland (QT_QPA_PLATFORM=wayland in config.kdl)
  qt6-wayland
  adwaita-icon-theme           # GTK icons + Adwaita cursor (cursor block in config.kdl)

  # Quality of life
  wl-clipboard                 # wl-copy / wl-paste
  playerctl                    # media keys
  xdg-user-dirs                # creates ~/Pictures etc. (screenshots go there)
  xdg-utils                    # xdg-open / xdg-mime (default browser registration)
  noto-fonts
  noto-fonts-emoji
  polkit

  # Build tooling for the AUR helper bootstrap. Both are already installed by
  # archInstall.sh; kept here (--needed makes them no-ops) so this script also
  # works on systems installed some other way.
  git
  base-devel
)

AUR_PACKAGES=()
if [[ "${INSTALL_BROWSER}" == "yes" ]]; then
  AUR_PACKAGES+=("${BROWSER_PKG}")
fi
if [[ "${INSTALL_GREETER}" == "yes" ]]; then
  PACKAGES+=(greetd)                 # official repo; the greeter itself is AUR
  AUR_PACKAGES+=("${GREETER_PKG}")
fi

# power-profiles-daemon conflicts with tlp / auto-cpufreq; skip it if either is present.
INSTALL_PPD="no"
if [[ "${IS_LAPTOP}" == "yes" ]]; then
  PACKAGES+=(brightnessctl)
  if pacman -Qq tlp &>/dev/null || pacman -Qq auto-cpufreq &>/dev/null; then
    log_warn "tlp/auto-cpufreq detected; skipping power-profiles-daemon (they conflict)."
  else
    PACKAGES+=(power-profiles-daemon)
    INSTALL_PPD="yes"
  fi
fi

log_info "Packages to install:"
printf '  - %s\n' "${PACKAGES[@]}"

log_info "Synchronizing package databases and installing (this may take a while)..."
sudo pacman -Syu --needed --noconfirm "${PACKAGES[@]}"
log_success "Packages installed."

if [[ "${INSTALL_PPD}" == "yes" ]]; then
  sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null \
    || log_warn "Could not enable power-profiles-daemon; continuing."
fi

# Validate the bundled niri config as soon as the binary exists and BEFORE any
# user config is touched, so a broken repo file never replaces a working one.
if niri validate -c "${NIRI_CONFIG_SRC}" >/dev/null 2>&1; then
  log_success "Bundled niri config validated."
else
  log_error "Bundled niri config failed validation; aborting before touching any config:"
  niri validate -c "${NIRI_CONFIG_SRC}" || true
  exit 1
fi

# ------------------------------------------------------------------------------
# Phase 2b: AUR packages (Helium browser, Noctalia Greeter)
# ------------------------------------------------------------------------------
BROWSER_DESKTOP=""
if [[ ${#AUR_PACKAGES[@]} -gt 0 ]]; then
  log_title "Phase 2b: AUR Packages"

  if ! command -v "${AUR_HELPER}" &>/dev/null; then
    log_info "AUR helper '${AUR_HELPER}' not found. Bootstrapping ${AUR_HELPER}-bin from the AUR..."
    AUR_BUILD_DIR=$(mktemp -d)   # removed by the EXIT trap, even on failure
    git clone --depth 1 "https://aur.archlinux.org/${AUR_HELPER}-bin.git" "${AUR_BUILD_DIR}/${AUR_HELPER}-bin"
    (cd "${AUR_BUILD_DIR}/${AUR_HELPER}-bin" && makepkg -si --noconfirm --needed)
    log_success "${AUR_HELPER} installed."
  else
    log_success "AUR helper '${AUR_HELPER}' already present."
  fi

  log_info "AUR packages to install:"
  printf '  - %s\n' "${AUR_PACKAGES[@]}"
  "${AUR_HELPER}" -S --needed --noconfirm "${AUR_PACKAGES[@]}"
  log_success "AUR packages installed."

  # Register the browser as default for web links. The .desktop name is read
  # from the installed package rather than hard-coded, so BROWSER_PKG can be
  # swapped for any other browser package.
  if [[ "${INSTALL_BROWSER}" == "yes" ]]; then
    BROWSER_DESKTOP="$(pacman -Qql "${BROWSER_PKG}" 2>/dev/null \
      | grep -m1 -E '^/usr/share/applications/[^/]+\.desktop$' | xargs -r basename || true)"
    if [[ -n "${BROWSER_DESKTOP}" ]]; then
      if xdg-mime default "${BROWSER_DESKTOP}" x-scheme-handler/http x-scheme-handler/https text/html; then
        log_success "Default browser set to ${BROWSER_DESKTOP}"
      else
        log_warn "Could not set ${BROWSER_DESKTOP} as default browser; set it later with: xdg-settings set default-web-browser ${BROWSER_DESKTOP}"
      fi
    else
      log_warn "No .desktop file found in ${BROWSER_PKG}; default browser not set."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Phase 2c: Login screen (greetd + Noctalia Greeter)
# ------------------------------------------------------------------------------
GREETD_STATUS="not installed"
if [[ "${INSTALL_GREETER}" == "yes" ]]; then
  log_title "Phase 2c: Login Screen (greetd)"

  GREETD_CONF="/etc/greetd/config.toml"
  # greetd must launch the session wrapper, not the noctalia-greeter binary.
  GREETER_SESSION="$(command -v noctalia-greeter-session || true)"
  if [[ -z "${GREETER_SESSION}" ]]; then
    log_error "noctalia-greeter-session not found after installing ${GREETER_PKG}; cannot configure greetd."
    exit 1
  fi

  # Point greetd's [default_session] at the greeter. Only the `command` line
  # inside that section is touched (the range stops at the next [section]), so
  # the rest of the packaged config - vt, greeter user - is preserved.
  if [[ ! -f "${GREETD_CONF}" ]]; then
    log_error "${GREETD_CONF} not found; is greetd installed?"
    exit 1
  fi
  if sudo grep -qF "command = \"${GREETER_SESSION}\"" "${GREETD_CONF}"; then
    log_info "${GREETD_CONF} already launches ${GREETER_SESSION}"
  else
    sudo cp -a "${GREETD_CONF}" "${GREETD_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    sudo sed -i "/^\[default_session\]/,/^\[/ s|^command = .*|command = \"${GREETER_SESSION}\"|" "${GREETD_CONF}"
    if sudo grep -qF "command = \"${GREETER_SESSION}\"" "${GREETD_CONF}"; then
      log_success "${GREETD_CONF}: default_session command -> ${GREETER_SESSION}"
    else
      log_error "Failed to update ${GREETD_CONF}; edit it manually (see the .bak copy next to it)."
      exit 1
    fi
  fi

  # Exactly one display manager may own display-manager.service. Disable any
  # other one (gdm, sddm, ly, ...) before enabling greetd.
  CURRENT_DM="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
  if [[ -n "${CURRENT_DM}" && "${CURRENT_DM}" != "display-manager.service" && "${CURRENT_DM}" != "greetd.service" ]]; then
    log_warn "Another display manager is enabled (${CURRENT_DM}); disabling it in favour of greetd."
    sudo systemctl disable "${CURRENT_DM}" 2>/dev/null \
      || log_warn "Could not disable ${CURRENT_DM}; disable it manually before rebooting."
  fi

  # enable, not --now: starting greetd here would take over VT1 and kill the
  # TTY session this script is running from. It comes up on the next boot.
  sudo systemctl enable greetd.service
  GREETD_STATUS="enabled (starts on next boot)"
  log_success "greetd enabled. Noctalia Greeter will appear after a reboot."
fi

# ------------------------------------------------------------------------------
# Phase 3: Directories & wallpapers
# ------------------------------------------------------------------------------
log_title "Phase 3: User Directories"

xdg-user-dirs-update 2>/dev/null || true
mkdir -p "${HOME}/.config/niri" \
         "${HOME}/.config/noctalia" \
         "${HOME}/.config/alacritty" \
         "${HOME}/Pictures/Screenshots" \
         "${WALLPAPER_DIR}"
log_success "Directories ready (wallpapers: ${WALLPAPER_DIR})."

# Seed the wallpaper directory with the bundled images (never overwrites).
if compgen -G "${WALLPAPER_SRC}/*" >/dev/null; then
  cp -n "${WALLPAPER_SRC}"/* "${WALLPAPER_DIR}/"
  log_success "Bundled wallpapers copied to ${WALLPAPER_DIR}"
else
  log_warn "No bundled wallpapers found in ${WALLPAPER_SRC}; skipping."
fi

# ------------------------------------------------------------------------------
# Phase 4: Configuration files
# ------------------------------------------------------------------------------
log_title "Phase 4: Configuration Files"

# config/niri/config.kdl is niri's default config with the tutorial's changes
# applied, plus Noctalia's recommended niri integration. No placeholders, so it
# is eligible for LINK_CONFIGS=yes.
install_config "${NIRI_CONFIG_SRC}" "${NIRI_CONFIG}"

# config/noctalia/config.toml is the tutorial's settings translated to Noctalia
# v5 TOML, plus idle lock/screen-off. Placeholders: __UI_FONT__, __THEME__,
# __WALLPAPER_DIR__.
install_config "${NOCTALIA_CONFIG_SRC}" "${NOCTALIA_CONFIG}" \
  -e "s|__UI_FONT__|$(escape_sed "${UI_FONT}")|g" \
  -e "s|__THEME__|$(escape_sed "${NOCTALIA_THEME}")|g" \
  -e "s|__WALLPAPER_DIR__|$(escape_sed "${WALLPAPER_DIR}")|g"

# config/alacritty/alacritty.toml. Placeholder: __MONO_FONT__.
install_config "${ALACRITTY_CONFIG_SRC}" "${ALACRITTY_CONFIG}" \
  -e "s|__MONO_FONT__|$(escape_sed "${MONO_FONT}")|g"

# ------------------------------------------------------------------------------
# Phase 5: Summary
# ------------------------------------------------------------------------------
log_title "Phase 5: Done"

echo
printf '%s%s%s\n' "${COLOR_SUCCESS}" "========================================================================" "${COLOR_RESET}"
printf '%s%s%s\n' "${COLOR_SUCCESS}" "                 Niri Desktop Setup Completed Successfully!             " "${COLOR_RESET}"
printf '%s%s%s\n' "${COLOR_SUCCESS}" "========================================================================" "${COLOR_RESET}"
echo
# pkg_ver <name> -> "name 1.2.3-1" or "name (not installed)"
pkg_ver() { pacman -Q "$1" 2>/dev/null || echo "$1 (not installed)"; }

echo "Installed:"
echo "  - $(pkg_ver niri) + xwayland-satellite   (compositor)"
echo "  - $(pkg_ver noctalia)                    (bar / launcher / notifications / lock / idle / wallpaper / clipboard)"
echo "  - alacritty, swaybg, nautilus, imv, pavucontrol"
if [[ "${INSTALL_BROWSER}" == "yes" ]]; then
  echo "  - $(pkg_ver "${BROWSER_PKG}") (AUR, via ${AUR_HELPER}; default browser: ${BROWSER_DESKTOP:-not set})"
fi
if [[ "${INSTALL_GREETER}" == "yes" ]]; then
  echo "  - $(pkg_ver greetd) + $(pkg_ver "${GREETER_PKG}") (login screen; ${GREETD_STATUS})"
fi
echo "  - JetBrainsMono Nerd Font, Noto fonts, adwaita-icon-theme, qt5/qt6-wayland"
echo "  - xdg-desktop-portal (gnome/gtk)"
if [[ "${IS_LAPTOP}" == "yes" ]]; then
  if [[ "${INSTALL_PPD}" == "yes" ]]; then
    echo "  - brightnessctl, power-profiles-daemon (laptop)"
  else
    echo "  - brightnessctl (laptop; power-profiles-daemon skipped due to tlp/auto-cpufreq)"
  fi
fi
echo
echo "Config files (mode: $([[ "${LINK_CONFIGS}" == "yes" ]] && echo "symlink where possible" || echo "copy")):"
echo "  - ${NIRI_CONFIG}"
echo "  - ${NOCTALIA_CONFIG}"
echo "  - ${ALACRITTY_CONFIG}"
echo
echo "Keybinds (Mod = Super) - press Mod+Shift+/ inside niri for the full list:"
echo "  Mod+Return   Terminal              Mod+Space    Noctalia launcher"
echo "  Mod+N        Noctalia control center   Mod+Q    Close window"
echo "  Mod+O        Overview              Print        Screenshot (region)"
echo "  Super+Alt+L  Lock                  Mod+Shift+E  Quit niri"
echo
echo "Next Steps:"
echo "  1. Add your own wallpapers to: ${WALLPAPER_DIR} (a few are bundled already)"
if [[ "${INSTALL_GREETER}" == "yes" ]]; then
  echo "  2. Reboot: greetd shows the Noctalia Greeter; pick the 'niri' session and log in."
  echo "     If the greeter fails, switch to TTY2 (Ctrl+Alt+F2), log in, and run:"
  echo "       sudo systemctl disable greetd   # then start niri manually with: niri-session"
else
  echo "  2. Start niri from a TTY with: niri-session"
  echo "     (to auto-start on TTY1, add to ~/.zprofile:"
  echo "      [[ -z \"\$WAYLAND_DISPLAY\" && \"\$XDG_VTNR\" == 1 ]] && exec niri-session)"
fi
echo "  3. Multi-monitor? Run 'niri msg outputs' and edit the output block in config.kdl."
echo "  4. Noctalia settings UI: Mod+N -> gear icon, or run: noctalia msg settings-toggle"
echo "     Idle lock is on (10 min lock, 11 min screen off): [idle.behavior.*] in config.toml"
echo
