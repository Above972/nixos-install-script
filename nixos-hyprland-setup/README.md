# NixOS + Hyprland — dual-boot Windows 11, RTX 3050 Laptop (Optimus)

A flake-based installer for a laptop that **already has Windows 11 in UEFI
mode** and an **RTX 3050 Laptop (NVIDIA Optimus: Intel iGPU + NVIDIA dGPU)**.
It installs NixOS + Hyprland alongside Windows without touching it, and sets
up NVIDIA PRIME offload so the desktop runs on the Intel iGPU (good battery
life) while individual apps can be pushed to the dGPU on demand.

**It creates and formats partitions.** It is written to only ever touch free
space, and to never format the ESP or any NTFS partition — but back up
anything important first and read `install.sh` before running it.

## What's in here

Five files, flat in one folder (no subfolders — easy to copy to a USB stick
or paste into a gist):

- `install.sh` — the installer, run from the NixOS live ISO
- `flake.nix` — nixpkgs + home-manager wiring
- `configuration.nix` — system config (NVIDIA Optimus/PRIME, Hyprland,
  greetd, pipewire, dual-boot-safe bootloader, users, packages)
- `home.nix` — the Hyprland session itself (keybinds, waybar, mako, kitty)
- `README.md` — this file

Placeholders like `@HOSTNAME@` are filled in automatically by `install.sh`;
nothing needs renaming by hand.

## Requirements

- Booted from the NixOS live ISO in **UEFI mode** (same mode Windows uses)
- Secure Boot **disabled** (proprietary NVIDIA modules won't load with it on
  unless you set up lanzaboote, which this config does not)
- Free unallocated space, or a whole spare disk, for Linux
- Working network from the live ISO

## 1. Free up space in Windows (skip if you already have a spare disk)

In Windows: **Disk Management** → right-click `C:` → **Shrink Volume** →
free up 30+ GB (60+ if you'll install games). Leave it **Unallocated** — do
not create a volume in it.

Also turn off **Fast Startup** (Control Panel → Power Options → "Choose what
the power buttons do" → uncheck "Turn on fast startup"). It leaves NTFS in a
hibernated state, which causes trouble when dual-booting.

## 2. Boot the live ISO and get networking up

```sh
sudo -i
nmtui          # or: nmcli device wifi connect "<SSID>" password "<password>"
```

Verify you can actually reach the Nix cache — the installer checks this, and
a working `ping ya.ru` does **not** prove it:

```sh
curl -sI https://cache.nixos.org/nix-cache-info | head -1
```

No response? The usual culprit is DNS:

```sh
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

## 3. Get this project onto the live system

You need a **second, ordinary USB stick** — you cannot copy files onto the
NixOS installer stick, because it was written as a raw disk image and isn't a
writable filesystem from Windows afterwards.

**Option A — second USB stick (most reliable):**

```sh
lsblk                          # find the new device: usually sda, sdb...
mkdir -p /mnt/usb
mount /dev/sda1 /mnt/usb       # use the device you actually saw
cp -r /mnt/usb/nixos-hyprland-setup ~/nixos-hyprland-setup
cd ~/nixos-hyprland-setup
```

If `mount` says **"Can't open blockdev"**, that device does not exist — the
stick isn't plugged in or wasn't detected. Run `lsblk` before and after
inserting it and compare; don't guess the name.

**Option B — download the zip (no second stick):** upload it to your own
cloud storage, then get a *direct file* link (a link to a **folder** will not
work with `curl`):

```sh
# Google Drive: share the FILE, take the ID out of .../file/d/<ID>/view
FILE_ID=<paste-the-id>
curl -L -o setup.zip "https://drive.usercontent.google.com/download?id=$FILE_ID&export=download&confirm=t"

# Always verify before unpacking:
nix-shell -p file --run "file setup.zip"     # must say "Zip archive data"
nix-shell -p unzip --run "unzip setup.zip"
cd nixos-hyprland-setup
```

If `file` says `ASCII text` or `HTML document`, the download is an error page,
not the archive — `cat setup.zip` will show you which error.

## 4. Run the installer

```sh
chmod +x install.sh
./install.sh
```

It walks through:

1. **Lists your disks** with size and model. Pick by size/model, **not by a
   remembered name** — `nvme0n1` and `nvme1n1` can and do swap between boots.
2. **Finds the existing ESP across all disks**, preferring the one that
   actually contains `/EFI/Microsoft`. Windows and Linux frequently live on
   different physical disks; the ESP is reused and never formatted.
3. **Shows every free region** and picks the largest, rounded to whole MiB.
4. **Prints the exact plan and waits for you to type `YES`.** Nothing is
   written before that.
5. Creates swap + ext4 root **inside that region only**, wipes stale
   filesystem signatures, formats, and mounts with explicit `-t ext4`/`-t vfat`.
6. Detects your Intel/NVIDIA PCI bus IDs from `lspci`, fills in the templates,
   verifies no placeholder is left, then runs `nixos-install`.
7. Prompts for your user's password.

Prompts can be pre-filled as environment variables: `DISK`, `HOSTNAME`,
`USERNAME`, `TIMEZONE`, `KEYMAP`, `SWAP_GIB` (default 8), and
`FREE_START_MIB` / `FREE_END_MIB` to override region detection.

`HOSTNAME` and `USERNAME` are only honoured when actually passed on the
command line as shown below, because bash presets variables of those names in
every shell it starts. `NIX_HOSTNAME` / `NIX_USERNAME` work too and are
unambiguous.

```sh
DISK=/dev/nvme1n1 HOSTNAME=nixhypr USERNAME=kms \
TIMEZONE=Asia/Yekaterinburg KEYMAP=us SWAP_GIB=8 ./install.sh
```

### Resuming after a failure

If it created the partitions but died later (network dropped, build failed),
**do not re-run it plainly** — it would append a second pair of partitions.
It now refuses to do that and tells you to resume instead:

```sh
SKIP_PARTITIONING=1 DISK=/dev/nvme1n1 USERNAME=kms \
  TIMEZONE=Asia/Yekaterinburg HOSTNAME=nixhypr ./install.sh
```

Resume reuses the existing root/swap (it recognises both this version's
`nixos-root`/`nixos-swap` names and older `root`/`swap` ones) and skips
straight to installing. You can also force specific devices with
`ROOT_PART=/dev/... SWAP_PART=/dev/...`.

### Reusing a disk that still has an old Linux on it

The installer only uses *unallocated* space, so an old distro filling the disk
leaves nothing free. Delete just those partitions first — check `lsblk -f` to
see which are `ext4`/`btrfs` (old Linux) versus `ntfs`/`vfat` (Windows, leave
alone):

```sh
lsblk -f
parted /dev/nvmeXn1 unit MiB print       # note the numbers to remove
parted -s /dev/nvmeXn1 rm 2              # highest number first
parted -s /dev/nvmeXn1 rm 1
parted -s /dev/nvmeXn1 unit MiB print free
```

## 5. First boot

The **systemd-boot menu** lists NixOS and Windows Boot Manager — pick NixOS.
Then `tuigreet` asks for your username and password and starts Hyprland
directly (there is no session menu).

| Key | Action |
| --- | --- |
| `SUPER+Return` | terminal (kitty) |
| `SUPER+R` | app launcher (wofi) |
| `SUPER+Q` | close window |
| `SUPER+E` | file manager |
| `SUPER+F` | fullscreen |
| `SUPER+1..5` | switch workspace |
| `SUPER+SHIFT+1..5` | move window to workspace |
| `Print` | region screenshot to clipboard |
| `SUPER+SHIFT+M` | exit Hyprland |

Run something on the dGPU:

```sh
nvidia-offload steam
nvidia-smi              # should list the RTX 3050
```

## 6. Changing the config later

Keep the flake somewhere permanent and rebuild from it:

```sh
cp -r ~/nixos-hyprland-setup ~/nixos-config
cd ~/nixos-config
# edit configuration.nix / home.nix, then:
sudo nixos-rebuild switch --flake ~/nixos-config#nixhypr
```

## NVIDIA Optimus notes

Default mode is **PRIME offload**: the desktop renders on the Intel iGPU and
`nvidia-offload <cmd>` runs one app on the dGPU.

Deliberate choices worth knowing about:

- **No global `GBM_BACKEND`/`__GLX_VENDOR_LIBRARY_NAME`.** Forcing everything
  onto the NVIDIA driver defeats offload and is a classic cause of a glitchy
  or non-starting Hyprland on Optimus laptops. `nvidia-offload` sets those per
  app instead. If you switch to sync mode, the config comments tell you which
  lines to add.
- **`open = false`** (proprietary modules). The open modules do support Ampere,
  but combined with PRIME offload it's the less-trodden path.
- **`powerManagement.finegrained = false`.** Best battery life comes from
  `true`, but it's also the most common reason `nvidia-offload` silently does
  nothing or the dGPU won't wake. Turn it on once the basics work.
- **Default kernel, not `linuxPackages_latest`.** The proprietary modules
  regularly fail to build against a brand-new kernel on unstable.
- **Software cursors** (`cursor.no_hardware_cursors`) — hardware cursors on
  NVIDIA often give an invisible or flickering pointer. This is the modern
  replacement for `WLR_NO_HARDWARE_CURSORS`, which current Hyprland ignores.

**If Hyprland is unstable on the iGPU**, switch to sync mode (everything on
the dGPU — worse battery, often more stable). In `configuration.nix`:
comment out the whole `prime.offload` block, keep
`powerManagement.finegrained = false`, uncomment `prime.sync.enable = true;`,
and add the two sync-mode env vars as described in the comments there.

**Bus IDs** are auto-detected. To check by hand:

```sh
lspci -nn | grep -E 'VGA|3D'
```

Convert the hex `bus:device.function` to decimal — `01:00.0` → `PCI:1:0:0` —
and update `configuration.nix` if they don't match.

## Not covered

- Secure Boot (would need lanzaboote)
- Hyprland wallpaper / idle / lock: `hyprpaper`, `hypridle` and `hyprlock` are
  installed but intentionally **not autostarted**, because they error out
  without config files. Add configs, then add them to `exec-once` in
  `home.nix`.
- Btrfs/LVM/encryption — this uses a plain ext4 root.

## Troubleshooting

- **"No network detected" / cache unreachable, but `ping ya.ru` works.**
  The installer checks `cache.nixos.org`, not your ISP. Usually DNS:
  `echo "nameserver 1.1.1.1" > /etc/resolv.conf`.
- **"No EFI System Partition found on any disk."** Windows isn't installed in
  UEFI mode, or you booted the ISO in legacy/CSM mode. Check firmware settings.
- **"No free space on ..."** You haven't shrunk Windows yet, or an old Linux
  still fills the disk — see "Reusing a disk that still has an old Linux".
- **"already has a 'nixos-root' partition ... Refusing to re-partition."**
  Expected on a second run. Resume with `SKIP_PARTITIONING=1` (above).
- **`mount: wrong fs type, bad option, bad superblock` / `bogus number of
  reserved sectors`.** Leftover signatures from a previous filesystem, plus
  stale udev symlinks. The installer now runs `wipefs` and mounts with an
  explicit `-t`, so this shouldn't recur. To check a partition by hand:
  `blkid /dev/nvmeXn1pY` — then mount it explicitly:
  `mount -t ext4 /dev/nvmeXn1pY /mnt`.
- **Terminal turns into garbage characters** after `cat`-ing a binary file:
  `reset`, or `echo -e '\033c'`, or `stty sane; clear`.
- **Windows missing from the boot menu.** The installer never formats the ESP,
  so this is unlikely. Use your firmware's boot picker (F12 etc.) to boot
  Windows, then from NixOS run `bootctl update`. If the installer warned that
  it couldn't find `/EFI/Microsoft` on any ESP, it may have picked a leftover
  ESP from the old Linux — check `lsblk -f` for other vfat partitions.
- **Black screen / Hyprland won't start.** Switch to a TTY with
  `Ctrl+Alt+F2`, then `journalctl -b -u greetd` and `nvidia-smi`. See the
  Optimus notes about offload vs sync mode.
- **`/boot` on a different disk than `/`.** Fine, but both disks must stay
  installed. The installer warns when this is the case.
- **Build fails pulling nixos-unstable.** Unstable moves fast; re-run, or pin
  `nixpkgs` in `flake.nix` to a specific commit (or a release branch like
  `nixos-26.05`) for reproducibility.
