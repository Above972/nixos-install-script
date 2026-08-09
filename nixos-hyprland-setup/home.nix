{ config, pkgs, inputs, ... }:

{
  home.username = "@USERNAME@";
  home.homeDirectory = "/home/@USERNAME@";
  home.stateVersion = "26.05"; # match system.stateVersion; do not bump later

  # --- Hyprland ---------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;
    settings = {
      monitor = [ ",preferred,auto,1" ];

      "$mod" = "SUPER";
      "$terminal" = "kitty";
      "$menu" = "wofi --show drun";
      "$fileManager" = "pcmanfm";

      # mako is NOT listed here on purpose: services.mako.enable below starts
      # it as a systemd user service, and a second instance from exec-once
      # would just fail. hyprpaper/hypridle are also left out until you give
      # them config files (see README) — autostarting them unconfigured just
      # produces errors at login.
      exec-once = [
        "waybar"
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
      ];

      # Software cursors. On Optimus/NVIDIA setups hardware cursors are a
      # common source of an invisible or flickering mouse pointer. This is the
      # modern replacement for the old WLR_NO_HARDWARE_CURSORS env var, which
      # current Hyprland ignores.
      cursor = {
        no_hardware_cursors = true;
      };

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        "col.active_border" = "rgba(88c0d0ee)";
        "col.inactive_border" = "rgba(595959aa)";
        layout = "dwindle";
      };

      decoration = {
        rounding = 6;
        blur = {
          enabled = true;
          size = 4;
          passes = 2;
        };
      };

      animations.enabled = true;

      input = {
        kb_layout = "@KEYMAP@";
        follow_mouse = 1;
        touchpad.natural_scroll = true;
      };

      bind = [
        "$mod, Return, exec, $terminal"
        "$mod, Q, killactive"
        "$mod SHIFT, M, exit"
        "$mod, E, exec, $fileManager"
        "$mod, V, togglefloating"
        "$mod, R, exec, $menu"
        "$mod, P, pseudo"
        "$mod, J, togglesplit"
        "$mod, F, fullscreen"
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        ", Print, exec, grim -g \"$(slurp)\" - | wl-copy"
      ];

      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
    };
  };

  # --- Status bar ---------------------------------------------------------------
  programs.waybar = {
    enable = true;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 30;
        modules-left = [ "hyprland/workspaces" ];
        modules-center = [ "clock" ];
        modules-right = [ "pulseaudio" "network" "battery" "tray" ];
      };
    };
  };

  # --- Notifications --------------------------------------------------------------
  services.mako = {
    enable = true;
  };

  # --- Terminal --------------------------------------------------------------------
  programs.kitty = {
    enable = true;
    font.size = 11;
  };

  home.packages = with pkgs; [
    firefox
  ];

  programs.home-manager.enable = true;
}
