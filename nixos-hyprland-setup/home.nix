{ config, pkgs, inputs, ... }:

{
  home.username = "@USERNAME@";
  home.homeDirectory = "/home/@USERNAME@";
  home.stateVersion = "26.05"; # match system.stateVersion; do not bump later

  # --- Hyprland ---------------------------------------------------------------
  wayland.windowManager.hyprland = {
    enable = true;
    xwayland.enable = true;

    # Hyprland deprecated hyprlang in favour of Lua in 0.55, and home-manager
    # follows: this option defaults to "lua" from stateVersion 26.05 onwards.
    # Set it explicitly so the format never depends on stateVersion drifting.
    configType = "lua";

    # In lua mode each attribute here becomes an `hl.<name>(<args>)` call, with
    # strings rendered as quoted Lua strings. That fits declarative option
    # blocks, so `hl.config` and `hl.monitor` live here. It does NOT fit
    # keybinds: `hl.bind` takes a dispatcher *function call* as its second
    # argument, and anything written as a Nix string would come out quoted and
    # inert. Those go in extraConfig below, as real Lua.
    #
    # There is no "$mod" any more — that was hyprlang. Lua uses ordinary
    # locals, declared in extraConfig.
    settings = {
      monitor = {
        output = "";
        mode = "preferred";
        position = "auto";
        scale = "auto";
      };

      config = {
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
      };
    };

    # Raw Lua, appended verbatim to hyprland.lua.
    #
    # Everything below uses call shapes taken from Hyprland's own shipped
    # example config (example/hyprland.lua), not guessed.
    extraConfig = ''
      local mainMod     = "SUPER"
      local terminal    = "kitty"
      local menu        = "wofi --show drun"
      local fileManager = "pcmanfm"

      hl.bind(mainMod .. " + Return",    hl.dsp.exec_cmd(terminal))
      hl.bind(mainMod .. " + E",         hl.dsp.exec_cmd(fileManager))
      hl.bind(mainMod .. " + R",         hl.dsp.exec_cmd(menu))
      hl.bind(mainMod .. " + Q",         hl.dsp.window.close())
      hl.bind(mainMod .. " + V",         hl.dsp.window.float({ action = "toggle" }))
      hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exit())

      -- Long brackets [[ ]] keep the shell quoting intact without escapes.
      hl.bind("Print", hl.dsp.exec_cmd([[grim -g "$(slurp)" - | wl-copy]]))

      for i = 1, 5 do
        local key = tostring(i)
        hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
        hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
      end

      hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
      hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

      -- These three have no counterpart in Hyprland's example config, so the
      -- dispatcher names are inferred from the hl.dsp.window.* namespace
      -- rather than verified. pcall contains the damage: if a name is wrong,
      -- that one bind is skipped instead of aborting the whole config and
      -- dropping you back into emergency mode with no binds at all.
      -- To see the real names once you are logged in: hyprctl dispatchers
      local function try_bind(keys, make)
        local ok, dispatcher = pcall(make)
        if ok then hl.bind(keys, dispatcher) end
      end

      try_bind(mainMod .. " + F", function() return hl.dsp.window.fullscreen() end)
      try_bind(mainMod .. " + P", function() return hl.dsp.window.pseudo() end)
      try_bind(mainMod .. " + J", function() return hl.dsp.window.togglesplit() end)

      -- Software cursors. On Optimus/NVIDIA, hardware cursors are a common
      -- cause of an invisible or flickering pointer. Also unverified under the
      -- lua schema, so isolated in its own call — a rejected key here must not
      -- take the working hl.config block above down with it.
      pcall(function()
        hl.config({ cursor = { no_hardware_cursors = true } })
      end)

      -- Autostart. mako is deliberately absent: services.mako.enable starts it
      -- as a systemd user service, and a second instance would just fail.
      -- hyprpaper/hypridle stay out until they have config files of their own.
      hl.on("hyprland.start", function()
        hl.exec_cmd("waybar")
        hl.exec_cmd("${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1")
      end)
    '';
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
  # `font.name` has no default in home-manager's font type, and setting any
  # sub-option instantiates the whole submodule — so `font.size = 11;` on its
  # own fails evaluation with "The option `programs.kitty.font.name' is used
  # but not defined". Name the font explicitly; it is the Nerd Font already
  # installed system-wide in configuration.nix, so the glyphs waybar and the
  # shell prompt expect are actually present.
  programs.kitty = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      package = pkgs.nerd-fonts.jetbrains-mono;
      size = 11;
    };
  };

  home.packages = with pkgs; [
    firefox
  ];

  programs.home-manager.enable = true;
}
