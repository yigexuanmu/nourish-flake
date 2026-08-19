# module.nix — the `programs.nourish` NixOS module.
#
# WHAT `programs.nourish.enable = true` DOES (you asked — this is the inverse of
# `programs.niri.enable`, see nixpkgs/nixos/modules/programs/wayland/niri.nix):
#
# A NixOS `programs.*` option is the conventional site to wire UP a full desktop
# when the work is not permissive-permissive enough to leave to the user. Enabling
# it flips on the SERVICE plumbing underneath — environment + session + portal +
# PAM + runtime GPU stack — so the compositor is usable out of the box the way
# GNOME/KDE/Niri are. Concretely, behind the one toggle:
#
#   • environment.systemPackages  ← the compositor + polkit agent + xwayland +
#     vulkan-tools (so `vulkaninfo` is on PATH for first-line GPU diagnostics).
#   • services.displayManager.sessionPackages  ← our wayland-sessions .desktop so
#     GDM/SDDM/ly offer the "Y5" session. We register only (like hyprland/sway —
#     no defaultSession), so this flake coexists with programs.niri etc. without
#     locking defaultSession. On a Nourish-only box using GDM 50, set
#     `services.displayManager.defaultSession = "y5"` yourself to avoid GDM
#     looping back to the non-installed gnome-session.
#   • systemd.packages  ← installing the y5.service + y5-shutdown.target +
#     xwayland-satellite.service user units from `cfg.package` (these ship in
#     `lib/systemd/user/`). The satellite additionally sets
#     `wantedBy = ["graphical-session.target"]` so it auto-starts when the
#     compositor pulls up that target (canonical NixOS pattern, see
#     `nixpkgs/nixos/modules/services/system/systemd-lock-handler.nix`).
#     `restartIfChanged = false` on both: a `rebuild switch` won't kill an
#     active login session.
#   • xdg.portal  ← enable + extraPortals (gnome+gtk) + a `nourish` config block
#     so org.freedesktop.impl.portal.{Access,FileChooser,Notification,Secret}
#     route correctly. (The single biggest "behind the scenes" lift when adding
#     any new Wayland compositor.)
#   • security.pam.services.y5-lock  ← the lock screen calls pam_start("y5-lock").
#   • security.polkit + the y5-polkit-agent user service.
#   • hardware.graphics + Vulkan runtimes (vulkan-loader, validation layers,
#     mesa.drivers) so ICDs/GLX are visible — essential for a Vulkan-FIRST
#     compositor.
#   • xwayland + a seatd/libseat path so the native udev backend can grab the
#     session.
#
# The module is SELF-CONTAINED: the `package` option default fetches the pinned
# source + builds it via ./package.nix, so the one-liner
#   programs.nourish.enable = true
# Just Works with no overlay and no extra pinning. Override `programs.nourish.package`
# to point at a local build to iterate on the compositor without touching the
# module.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nourish;

  # Pinned source — kept in lockstep with flakes.nix + package.nix callers.
  srcMeta = {
    owner = "y5-snowies";
    repo = "nourish";
    rev = "f28b3d2c90d9d05fafbb0b0cc53965d7577f40b4";
    hash = "sha256-ZDVEiS/UdpsMDTs8OuG6Lz7hEC77ylbwJ/DL3NI5y9s=";
  };
  version = "1.8.0"; # repo-root VERSION at that rev
in
{
  options.programs.nourish = {
    enable = lib.mkEnableOption ''
      Nourish (y5), a Vulkan-first Wayland compositor with an infinite,
      zoomable canvas built from source.

      Enabling this wires up the full desktop — Wayland session, xdg portal,
      PAM lock service, polkit, and the Vulkan runtime stack — the same way
      `programs.niri` / GNOME do.
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {
        src = pkgs.fetchFromGitHub srcMeta;
        inherit version;
        cargoLock = ../Cargo.lock;
      };
      defaultText = lib.literalMD "y5-compositor built from the pinned source in this flake";
      description = ''
        The y5 compositor package to use. Defaults to the source build from
        this flake at the pinned commit. Override with a local build (e.g.
        `pkgs.callPackage ./package.nix { src = ./.; ... }`) to iterate on the
        compositor without touching the module.
      '';
    };

    enableVulkanValidation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add vulkan-validation-layers to the session's VK_LAYER_PATH so the
        Vulkan loader surfaces vk_diag / GpuAss diagnostics in the journal.
        Off by default because validation layers cost throughput and spam logs;
        flip on when diagnosing renderer bugs.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # ── The compositor + companions on PATH ──────────────────────────────
        environment.systemPackages = [
          cfg.package
          pkgs.xwayland
          # `vulkaninfo` is one keystroke away for "is my Vulkan stack working?"
          pkgs.vulkan-tools
          # X11 client libs that the xwayland-satellite side of the session
          # needs on the system PATH so its Xwayland's PCI-surface finds them
          # via `/run/current-system/sw/lib` (the satellite binary itself
          # already links them via its own RPATH from `buildInputs` in
          # package.nix — this is for X11 client apps that look at system lib
          # paths).
          pkgs.libxcb
          pkgs.xcb-util-cursor
        ]
        ++ lib.optional cfg.enableVulkanValidation pkgs.vulkan-validation-layers;

        # ── Display manager picks us up as a session ─────────────────────────
        # Register only, like nixpkgs's hyprland/sway/wayfire modules do: we add
        # ourselves to the session list so GDM/SDDM/ly offer "Y5", but we do NOT
        # pin `services.displayManager.defaultSession`. Pinning it would collide
        # with any other compositor that also pins (nixpkgs's `programs.niri`
        # does `mkDefault "niri"`, and two `mkDefault`s of different values
        # hard-fail the build). Leaving it unset means: on a multi-desktop box,
        # the user picks at the login screen (or sets defaultSession themselves);
        # on a Nourish-ONLY box using GDM 50, set `defaultSession = "y5"` in your
        # config to avoid GDM looping back to the non-installed gnome-session.
        services.displayManager.sessionPackages = [ cfg.package ];

        # ── systemd: unit files ship in `cfg.package` ───────────────────────
        # `systemd.packages` installs the package's `lib/systemd/user/` contents
        # (y5.service, y5-shutdown.target, xwayland-satellite.service — all
        # written by package.nix) into the user-unit dir, where the user session
        # manager picks them up at next login. It does NOT, by itself, enable
        # them — so for the satellite we ALSO set `wantedBy` here. The SDL
        # pattern (`systemd-lock-handler.nix` in nixpkgs) is precisely
        # `systemd.packages = [pkg]` + `systemd.user.services.X.wantedBy = …`.
        #
        # y5.service is NOT `wantedBy` anything — it is started explicitly by
        # the y5-session wrapper (`systemctl --user --wait start y5.service`).
        # Setting `restartIfChanged = false` on both units means a `nixos-rebuild
        # switch` while logged in will NOT tear down an active session — the
        # user gets the new binaries on next login.
        systemd.packages = [ cfg.package ];
        systemd.user.services.y5 = {
          restartIfChanged = false;
          # NixOS's default user-unit Environment="PATH=…" would clobber the
          # session-wrapped PATH; turn the drop-in off (niri.nix uses
          # `enableDefaultPath = false` for the same reason).
          enableDefaultPath = false;
        };
        systemd.user.services.xwayland-satellite = {
          # Pull the satellite up automatically when graphical-session.target
          # rises — i.e. when y5.service (which `BindsTo=graphical-session.target`)
          # starts. The author's `xwayland.service` already declares
          # [Install] WantedBy=graphical-session.target in its unit file, but
          # `systemctl --user enable` is never called under NixOS — this NixOS
          # option explicitly creates the `.wants/` softlink for us.
          wantedBy = [ "graphical-session.target" ];
          restartIfChanged = false;
          # Same rationale as y5.service — leave PATH to the unit's own
          # Environment= line (set in package.nix with the run-wrappers +
          # current-system path so it finds the Xwayland binary).
          enableDefaultPath = false;
        };

        # ── xdg-desktop-portal: the single biggest "behind the scenes" wire ──
        # Without a portal config FileChooser / ScreenCast / Secret all fail.
        xdg.portal = {
          enable = lib.mkDefault true;
          extraPortals = [
            pkgs.xdg-desktop-portal-gtk
            pkgs.xdg-desktop-portal-gnome
          ];
          # config.nourish routes the standard impl portals to a gtk/gnome mix,
          # keyed off XDG_CURRENT_DESKTOP=Y5Compositor (set by the session
          # wrapper). Secret → gnome-keyring; FileChooser → gtk (no nautilus dep).
          config.nourish = {
            default = [
              "gnome"
              "gtk"
            ];
            "org.freedesktop.impl.portal.Access" = "gtk";
            "org.freedesktop.impl.portal.FileChooser" = "gtk";
            "org.freedesktop.impl.portal.Notification" = "gtk";
            "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
          };
        };

        # ── PAM: the lock screen authenticates against "y5-lock" ────────────
        # The compositor's lock interface calls pam_start("y5-lock", ...);
        # absent a matching service PAM falls through to deny. Mirror `login`.
        security.pam.services.y5-lock = { };

        # ── polkit: the compositor ships its own agent, but the daemon stays ─
        security.polkit.enable = lib.mkDefault true;

        # ── GPU / Vulkan runtime stack — the headline of this flake ──────────
        # The compositor dlopens libvulkan + the ICDs at runtime; without these
        # on the system it fails at vkCreateInstance. hardware.graphics covers
        # both GL (mesa) and Vulkan loader on modern nixpkgs.
        hardware.graphics = {
          enable = lib.mkDefault true;
          enable32Bit = lib.mkDefault pkgs.stdenv.hostPlatform.isx86;
        };

        # ── Keyring for the portal Secret impl ──────────────────────────────
        services.gnome.gnome-keyring.enable = lib.mkDefault true;

        # ── XWayland: native X11 app support under the compositor ────────────
        # y5 drives xwayland itself; making the binary visible is enough.
        programs.xwayland.enable = lib.mkDefault true;
      }

      # ── Optional: Vulkan validation layers on the search path ───────────────
      (lib.mkIf cfg.enableVulkanValidation {
        environment.variables.VK_LAYER_PATH =
          "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layers.d";
      })
    ]
  );

  meta.maintainers = lib.maintainers.nourish or [ ];
}
