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
- `update-config.sh` — re-applies this flake onto an already-installed system
  and rebuilds; reuses the values from `/etc/nixos`, so nothing is retyped
- `flake.nix` — nixpkgs + home-manager wiring
- `configuration.nix` — system config (NVIDIA Optimus/PRIME, Hyprland,
  greetd, pipewire, dual-boot-safe bootloader, users, packages)
- `home.nix` — the Hyprland session itself (keybinds, waybar, mako, kitty).
  Written for Hyprland's **Lua** config format (`hyprland.lua`), which
  replaced hyprlang in 0.55. Option blocks go through home-manager's
  `settings` (each attribute becomes an `hl.<name>(...)` call); keybinds are
  raw Lua in `extraConfig`, because `hl.bind` takes a dispatcher function
  call, not a string
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

**Option A — clone it (shortest, and nothing to copy):**

```sh
nix-shell -p git --run "git clone https://github.com/Above972/nixos-install-script.git"
cd nixos-install-script/nixos-hyprland-setup
```

The options below matter only when the live system has no network yet — but
note the installer needs network anyway, so fix that first if you can.

You cannot copy files onto the NixOS installer stick itself: it was written as
a raw disk image and isn't a writable filesystem from Windows afterwards. So
the offline route needs a **second, ordinary USB stick**.

**Option B — second USB stick:**

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

**Option C — download the zip without git:**

```sh
curl -L -o setup.zip https://github.com/Above972/nixos-install-script/raw/main/nixos-hyprland-setup_2.zip

# Always verify before unpacking:
nix-shell -p file --run "file setup.zip"     # must say "Zip archive data"
nix-shell -p unzip --run "unzip setup.zip"
cd nixos-hyprland-setup
```

If `file` says `ASCII text` or `HTML document`, the download is an error page,
not the archive — `cat setup.zip` will show you which error.

## 4. Run the installer

```sh
bash install.sh
```

(`bash install.sh` rather than `./install.sh` — it runs straight from a fresh
clone or unzip, with no `chmod +x` step.)

It walks through:

1. **Offers to resume** if an earlier attempt already created partitions — it
   searches every disk for them, so nothing has to be typed.
2. **Lists your disks** with size and model as a numbered menu; answer with the
   number. Pick by size/model, **not by a remembered name** — `nvme0n1` and
   `nvme1n1` can and do swap between boots, which is exactly why the menu is
   numbered and why resume searches by partition name instead of device path.
3. **Finds the existing ESP across all disks**, preferring the one that
   actually contains `/EFI/Microsoft`. Windows and Linux frequently live on
   different physical disks; the ESP is reused and never formatted.
4. **Shows every free region** and picks the largest, rounded to whole MiB.
5. **Prints the exact plan and waits for you to type `YES`.** Nothing is
   written before that.
6. Creates swap + ext4 root **inside that region only**, wipes stale
   filesystem signatures, formats, and mounts with explicit `-t ext4`/`-t vfat`.
7. Detects your Intel/NVIDIA PCI bus IDs from `lspci`, fills in the templates,
   verifies no placeholder is left, then runs `nixos-install`.
8. Prompts for your user's password.

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
just run it again:

```sh
bash install.sh
```

It searches **every disk** for the root partition it made last time, shows
where it found it, and offers to resume — answer `1`. It never silently
appends a second pair of partitions.

Searching by partition name rather than device path is deliberate: `nvme0n1`
and `nvme1n1` are assigned in probe order and swap between boots, so a path
noted down during the last attempt may point at the wrong disk on this one.

Resume reuses the existing root/swap (it recognises both this version's
`nixos-root`/`nixos-swap` names and older `root`/`swap` ones) and skips
straight to installing. To drive it non-interactively, `SKIP_PARTITIONING=1`
still works and no longer needs `DISK`:

```sh
SKIP_PARTITIONING=1 USERNAME=kms TIMEZONE=Asia/Yekaterinburg ./install.sh
```

You can also force specific devices with `ROOT_PART=/dev/... SWAP_PART=/dev/...`.

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

**To pull updates from this repo** onto an installed machine — including when
the desktop is broken and you are on a TTY (`Ctrl+Alt+F2`):

```sh
git clone https://github.com/Above972/nixos-install-script.git ~/nixos-install-script
sudo bash ~/nixos-install-script/nixos-hyprland-setup/update-config.sh
```

`update-config.sh` reads the hostname, username, timezone, keymap and GPU bus
IDs back out of `/etc/nixos` — the values `install.sh` filled in the first
time — so none of them have to be retyped and the bus IDs cannot drift from
the hardware. It backs up the current `/etc/nixos` files, refuses to rebuild
if any placeholder is left unsubstituted, and then runs `nixos-rebuild
switch`. `hardware-configuration.nix` is never touched.

To roll back: copy the files out of the backup directory it prints, or pick
the previous generation in the boot menu.

**To make your own changes**, edit `/etc/nixos/configuration.nix` and
`/etc/nixos/home.nix` directly and rebuild:

```sh
sudo nixos-rebuild switch --flake /etc/nixos#nixhypr
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
  Only reachable if you declined the resume offer and then chose that same
  disk anyway. Re-run `bash install.sh` and answer `1` at the resume prompt.
- **`error: Refusing to evaluate package 'nvidia-x11-...' because it has an
  unfree license`.** Fixed on 2026-08-09 by `nixpkgs.config.allowUnfree = true`
  in `configuration.nix`. Note that the `NIXPKGS_ALLOW_UNFREE=1` the error
  message suggests does not help here — it applies to a single nix CLI
  invocation, not to the system configuration, and flakes ignore it.
- **`The option 'programs.kitty.font.name' is used but not defined`.** Also
  fixed on 2026-08-09. `font.name` has no default in home-manager, so setting
  only `font.size` left it undefined.
- **`No space left on device` while installing the bootloader**, after the
  whole download finished. The ESP is shared with Windows and is often only
  100MiB, while each generation stores a kernel and initrd there. The
  installer now checks this before downloading anything. Lower
  `boot.loader.systemd-boot.configurationLimit`, clear out vendor directories
  in `/boot/EFI` you no longer need, or enlarge the ESP.
- **The script exits silently right after "Creating swap + root partitions".**
  A bug in versions before 2026-08-09: the loop waiting for udev to publish
  the new partitions inherited a failing exit status under `set -e` and killed
  the script instead of retrying. Update, then resume — the partitions from
  that run are fine and will be reused.
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
- **`Emergency mode tripped: a lua config error resulted in no binds being
  registered` / `hyprland.lua:5: <name> expected near '$'`.** Fixed on
  2026-08-09. Hyprland deprecated hyprlang in favour of Lua in 0.55, and
  home-manager's `configType` follows suit from `stateVersion` 26.05 — so
  hyprlang settings (`"$mod" = "SUPER"` and friends) were being written into
  `hyprland.lua`, where a leading `$` is a syntax error. `home.nix` is now
  written for Lua. Recover with `update-config.sh` above.
- **`Hyprland was started without start-hyprland`.** Also fixed on
  2026-08-09 — greetd launched the `Hyprland` binary directly instead of the
  `start-hyprland` wrapper that sets the session up.
- **`'<pkg>' has been renamed to/replaced by '<other>'`, thrown from
  `pkgs/top-level/aliases.nix`.** nixpkgs turns old package names into hard
  throws after a grace period, so a config that worked six months ago stops
  evaluating. Two of these were hit here and are fixed:
  `pkgs.greetd.tuigreet` → `pkgs.tuigreet` (moved to `pkgs/by-name`, so it is
  top-level now) and `noto-fonts-emoji` → `noto-fonts-color-emoji`. When you
  see one, the fix is in the message; the useful part of a nix trace is the
  **first** error, not the last.
- **`/boot` on a different disk than `/`.** Fine, but both disks must stay
  installed. The installer warns when this is the case.
- **Build fails pulling nixos-unstable.** Unstable moves fast; re-run, or pin
  `nixpkgs` in `flake.nix` to a specific commit (or a release branch like
  `nixos-26.05`) for reproducibility.
