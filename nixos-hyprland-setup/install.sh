#!/usr/bin/env bash
#
# NixOS + Hyprland (NVIDIA Optimus / RTX 3050 Laptop, dual-boot with Windows)
# ============================================================================
#
# Run this FROM THE NIXOS LIVE ISO (booted UEFI, network connected), on a
# machine that already has Windows installed in UEFI mode, plus free
# unallocated space (or a whole spare disk) set aside for Linux.
#
# What this script does NOT do:
#   - never wipes a disk or recreates a partition table
#   - never formats the Windows EFI System Partition (ESP) — it reuses it,
#     so systemd-boot and Windows Boot Manager share one ESP
#   - never touches NTFS partitions
#
# What it DOES do:
#   - finds the existing ESP on ANY disk (Windows and Linux may live on
#     different physical disks — common in laptops with 2x NVMe)
#   - creates swap + ext4 root inside a free region you point it at, and
#     keeps root INSIDE that region (does not run to end-of-disk, which
#     would collide with a recovery partition sitting after the free space)
#   - sets up NVIDIA PRIME offload (Intel iGPU by default, dGPU on demand
#     via `nvidia-offload <cmd>`) with auto-detected PCI bus IDs
#
# It still creates and formats partitions — back up anything important and
# read it end to end first.
#
# Usage:
#   ./install.sh
#
# Non-interactive:
#   DISK=/dev/nvme1n1 HOSTNAME=nixhypr USERNAME=kms \
#   TIMEZONE=Asia/Yekaterinburg KEYMAP=us SWAP_GIB=8 ./install.sh
#
# Resume after a failure (partitions already created — do NOT re-partition):
#   ./install.sh          — it finds the earlier root on any disk and offers
#                           to resume; answer [1]. No device path to retype,
#                           which matters because disk names change between
#                           boots.
#   Forcing it non-interactively still works:
#   SKIP_PARTITIONING=1 USERNAME=kms TIMEZONE=Asia/Yekaterinburg ./install.sh
#
# Run from inside the project directory (same folder as flake.nix).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

export NIX_CONFIG="experimental-features = nix-command flakes"

SWAP_LABEL="nixos-swap"
ROOT_LABEL="nixos-root"

[[ $EUID -eq 0 ]] || die "Run as root ('sudo -i', then re-run)."
command -v nixos-install >/dev/null 2>&1 || die "nixos-install not found — this doesn't look like a NixOS live environment."
for f in flake.nix configuration.nix home.nix; do
  [[ -f "$SCRIPT_DIR/$f" ]] || die "$f not found next to install.sh. cd into the project directory first."
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# parted reports free-space offsets as fractions (e.g. "0.02MiB"), which bash
# arithmetic cannot handle at all — hence ceil/floor via awk.
ceil()  { awk -v x="$1" 'BEGIN { printf "%d", (x == int(x) ? x : int(x) + 1) }'; }
floor() { awk -v x="$1" 'BEGIN { printf "%d", int(x) }'; }

# Partition metadata is read with `blkid -p`, which probes the GPT directly on
# disk, instead of lsblk's PARTLABEL/PARTTYPE columns, which come from udev.
# udev data can be stale right after repartitioning — that is exactly what
# makes /dev/disk/by-partlabel/* point at the wrong device and produces
# "wrong fs type / bogus number of reserved sectors" on mount.
disk_parts() {
  lsblk -lno PATH,TYPE "$1" 2>/dev/null | awk '$2 == "part" { print $1 }'
}

part_entry_type() {
  blkid -p -o value -s PART_ENTRY_TYPE "$1" 2>/dev/null \
    || lsblk -no PARTTYPE "$1" 2>/dev/null | head -n1
}

part_entry_name() {
  blkid -p -o value -s PART_ENTRY_NAME "$1" 2>/dev/null \
    || lsblk -no PARTLABEL "$1" 2>/dev/null | head -n1
}

all_disks() { lsblk -dlno PATH,TYPE | awk '$2 == "disk" { print $1 }'; }

# Locate a root partition left behind by an earlier run of this script, on ANY
# disk. Kernel disk names (nvme0n1 vs nvme1n1) are assigned in probe order and
# genuinely swap between boots, so a device path written down during the last
# attempt cannot be trusted on this one. The partition itself carries a stable
# GPT name, so search by that and derive the disk from whatever it is on now.
find_existing_root() {
  local d p fstype fslabel
  for d in $(all_disks); do
    for p in $(disk_parts "$d"); do
      if [[ "$(part_entry_name "$p")" == "$ROOT_LABEL" ]]; then
        printf '%s' "$p"
        return 0
      fi
    done
  done
  # Older versions of this script used the GPT name "root" and only set the
  # ext4 filesystem label, so fall back to probing for that.
  for d in $(all_disks); do
    for p in $(disk_parts "$d"); do
      fstype="$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)"
      fslabel="$(blkid -p -o value -s LABEL "$p" 2>/dev/null || true)"
      if [[ "$fstype" == "ext4" && "$fslabel" == "nixos" ]]; then
        printf '%s' "$p"
        return 0
      fi
    done
  done
  return 1
}

disk_of() { printf '/dev/%s' "$(lsblk -no PKNAME "$1")"; }

# Resolve a partition on a specific disk by its GPT partition name.
part_by_label() {
  local disk="$1" label="$2" p
  for p in $(disk_parts "$disk"); do
    if [[ "$(part_entry_name "$p")" == "$label" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 0. Sanity: UEFI + network
# ---------------------------------------------------------------------------
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. UEFI + systemd-boot is required to dual-boot cleanly with Windows."

# Check the binary cache (where packages actually come from), not nixos.org —
# the website can be unreachable while the CDN works fine, and vice versa.
log "Checking network access to the Nix binary cache"
if ! curl -sfI --max-time 10 https://cache.nixos.org/nix-cache-info >/dev/null 2>&1; then
  warn "Could not reach https://cache.nixos.org"
  echo "    Common causes and fixes:"
  echo "      - not connected:  nmtui"
  echo "      - broken DNS:     echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
  echo "      - ISP blocking:   you may need a VPN"
  echo
  read -rp "Continue anyway? [y/N]: " NET_OK
  [[ "${NET_OK,,}" == "y" ]] || die "Aborted. Fix networking and re-run."
else
  log "Binary cache reachable."
fi

# ---------------------------------------------------------------------------
# 1. Gather configuration
# ---------------------------------------------------------------------------
DISK="${DISK:-}"
SKIP_PARTITIONING="${SKIP_PARTITIONING:-0}"
ROOT_PART="${ROOT_PART:-}"
SWAP_PART="${SWAP_PART:-}"

# --- Offer to resume an earlier attempt -------------------------------------
# A previous run that died after partitioning leaves a usable root behind.
# Finding it automatically matters more than it looks: the alternative is the
# operator retyping a device path from notes, and that path may point at a
# different disk after a reboot.
if [[ "$SKIP_PARTITIONING" != "1" && -z "$ROOT_PART" && -z "$DISK" ]]; then
  FOUND_ROOT="$(find_existing_root || true)"
  if [[ -n "$FOUND_ROOT" ]]; then
    FOUND_DISK="$(disk_of "$FOUND_ROOT")"
    warn "Found a NixOS root partition from an earlier attempt:"
    echo "    $FOUND_ROOT  (on $FOUND_DISK)"
    echo
    echo "    [1] Resume — install onto it, create no partitions (recommended)"
    echo "    [2] Ignore it and partition a disk from scratch"
    echo
    read -rp "Choice [1]: " RESUME_CHOICE
    if [[ -z "$RESUME_CHOICE" || "$RESUME_CHOICE" == "1" ]]; then
      SKIP_PARTITIONING=1
      ROOT_PART="$FOUND_ROOT"
      DISK="$FOUND_DISK"
      log "Resuming on $ROOT_PART — nothing will be repartitioned."
    fi
  fi
fi

# --- Pick the target disk ---------------------------------------------------
if [[ "$SKIP_PARTITIONING" == "1" ]]; then
  # On resume the disk name is not information the operator needs to supply:
  # the partition is found by its GPT name and the disk follows from it.
  if [[ -z "$DISK" ]]; then
    [[ -n "$ROOT_PART" ]] || ROOT_PART="$(find_existing_root || true)"
    [[ -b "${ROOT_PART:-}" ]] \
      || die "SKIP_PARTITIONING=1 but no existing NixOS root was found on any disk. Pass ROOT_PART=/dev/... explicitly."
    DISK="$(disk_of "$ROOT_PART")"
    log "Existing root $ROOT_PART is on $DISK"
  fi
elif [[ -z "$DISK" ]]; then
  log "Available disks:"
  DISK_LIST=()
  while read -r dpath dsize dmodel; do
    DISK_LIST+=("$dpath")
    printf '    [%d] %-16s %-9s %s\n' "${#DISK_LIST[@]}" "$dpath" "$dsize" "$dmodel"
  done < <(lsblk -dpno NAME,SIZE,MODEL | grep -v '^/dev/loop' || true)
  [[ ${#DISK_LIST[@]} -gt 0 ]] || die "No disks detected."
  echo
  warn "Disk names (nvme0n1 vs nvme1n1) can SWAP BETWEEN BOOTS. Pick by SIZE"
  echo "    and MODEL above, not by a name you remember from last time."
  echo
  read -rp "Disk to install NixOS onto — number [1-${#DISK_LIST[@]}], or a full /dev/... path: " DISK_CHOICE
  if [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]]; then
    (( DISK_CHOICE >= 1 && DISK_CHOICE <= ${#DISK_LIST[@]} )) \
      || die "There is no disk [$DISK_CHOICE] in the list above."
    DISK="${DISK_LIST[$(( DISK_CHOICE - 1 ))]}"
    log "Selected $DISK"
  else
    DISK="$DISK_CHOICE"
  fi
fi
[[ -b "$DISK" ]] || die "$DISK is not a block device."

# HOSTNAME and USERNAME cannot be read as plain shell variables here. Bash
# sets HOSTNAME in every shell it starts (to the live ISO's name, "nixos"),
# and some environments preset USERNAME the same way — so "${HOSTNAME:-}"
# is never empty, the prompt below gets skipped, and the machine silently
# installs as "nixos" without ever asking.
#
# An explicit `HOSTNAME=... ./install.sh` still has to work, though, and the
# only thing separating that from bash's own copy is that the caller's value
# lives in the ENVIRONMENT while bash's is a shell variable. printenv sees
# only the former, so it is what tells the two apart.
env_or_empty() { printenv "$1" 2>/dev/null || true; }

NIX_HOSTNAME="${NIX_HOSTNAME:-$(env_or_empty HOSTNAME)}"
[[ -z "$NIX_HOSTNAME" ]] && read -rp "Hostname [nixhypr]: " NIX_HOSTNAME
NIX_HOSTNAME="${NIX_HOSTNAME:-nixhypr}"

NIX_USERNAME="${NIX_USERNAME:-$(env_or_empty USERNAME)}"
[[ -z "$NIX_USERNAME" ]] && read -rp "Username to create: " NIX_USERNAME
[[ -n "$NIX_USERNAME" ]] || die "Username cannot be empty."
[[ "$NIX_USERNAME" != "root" ]] || die "Username cannot be 'root' — this creates a normal user account."

TIMEZONE="${TIMEZONE:-}"
[[ -z "$TIMEZONE" ]] && read -rp "Timezone [Etc/UTC] (e.g. Asia/Yekaterinburg): " TIMEZONE
TIMEZONE="${TIMEZONE:-Etc/UTC}"

KEYMAP="${KEYMAP:-us}"
SWAP_GIB="${SWAP_GIB:-8}"
# NB: SKIP_PARTITIONING is set far above, before the disk is chosen — the
# resume prompt may have turned it on, so do not re-default it here.

# ---------------------------------------------------------------------------
# 2. Find the existing ESP — on ANY disk, not just the target one.
#    Windows and Linux often sit on different physical disks.
# ---------------------------------------------------------------------------
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

log "Looking for an existing EFI System Partition (all disks)"

# Collect every ESP on every disk. Windows and Linux commonly live on
# different physical disks in dual-NVMe laptops, so we must not restrict the
# search to $DISK.
ESP_CANDIDATES=()
for d in $(lsblk -dlno PATH,TYPE | awk '$2 == "disk" { print $1 }'); do
  for p in $(disk_parts "$d"); do
    [[ "$(part_entry_type "$p")" == "$ESP_GUID" ]] && ESP_CANDIDATES+=("$p")
  done
done
[[ ${#ESP_CANDIDATES[@]} -gt 0 ]] \
  || die "No EFI System Partition found on any disk. Is Windows installed in UEFI mode?"

# Prefer the ESP that actually holds the Windows bootloader, so we don't pick
# a leftover ESP from a previous Linux install and end up with a boot menu
# that has no Windows entry.
ESP_PART=""
for cand in "${ESP_CANDIDATES[@]}"; do
  probe="$(mktemp -d)"
  found=0
  if mount -t vfat -o ro "$cand" "$probe" 2>/dev/null; then
    [[ -d "$probe/EFI/Microsoft" ]] && found=1
    # Every cleanup step here is non-fatal on purpose: this is only a probe,
    # and a failed umount must never abort the install via `set -e`.
    umount "$probe" 2>/dev/null || true
  fi
  rmdir "$probe" 2>/dev/null || true
  if (( found )); then
    ESP_PART="$cand"
    log "Picked $cand — it contains the Windows bootloader (/EFI/Microsoft)."
    break
  fi
done

# No Windows bootloader found on any ESP: prefer one on the target disk,
# else just take the first.
if [[ -z "$ESP_PART" ]]; then
  for cand in "${ESP_CANDIDATES[@]}"; do
    if [[ "/dev/$(lsblk -no PKNAME "$cand" 2>/dev/null)" == "$DISK" ]]; then
      ESP_PART="$cand"
      break
    fi
  done
  ESP_PART="${ESP_PART:-${ESP_CANDIDATES[0]}}"
  warn "No /EFI/Microsoft found on any ESP — using $ESP_PART."
  echo "    If Windows is missing from the boot menu afterwards, you picked the"
  echo "    wrong ESP; candidates were: ${ESP_CANDIDATES[*]}"
fi

[[ -n "$ESP_PART" && -b "$ESP_PART" ]] \
  || die "No EFI System Partition found on any disk. Is Windows installed in UEFI mode?"

ESP_DISK="/dev/$(lsblk -no PKNAME "$ESP_PART")"
log "Using EFI System Partition: $ESP_PART (on $ESP_DISK) — reused, NOT formatted"
if [[ "$ESP_DISK" != "$DISK" ]]; then
  warn "The ESP is on a DIFFERENT disk ($ESP_DISK) than your NixOS root ($DISK)."
  echo "    This works fine, but both disks must stay installed for NixOS to boot."
fi

# ---------------------------------------------------------------------------
# 3. Partition (or reuse existing partitions on resume)
# ---------------------------------------------------------------------------
if [[ "$SKIP_PARTITIONING" == "1" ]]; then
  log "SKIP_PARTITIONING=1 — reusing existing partitions, creating nothing"
  SWAP_PART="${SWAP_PART:-$(part_by_label "$DISK" "$SWAP_LABEL" || true)}"
  ROOT_PART="${ROOT_PART:-$(part_by_label "$DISK" "$ROOT_LABEL" || true)}"

  # Fall back to probing filesystems directly on each partition of $DISK. This
  # also picks up partitions made by an older version of this script, which
  # used the GPT names "swap"/"root" and filesystem labels "swap"/"nixos".
  for p in $(disk_parts "$DISK"); do
    fstype="$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)"
    fslabel="$(blkid -p -o value -s LABEL "$p" 2>/dev/null || true)"
    if [[ -z "$ROOT_PART" && "$fstype" == "ext4" && "$fslabel" == "nixos" ]]; then
      ROOT_PART="$p"
    fi
    if [[ -z "$SWAP_PART" && "$fstype" == "swap" ]]; then
      SWAP_PART="$p"
    fi
  done

  [[ -b "${ROOT_PART:-}" ]] \
    || die "Could not find an existing ext4 root (LABEL=nixos) on $DISK. Pass ROOT_PART=/dev/... explicitly."
  log "Reusing root: $ROOT_PART   swap: ${SWAP_PART:-<none>}"
else
  # Guard against a partial re-run. If this script already created partitions
  # on this disk, running it again would append a SECOND pair and could then
  # format the wrong one. Resume instead of re-partitioning.
  EXISTING_ROOT="$(part_by_label "$DISK" "$ROOT_LABEL" || true)"
  if [[ -n "$EXISTING_ROOT" ]]; then
    warn "$DISK already has a '$ROOT_LABEL' partition ($EXISTING_ROOT) from an earlier run."
    echo "    Creating another pair would risk formatting the wrong partition."
    echo
    echo "    To continue the install using what already exists, just re-run"
    echo "      ./install.sh"
    echo "    and answer [1] when it offers to resume."
    echo
    echo "    To start over instead, delete those partitions first with:"
    echo "      parted $DISK print        # note the numbers"
    echo "      parted $DISK rm <number>  # swap and root only"
    die "Refusing to re-partition $DISK."
  fi

  log "Current partition table on $DISK:"
  parted -s "$DISK" unit MiB print || true

  log "Free space on $DISK:"
  FREE_TABLE="$(parted -s "$DISK" unit MiB print free 2>/dev/null \
    | awk '/Free Space/ { gsub("MiB",""); print $1, $2, $3 }')"
  [[ -n "$FREE_TABLE" ]] || die "No free space on $DISK. Shrink Windows (Disk Management -> Shrink Volume) or free up a disk first."
  printf '    %s\n' "$FREE_TABLE"

  # Largest free region wins.
  BEST="$(printf '%s\n' "$FREE_TABLE" | sort -k3 -g -r | head -n1)"
  RAW_START="$(echo "$BEST" | awk '{print $1}')"
  RAW_END="$(echo "$BEST" | awk '{print $2}')"

  # Round inward so we always land on whole MiB inside the free region.
  FREE_START_MIB="${FREE_START_MIB:-$(ceil "$RAW_START")}"
  FREE_END_MIB="${FREE_END_MIB:-$(floor "$RAW_END")}"
  # 1MiB is the smallest sane alignment; parted dislikes starting at 0.
  (( FREE_START_MIB < 1 )) && FREE_START_MIB=1

  AVAIL_MIB=$(( FREE_END_MIB - FREE_START_MIB ))
  (( AVAIL_MIB > 0 )) || die "Free region is empty after alignment (start=$FREE_START_MIB end=$FREE_END_MIB)."

  SWAP_MIB=$(( SWAP_GIB * 1024 ))
  # Leave at least 15GiB for root, otherwise shrink or drop swap.
  MIN_ROOT_MIB=$(( 15 * 1024 ))
  if (( AVAIL_MIB < MIN_ROOT_MIB )); then
    die "Only ${AVAIL_MIB}MiB free — need at least ${MIN_ROOT_MIB}MiB for root. Free up more space."
  fi
  if (( SWAP_MIB + MIN_ROOT_MIB > AVAIL_MIB )); then
    SWAP_MIB=$(( AVAIL_MIB - MIN_ROOT_MIB ))
    warn "Not enough room for ${SWAP_GIB}GiB swap — shrinking swap to $(( SWAP_MIB / 1024 ))GiB."
  fi
  SWAP_END_MIB=$(( FREE_START_MIB + SWAP_MIB ))

  # Where root should end.
  #
  # Two cases, and getting this wrong breaks the install either way:
  #   - free space is in the MIDDLE of the disk (typical after shrinking
  #     Windows, with a recovery partition still sitting at the end): root
  #     must stop at the region end. Using "100%" here would try to run over
  #     that trailing partition.
  #   - free space runs to the END of the disk (typical when the whole disk is
  #     free): parted REPORTS free space all the way to the device end, but
  #     refuses to create a partition there, because GPT reserves the last
  #     sectors for its backup header ("The location NNN is outside of the
  #     device"). Only "100%" lets parted pick the real maximum.
  DISK_SIZE_MIB="$(parted -s "$DISK" unit MiB print 2>/dev/null \
    | awk '/^Disk \// && /MiB/ { gsub(/MiB/, "", $3); print $3; exit }')"
  DISK_SIZE_MIB="${DISK_SIZE_MIB%%.*}"

  if [[ -n "$DISK_SIZE_MIB" ]] && (( FREE_END_MIB >= DISK_SIZE_MIB - 2 )); then
    ROOT_END_SPEC="100%"
    ROOT_END_DESC="end of disk"
  else
    ROOT_END_SPEC="${FREE_END_MIB}MiB"
    ROOT_END_DESC="${FREE_END_MIB}MiB (end of the free region)"
  fi

  echo
  warn "About to create NEW partitions on $DISK (inside free space only):"
  echo "    swap: ${FREE_START_MIB}MiB -> ${SWAP_END_MIB}MiB  ($(( SWAP_MIB / 1024 ))GiB)"
  echo "    root: ${SWAP_END_MIB}MiB -> ${ROOT_END_DESC}  (~$(( (FREE_END_MIB - SWAP_END_MIB) / 1024 ))GiB, ext4)"
  warn "Windows partitions and the ESP ($ESP_PART) are NOT touched."
  echo
  read -rp "Type YES (all caps) to continue: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || die "Aborted, nothing was written."

  log "Creating swap + root partitions"
  parted -s -a optimal "$DISK" -- \
    mkpart "$SWAP_LABEL" linux-swap "${FREE_START_MIB}MiB" "${SWAP_END_MIB}MiB" \
    mkpart "$ROOT_LABEL" ext4 "${SWAP_END_MIB}MiB" "$ROOT_END_SPEC"

  partprobe "$DISK" || true
  udevadm settle || true

  # `|| true` is load-bearing: part_by_label returns 1 until udev has caught up
  # with the new partitions, and under `set -e` an assignment inherits that
  # exit status — so without it the script dies on the first iteration, in
  # exactly the case this retry loop exists to handle.
  SWAP_PART=""; ROOT_PART=""
  for _ in $(seq 1 15); do
    SWAP_PART="$(part_by_label "$DISK" "$SWAP_LABEL" || true)"
    ROOT_PART="$(part_by_label "$DISK" "$ROOT_LABEL" || true)"
    [[ -b "${SWAP_PART:-}" && -b "${ROOT_PART:-}" ]] && break
    sleep 1
    udevadm settle || true
  done
  [[ -b "${SWAP_PART:-}" ]] || die "New swap partition did not appear on $DISK."
  [[ -b "${ROOT_PART:-}" ]] || die "New root partition did not appear on $DISK."
  log "New partitions: swap=$SWAP_PART root=$ROOT_PART"

  # Wipe stale filesystem signatures. Without this, leftover vfat/btrfs magic
  # from a previous OS can make `mount` autodetect the WRONG filesystem and
  # fail with "wrong fs type / bogus number of reserved sectors".
  log "Wiping stale filesystem signatures on the new partitions"
  wipefs -af "$SWAP_PART"
  wipefs -af "$ROOT_PART"
  udevadm settle || true

  log "Formatting swap + root (ESP and Windows untouched)"
  mkswap -L swap "$SWAP_PART"
  mkfs.ext4 -F -L nixos "$ROOT_PART"
  udevadm settle || true
fi

# ---------------------------------------------------------------------------
# 4. Mount — always with an explicit filesystem type, never autodetect.
# ---------------------------------------------------------------------------
log "Mounting filesystems"
mountpoint -q /mnt && umount -R /mnt || true
mount -t ext4 "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount -t vfat -o umask=0077 "$ESP_PART" /mnt/boot
if [[ -n "${SWAP_PART:-}" && -b "${SWAP_PART:-}" ]]; then
  swapon "$SWAP_PART" 2>/dev/null || warn "Could not enable swap on $SWAP_PART (continuing)."
fi
log "Mounted: / -> $ROOT_PART   /boot -> $ESP_PART"

# Check the ESP has room BEFORE nixos-install spends an hour downloading.
# Windows ESPs are routinely 100MiB, and every NixOS generation puts a kernel
# and an NVIDIA-laden initrd there. Running out shows up at the very end as
# "No space left on device" while installing the bootloader.
esp_df_mib() { df -BM --output="$1" /mnt/boot 2>/dev/null | tail -n1 | tr -dc '0-9'; }
ESP_SIZE_MIB="$(esp_df_mib size)"; ESP_SIZE_MIB="${ESP_SIZE_MIB:-0}"
ESP_FREE_MIB="$(esp_df_mib avail)"; ESP_FREE_MIB="${ESP_FREE_MIB:-0}"
if (( ESP_SIZE_MIB > 0 )); then
  log "ESP capacity: ${ESP_SIZE_MIB}MiB total, ${ESP_FREE_MIB}MiB free"
  if (( ESP_FREE_MIB < 300 )); then
    warn "Only ${ESP_FREE_MIB}MiB free on the shared ESP — that is tight."
    echo "    Each generation needs roughly 100MiB of kernel + initrd here."
    echo "    Ways to make it fit, in order of least effort:"
    echo "      - lower boot.loader.systemd-boot.configurationLimit in"
    echo "        configuration.nix (currently 10) to 2, and re-run this script"
    echo "      - remove leftover vendor directories under /mnt/boot/EFI from"
    echo "        operating systems you no longer have (never EFI/Microsoft)"
    echo "      - enlarge the ESP with a partition editor"
    echo
    read -rp "Continue anyway? [y/N]: " ESP_OK
    [[ "${ESP_OK,,}" == "y" ]] || die "Aborted before downloading anything."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Detect Intel/NVIDIA PCI bus IDs for PRIME offload
# ---------------------------------------------------------------------------
pci_addr_to_nix() {
  # "0000:01:00.0" -> "PCI:1:0:0" (nix wants decimal)
  local addr="$1" bus devfn dev func
  bus="$(echo "$addr" | cut -d: -f2)"
  devfn="$(echo "$addr" | cut -d: -f3)"
  dev="$(echo "$devfn" | cut -d. -f1)"
  func="$(echo "$devfn" | cut -d. -f2)"
  printf 'PCI:%d:%d:%d' "0x$bus" "0x$dev" "0x$func"
}

find_gpu_addr() {
  lspci -Dnn 2>/dev/null \
    | grep -E 'VGA compatible controller|3D controller' \
    | grep -i "\[$1:" | head -n1 | awk '{print $1}'
}

INTEL_ADDR="$(find_gpu_addr 8086 || true)"
NVIDIA_ADDR="$(find_gpu_addr 10de || true)"

if [[ -n "$INTEL_ADDR" ]]; then
  INTEL_BUSID="$(pci_addr_to_nix "$INTEL_ADDR")"
else
  INTEL_BUSID="PCI:0:2:0"
  warn "Intel iGPU not auto-detected — defaulting intelBusId to $INTEL_BUSID. Verify with 'lspci | grep -E \"VGA|3D\"'."
fi

if [[ -n "$NVIDIA_ADDR" ]]; then
  NVIDIA_BUSID="$(pci_addr_to_nix "$NVIDIA_ADDR")"
else
  NVIDIA_BUSID="PCI:1:0:0"
  warn "NVIDIA dGPU not auto-detected — defaulting nvidiaBusId to $NVIDIA_BUSID. Verify with 'lspci | grep -E \"VGA|3D\"'."
fi

log "GPU bus IDs — Intel: $INTEL_BUSID   NVIDIA: $NVIDIA_BUSID"

# ---------------------------------------------------------------------------
# 6. Generate hardware config, drop the flake in, fill templates
# ---------------------------------------------------------------------------
log "Generating hardware-configuration.nix"
nixos-generate-config --root /mnt

log "Installing flake files into /mnt/etc/nixos (keeping hardware-configuration.nix)"
cp "$SCRIPT_DIR"/flake.nix "$SCRIPT_DIR"/configuration.nix "$SCRIPT_DIR"/home.nix /mnt/etc/nixos/

log "Filling in hostname/username/timezone/keymap/GPU bus IDs"
sed -i \
  -e "s/@HOSTNAME@/$NIX_HOSTNAME/g" \
  -e "s/@USERNAME@/$NIX_USERNAME/g" \
  -e "s#@TIMEZONE@#$TIMEZONE#g" \
  -e "s/@KEYMAP@/$KEYMAP/g" \
  -e "s/@INTEL_BUSID@/$INTEL_BUSID/g" \
  -e "s/@NVIDIA_BUSID@/$NVIDIA_BUSID/g" \
  /mnt/etc/nixos/flake.nix \
  /mnt/etc/nixos/configuration.nix \
  /mnt/etc/nixos/home.nix

# Fail early on leftover placeholders rather than deep inside a nix build.
if grep -rn '@[A-Z_]\+@' /mnt/etc/nixos/flake.nix /mnt/etc/nixos/configuration.nix /mnt/etc/nixos/home.nix; then
  die "Unsubstituted placeholders remain (see above) — aborting before install."
fi

# ---------------------------------------------------------------------------
# 7. Install
# ---------------------------------------------------------------------------
log "Running nixos-install (downloads a lot — can take 10 minutes to an hour)"
nixos-install --root /mnt --flake /mnt/etc/nixos#"$NIX_HOSTNAME" --no-root-passwd

log "Set a login password for $NIX_USERNAME"
nixos-enter --root /mnt -c "passwd $NIX_USERNAME"

log "Done."
echo "    Reboot, remove the install media, and pick NixOS in the systemd-boot menu"
echo "    (Windows Boot Manager is auto-detected on the shared ESP)."
echo "    tuigreet asks for your username ($NIX_USERNAME) and password, then starts"
echo "    Hyprland directly — there is no session menu to pick from."
echo "    In Hyprland: SUPER+Return = terminal, SUPER+R = launcher, SUPER+Q = close."
if [[ "$ESP_DISK" != "$DISK" ]]; then
  echo
  echo "    Reminder: /boot lives on $ESP_DISK while / lives on $DISK — keep both installed."
fi
