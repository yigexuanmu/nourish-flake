# flake.nix — Nourish (y5) from source, with a `programs.nourish` NixOS module.
#
# What you get
#   legacyPackages.<system>.y5-compositor  ← the compositor, built PURELY from
#                   source (no prebuilt bundle, no nix-ld). Vulkan-first.
#   nixosModules.nourish                  ← `programs.nourish.enable = true`:
#                   the session, portal, PAM, polkit, GPU/Vulkan runtime
#                   plumbing — modelled on `programs.niri` in nixpkgs.
#   devShells.<system>.default            ← a dev shell mirroring upstream's
#                   install-deps.sh for hacking on the compositor locally.
#
# Building the compositor from source is heavy (~1400 crates). See README.md
# for how to iterate the FOD hashes if the lockfile drifts, and how to flip to
# fat-LTO `release` for shipping.

{
  description = "Nourish (y5) — a Vulkan-first Wayland compositor, built from source, with a NixOS module";

  inputs = {
    # Unstable tracks current Rust: the vendored bevy needs rustc >= 1.95, which
    # nixos-25.11's frozen 1.91 is too old for. (Matches environment/nix/flake.nix.)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Pinned commit of the verified build chain. The hash was computed with:
      #   nix-prefetch-url --unpack --type sha256 \
      #     https://github.com/y5-snowies/nourish/archive/<rev>.tar.gz
      #   nix hash to-sri --type sha256 <that>
      # To update: bump rev, re-run those two, commit a refreshed ./Cargo.lock.
      srcMeta = {
        owner = "y5-snowies";
        repo = "nourish";
        rev = "1280e12c8c86f890ba6369387ed11f19b91a796d";
        hash = "sha256-FldDOOO+JLyFjW6zaJa7FTJWA+33qiox9HlNbATLhTQ=";
      };
      version = "1.8.0"; # repo-root VERSION at that rev

      # Shared across the package attr and the NixOS module so they stay in sync.
      inherit (nixpkgs) lib;

      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      pkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
        }
      );
    in
    {
      # ── package: the y5 compositor, built from source ─────────────────────
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = self.packages.${system}.y5-compositor;
          y5-compositor = pkgs.callPackage ./nixos/package.nix {
            src = pkgs.fetchFromGitHub srcMeta;
            inherit version;
            cargoLock = ./Cargo.lock;
          };
        }
      );

      # convenience: legacyPackages so `pkgs.y5-compositor` works via overlays.
      legacyPackages = forAllSystems (system: self.packages.${system});

      # ── dev shell (mirrors install-deps.sh) ───────────────────────────────
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.callPackage ./nixos/devshell.nix { };
        }
      );

      formatter = forAllSystems (system: pkgsFor.${system}.nixfmt-rfc-style);

      # ── NixOS module (system-agnostic) ─────────────────────────────────────
      # A module is a function; import the file UN-APPLIED and let the NixOS
      # module system call it with {config, lib, pkgs, ...}. The module is
      # SELF-CONTAINED — it fetches the pinned source + builds the package in
      # its own `package` option default, so:
      #     programs.nourish.enable = true
      # Just Works with no overlay and no extra pinning.
      #
      # In your system config:
      #   inputs.nourish.url = "github:yigexuanmu/nourish";  # or your fork
      #   imports = [ inputs.nourish.nixosModules.nourish ];
      #   programs.nourish.enable = true;
      nixosModules.nourish = import ./nixos/module.nix;
      nixosModules.default = self.nixosModules.nourish;

      # An overlay as the alternative integration path (optional).
      overlays.default = final: _prev: {
        y5-compositor = final.callPackage ./nixos/package.nix {
          src = final.fetchFromGitHub srcMeta;
          inherit version;
          cargoLock = ./Cargo.lock;
        };
      };
    };
}
