{ config, pkgs, inputs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # --- Boot (dual-boot with Windows on a shared EFI System Partition) --------
  # install.sh mounts the EXISTING Windows ESP at /boot instead of creating
  # a new one. systemd-boot auto-detects Windows Boot Manager already on
  # that ESP and lists it in the boot menu alongside NixOS.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10; # don't let /boot fill up with old generations
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;
  # Deliberately using the DEFAULT kernel, not linuxPackages_latest: the
  # proprietary NVIDIA modules regularly fail to build against a brand-new
  # kernel on unstable. Uncomment below only if you need newer hardware
  # support and are willing to debug driver build failures.
  # boot.kernelPackages = pkgs.linuxPackages_latest;

  # --- Networking -------------------------------------------------------------
  networking.hostName = "@HOSTNAME@";
  networking.networkmanager.enable = true;

  # --- Locale / time ------------------------------------------------------------
  time.timeZone = "@TIMEZONE@";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "@KEYMAP@";

  # --- Unfree packages ----------------------------------------------------------
  # The proprietary NVIDIA driver is unfree, so without this nixos-install dies
  # during evaluation with "Refusing to evaluate package 'nvidia-x11-...'
  # because it has an unfree license (unfreeRedistributable)".
  # NIXPKGS_ALLOW_UNFREE=1 is NOT a substitute: it covers one invocation of the
  # nix CLI, not the system configuration, and flakes ignore it entirely.
  # To be stricter, replace this with a predicate allowing only the driver:
  #   nixpkgs.config.allowUnfreePredicate = pkg:
  #     builtins.elem (pkgs.lib.getName pkg) [ "nvidia-x11" "nvidia-settings" ];
  nixpkgs.config.allowUnfree = true;

  # --- NVIDIA (RTX 3050 Laptop + Intel iGPU = Optimus hybrid graphics) --------
  # `open = false` (proprietary kernel modules) is the safer default for a
  # laptop Optimus setup — the open modules (Turing+, which covers Ampere/
  # RTX 3050) are supported but PRIME offload + open modules is a newer,
  # less battle-tested combo. Try `open = true` if you want to experiment.
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # needed for Steam / 32-bit games
    extraPackages = with pkgs; [
      intel-media-driver # VA-API hardware video decode on the Intel iGPU
    ];
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true; # required for Wayland/Hyprland
    powerManagement.enable = true; # recommended on laptops: proper suspend/resume
    # finegrained fully powers the dGPU down when idle (best battery life), but
    # it is a common cause of "nvidia-offload does nothing" / dGPU failing to
    # wake. Left OFF for reliability — turn it on once the basics work.
    # It REQUIRES prime.offload.enable, so keep it false in sync mode.
    powerManagement.finegrained = false;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # --- PRIME offload: Hyprland runs on the Intel iGPU (battery-friendly),
    # heavy apps get launched on the NVIDIA dGPU with `nvidia-offload <cmd>`
    # (the wrapper script is generated automatically by enableOffloadCmd).
    # Bus IDs below are auto-filled by install.sh from `lspci` on your
    # machine — double check them against `lspci | grep -E 'VGA|3D'` if
    # anything GPU-related misbehaves.
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      intelBusId = "@INTEL_BUSID@";
      nvidiaBusId = "@NVIDIA_BUSID@";
    };

    # --- Alternative: "sync" mode instead of offload -----------------------
    # If Hyprland is unstable/glitchy on the Intel iGPU (a known rough edge
    # with some wlroots + Optimus combos), run everything on the NVIDIA dGPU
    # instead. To switch:
    #   1. comment out the whole `prime.offload` block above
    #   2. set `powerManagement.finegrained = false` above (required)
    #   3. uncomment the line below
    #   4. uncomment the sync-mode env vars further down
    # Trades battery life for stability.
    # prime.sync.enable = true;
  };

  # NOTE: in PRIME *offload* mode you must NOT globally force everything onto
  # the NVIDIA driver — that defeats offload and is a classic cause of a
  # broken or glitchy Hyprland session on Optimus laptops. The desktop renders
  # on the Intel iGPU, and the `nvidia-offload` wrapper sets the NVIDIA env
  # vars per-application (__NV_PRIME_RENDER_OFFLOAD, __GLX_VENDOR_LIBRARY_NAME,
  # etc.) only for the app you launch with it.
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1"; # Wayland for Chromium/Electron apps
    LIBVA_DRIVER_NAME = "iHD"; # video decode on the Intel iGPU

    # --- Only if you switched to prime.sync.enable above ---
    # Add these two lines, and change LIBVA_DRIVER_NAME above from "iHD" to
    # "nvidia" (do not add a second LIBVA_DRIVER_NAME — Nix rejects duplicate
    # attribute names in the same set).
    # GBM_BACKEND = "nvidia-drm";
    # __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };

  # --- Hyprland ---------------------------------------------------------------
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    configPackages = [ pkgs.hyprland ];
  };

  # --- Login manager: greetd + tuigreet, launches Hyprland directly -----------
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd Hyprland";
        user = "greeter";
      };
    };
  };

  # --- Audio: pipewire ----------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # --- Users --------------------------------------------------------------------
  users.users."@USERNAME@" = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;

  # --- System packages ------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    kitty
    waybar
    wofi
    mako
    hyprpaper
    hyprlock
    hypridle
    pcmanfm
    grim
    slurp
    wl-clipboard
    polkit_gnome
    networkmanagerapplet
    pavucontrol
    brightnessctl
  ];

  security.polkit.enable = true;

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-emoji
    nerd-fonts.jetbrains-mono
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "@USERNAME@" ];

  # Should match the NixOS release you first installed from (your ISO says
  # 26.05). Do NOT bump this later — it only exists to keep stateful defaults
  # stable across upgrades.
  system.stateVersion = "26.05";
}
