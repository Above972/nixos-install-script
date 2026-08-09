#!/usr/bin/env bash
#
# Re-apply this project's flake onto an ALREADY INSTALLED system.
# ============================================================================
#
# install.sh is for the live ISO. This is its counterpart for a machine that
# already boots: it updates /etc/nixos from the files next to it and rebuilds.
#
# The placeholders (@USERNAME@, @HOSTNAME@, GPU bus IDs, ...) are filled from
# the values install.sh substituted the first time, read back out of the
# installed /etc/nixos — so nothing has to be remembered or retyped, and the
# bus IDs cannot drift from what the hardware actually reports.
#
# Usage, from a TTY (Ctrl+Alt+F2) if the desktop is broken:
#   git clone https://github.com/Above972/nixos-install-script.git ~/nixos-install-script
#   sudo bash ~/nixos-install-script/nixos-hyprland-setup/update-config.sh
#
# The previous /etc/nixos files are backed up first. To roll back, copy them
# out of the printed backup directory and rebuild again — or just pick the
# previous generation in the boot menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-/etc/nixos}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"

for f in flake.nix configuration.nix home.nix; do
  [[ -f "$SCRIPT_DIR/$f" ]] || die "$f not found next to this script."
done
[[ -f "$TARGET/configuration.nix" && -f "$TARGET/home.nix" ]] \
  || die "$TARGET does not look like a system installed from this project."
[[ -f "$TARGET/hardware-configuration.nix" ]] \
  || die "$TARGET/hardware-configuration.nix is missing — refusing to touch this system."

# ---------------------------------------------------------------------------
# Recover the substituted values from the installed config
# ---------------------------------------------------------------------------
read_setting() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

HOSTNAME_V="$(read_setting "$TARGET/configuration.nix" 'networking\.hostName')"
TIMEZONE_V="$(read_setting "$TARGET/configuration.nix" 'time\.timeZone')"
KEYMAP_V="$(read_setting  "$TARGET/configuration.nix" 'console\.keyMap')"
INTEL_V="$(read_setting   "$TARGET/configuration.nix" 'intelBusId')"
NVIDIA_V="$(read_setting  "$TARGET/configuration.nix" 'nvidiaBusId')"
USERNAME_V="$(read_setting "$TARGET/home.nix" 'home\.username')"

check() { [[ -n "$2" ]] || die "Could not read $1 out of $TARGET. Edit the files there by hand instead."; }
check hostname    "$HOSTNAME_V"
check username    "$USERNAME_V"
check timezone    "$TIMEZONE_V"
check keymap      "$KEYMAP_V"
check intelBusId  "$INTEL_V"
check nvidiaBusId "$NVIDIA_V"

log "Reusing the values already in $TARGET"
echo "    hostname=$HOSTNAME_V   username=$USERNAME_V   timezone=$TIMEZONE_V   keymap=$KEYMAP_V"
echo "    intelBusId=$INTEL_V   nvidiaBusId=$NVIDIA_V"

# ---------------------------------------------------------------------------
# Back up, install, substitute
# ---------------------------------------------------------------------------
BACKUP="$TARGET/backup-$(date +%Y%m%d-%H%M%S)"
log "Backing up the current config to $BACKUP"
mkdir -p "$BACKUP"
cp "$TARGET"/flake.nix "$TARGET"/configuration.nix "$TARGET"/home.nix "$BACKUP"/

log "Installing updated flake files (hardware-configuration.nix left alone)"
cp "$SCRIPT_DIR"/flake.nix "$SCRIPT_DIR"/configuration.nix "$SCRIPT_DIR"/home.nix "$TARGET"/

log "Filling in hostname/username/timezone/keymap/GPU bus IDs"
sed -i \
  -e "s/@HOSTNAME@/$HOSTNAME_V/g" \
  -e "s/@USERNAME@/$USERNAME_V/g" \
  -e "s#@TIMEZONE@#$TIMEZONE_V#g" \
  -e "s/@KEYMAP@/$KEYMAP_V/g" \
  -e "s/@INTEL_BUSID@/$INTEL_V/g" \
  -e "s/@NVIDIA_BUSID@/$NVIDIA_V/g" \
  "$TARGET"/flake.nix "$TARGET"/configuration.nix "$TARGET"/home.nix

if grep -rn '@[A-Z_]\+@' "$TARGET"/flake.nix "$TARGET"/configuration.nix "$TARGET"/home.nix; then
  warn "Unsubstituted placeholders remain (above). Restoring the backup."
  cp "$BACKUP"/flake.nix "$BACKUP"/configuration.nix "$BACKUP"/home.nix "$TARGET"/
  die "Nothing was rebuilt."
fi

# ---------------------------------------------------------------------------
# Rebuild
# ---------------------------------------------------------------------------
log "Rebuilding: nixos-rebuild switch --flake $TARGET#$HOSTNAME_V"
nixos-rebuild switch --flake "$TARGET#$HOSTNAME_V"

log "Done."
echo "    Log out of the greeter (or reboot) to get a fresh Hyprland session."
echo "    If it still misbehaves, the previous config is in $BACKUP, and the"
echo "    previous generation is still in the boot menu."
