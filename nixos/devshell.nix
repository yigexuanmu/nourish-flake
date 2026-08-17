# devshell.nix — a dev shell mirroring environment/install-deps.sh for local hacking.
#
# `nix develop` drops you in a shell with the Rust toolchain + every system
# library the tree links against, so you can `./environment/build.sh udev` or
# `./environment/run-host.sh winit` without installing distro packages.

{ pkgs }:
let
  # Libraries the tree dlopen()s at runtime that a hermetic mkShell does NOT put
  # on the loader path — must go on LD_LIBRARY_PATH or you get NoWaylandLib etc.
  runtimeLibs = with pkgs; [
    wayland
    libxkbcommon
    libGL
    libglvnd
    vulkan-loader
    libinput
    seatd
  ];
in
pkgs.mkShell {
  packages = with pkgs; [
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer
    nodejs # the manifest generator (workspace.generate.js)
  ];

  RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

  nativeBuildInputs = with pkgs; [
    pkg-config
    clang
    rustPlatform.bindgenHook
    protobuf # protoc (prost-build)
  ];

  buildInputs = with pkgs; [
    # Wayland / smithay core
    libinput
    seatd
    libxkbcommon
    pixman
    wayland
    wayland-protocols
    libgbm
    libdisplay-info
    systemd
    dbus
    pam
    # Graphics — Vulkan-first
    mesa
    vulkan-loader
    vulkan-headers
    vulkan-tools
    vulkan-validation-layers
    libdrm
    libGL
    libglvnd
    ffmpeg
    libpulseaudio
  ];

  shellHook = ''
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "nourish dev shell — build deps ready."
    echo "  generate manifests:  node compositor.workspace/workspace.generate.js"
    echo "  build (native, vkb): ./environment/build.sh udev"
    echo "  run nested (winit):  ./environment/run-host.sh winit debug"
  '';
}
