# nixos-install-script

NixOS + Hyprland installer for a laptop that already runs Windows 11 in UEFI
mode, with NVIDIA Optimus (Intel iGPU + RTX 3050 Laptop).

## Quick start — everything you have to type on the live ISO

```sh
sudo -i
nmtui
nix-shell -p git --run "git clone https://github.com/Above972/nixos-install-script.git"
cd nixos-install-script/nixos-hyprland-setup
bash install.sh
```

That is the whole list. The installer asks for everything else and picks the
disk from a numbered menu, so no device path has to be typed or remembered.

If a previous attempt already created partitions, it finds them on whatever
disk they ended up on and offers to resume — answer `1`. Nothing else changes.

## Already installed, need to pull a fix

From the desktop or a TTY (`Ctrl+Alt+F2`):

```sh
git clone https://github.com/Above972/nixos-install-script.git ~/nixos-install-script
sudo bash ~/nixos-install-script/nixos-hyprland-setup/update-config.sh
```

It reuses the settings already in `/etc/nixos`, backs them up, and rebuilds.

## More

- [`nixos-hyprland-setup/`](nixos-hyprland-setup/) — the project itself
- [Full instructions](nixos-hyprland-setup/README.md) — requirements, shrinking
  Windows, NVIDIA Optimus notes, troubleshooting

`nixos-hyprland-setup_2.zip` is the same folder zipped, for machines without
git. It is generated from the files in this repo, so the two never diverge.
