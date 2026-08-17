# package.nix — build the y5 compositor PURELY FROM SOURCE.
#
# Why this derivation is non-obvious
# ───────────────────────────────────
# A fresh clone of the nourish repo ships NO Cargo.toml files at all. Every
# manifest (962 of them) is GENERATED from `vendor.catalog.json` +
# `workspace.catalog.json` + each crate's `crate.json` by
# `compositor.workspace/workspace.generate.js` (Node). The repo's own
# `environment/build.sh` runs that generator before every `cargo`. We do the
# same here, in `postPatch`.
#
# Ordering matters and just works with buildRustPackage:
#   1. postUnpackHooks  → cargoSetupPostUnpackHook: copies the vendored crate
#      universe into the build tree + appends the vendor `.cargo/config.toml`
#      to the repo's OWN `.cargo/config.toml` (which we must keep — it pins
#      rustflags `-A warnings` + `-C target-cpu=x86-64-v3`).
#   2. postPatch (string) → runs first: `node workspace.generate.js` writes the
#      962 Cargo.toml + we drop the pinned Cargo.lock into the workspace root.
#   3. postPatchHooks    → cargoSetupPostPatchHook: validates src Cargo.lock ==
#      vendored lock. Passes because step 2 already placed a byte-identical copy.
#
# We pin a pre-generated `../Cargo.lock` (1494 crates, all crates.io — no git
# sources, so importCargoLock needs no `outputHashes`) so cargoDeps is a
# fixed-output derivation and the build hermetic.

{
  lib,
  rustPlatform,
  stdenv,
  nodejs,
  clang,
  pkg-config,
  protobuf,
  makeWrapper,

  # Runtime / build libraries — mirror environment/install-deps.sh.
  libinput,
  seatd,
  libxkbcommon,
  pixman,
  wayland,
  wayland-protocols,
  libgbm,
  libdisplay-info,
  systemd,
  dbus,
  pam,
  mesa,
  ffmpeg,
  libpulseaudio,
  libdrm,
  libGL,
  libglvnd,
  vulkan-loader,
  vulkan-headers,
  vulkan-tools,

  src,
  version,
  cargoLock ? ../Cargo.lock,

  # ── build knobs (overridable via overrideAttrs / .override) ────────────────
  # `releasefast` mirrors the repo's everyday `release-fast` profile (release
  # opts, NO fat LTO, 16 codegen units) — re-exposed under a HYPHEN-free name.
  # Why rename: nixpkgs's cargo-build-hook does `export
  # "CARGO_PROFILE_${cargoBuildType@U}_STRIP"=false`; a hyphen makes
  # `${cargoBuildType@U}` = `RELEASE-FAST` → an illegal shell identifier and
  # the build dies in buildPhase. cargo itself accepts hyphenated `--profile`
  # names fine, so we alias the profile to a hyphen-free name in postPatch.
  # Fat-LTO `release` serial-links for 10–20 min and is reserved by upstream for
  # release TAGS; pass `buildType = "release"` only when shipping.
  buildType ? "releasefast",
  # Extra cargo features beyond backend-native. `renderer-vulkan` is the whole
  # point of this flake — it cascades through the native-wire entry crate to pull
  # in the kernel.vulkan renderer + ash (=0.38, Vulkan 1.3.281 headers). Add
  # `vulkan-validate` to additionally surface vk_diag / GpuAss diagnostics paths.
  extraBuildFeatures ? [ ],
}:

assert lib.assertMsg
  (lib.elem buildType [ "release" "releasefast" ])
  "package.nix: buildType must be `release` or `releasefast` (hyphen-free alias of the repo's release-fast; debug is gone upstream)";

let
  # The one workspace root that produces the SHIPPED `y5_compositor` bin —
  # matches what build.sh discovers. Setting buildAndTestSubdir here makes
  # cargo build ONLY this bin crate (+ its deps), not the whole workspace.
  binCrateSubdir =
    "compositor.kernel/kernel.loader/loader.main/main.execute/execute.base";

  # Libraries the compositor dlopens at runtime (wayland-rs, xkb, GL/Vulkan
  # loaders). These MUST be on RPATH or you get NoWaylandLib-style failures.
  runtimeLibs = lib.makeLibraryPath [
    wayland
    libxkbcommon
    libGL
    libglvnd
    vulkan-loader
    libinput
    seatd
    mesa
    libdrm
    systemd
    dbus
    pam
    libpulseaudio
    ffmpeg
    pixman
    libgbm
    libdisplay-info
  ];
in
rustPlatform.buildRustPackage {
  pname = "y5-compositor";
  inherit version src;

  # Vendor every crates.io dep as a FOD from the pinned lockfile. The local
  # path deps (smithay/input/pam-sys via [patch.crates-io], and all compositor_*
  # internal crates) resolve from the full source tree at build time — not from
  # the vendor dir.
  cargoLock = {
    lockFile = cargoLock;
    # No `outputHashes` needed: the lock has zero git+ sources (verified).
  };

  # release-fast / release — the cargo-build hook maps buildType!=="debug" to
  # `--profile <buildType>`. The generated workspace Cargo.toml defines BOTH
  # profiles, so this Just Works. The install hook finds the bin at
  # target/<buildType>/y5_compositor.
  buildType = buildType;

  # backend-native = the DRM/KMS backend on real hardware/tty (vs the default
  # backend-winit which only runs nested inside an existing Wayland session).
  # We MUST drop default features to remove backend-winit, then add
  # backend-native + the Vulkan renderer feature.
  buildNoDefaultFeatures = true;
  buildFeatures = [ "backend-native" "renderer-vulkan" ] ++ extraBuildFeatures;

  # Build ONLY the bin crate; its Cargo.toml uses `{ workspace = true }` deps,
  # resolved against the workspace root cargo walks up to (kernel.loader).
  buildAndTestSubdir = binCrateSubdir;

  # The build's lockfile-consistency check (cargoSetupPostPatchHook) looks for the
  # src `Cargo.lock` at `$(pwd)/${cargoRoot:+$cargoRoot/}Cargo.lock`. This repo's
  # workspace root is NESTED (compositor.kernel/kernel.loader), not the repo
  # root — so without `cargoRoot` the check looks at repo-root and fails with
  # "Missing Cargo.lock from src" the moment it tries to validate. Pointing it
  # at the workspace root is where postPatch writes the lock, so they match.
  cargoRoot = "compositor.kernel/kernel.loader";

  nativeBuildInputs = [
    nodejs # the manifest generator (postPatch)
    # Mirror install-deps.sh build-tool side: clang (linker + bindgen libclang),
    # pkg-config (systemd/dbus/ffmpeg .pc probes), protoc (prost-build codegen).
    clang
    pkg-config
    protobuf
    rustPlatform.bindgenHook
    makeWrapper
  ];

  # Devel libs the tree links against (mirrors environment/install-deps.sh).
  buildInputs = [
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
    # Graphics stack — Vulkan-first
    mesa
    vulkan-loader
    vulkan-headers
    libdrm
    libGL
    libglvnd
    ffmpeg
    libpulseaudio
  ];

  # ── Generate the missing Cargo manifests + drop the pinned lockfile ─────────
  # This string runs BEFORE postPatchHooks → cargoSetupPostPatchHook, which
  # validates src Cargo.lock == vendored lock. By the time it runs the lockfile
  # is in place, so validation passes.
  postPatch = ''
    echo ":: generating Cargo manifests (workspace.generate.js)"
    node compositor.workspace/workspace.generate.js

    echo ":: placing pinned Cargo.lock at compositor.kernel/kernel.loader/Cargo.lock"
    mkdir -p compositor.kernel/kernel.loader
    cp "${cargoLock}" compositor.kernel/kernel.loader/Cargo.lock
    chmod 644 compositor.kernel/kernel.loader/Cargo.lock

    # Re-expose the repo's `release-fast` profile under the hyphen-free name
    # `releasefast` so nixpkgs's cargo-build-hook can build the
    # `CARGO_PROFILE_<TYPE>_STRIP` env-var (hyphens are illegal there). Cargo
    # resolves the `inherits` chain at build time, so this alias is identical
    # to invoking `--profile release-fast` by hand. (See buildType option doc.)
    echo ":: adding [profile.releasefast] alias of [profile.release-fast]"
    cat >> compositor.kernel/kernel.loader/Cargo.toml <<'EOF_NISH'

[profile.releasefast]
inherits = "release"
lto = false
codegen-units = 16
EOF_NISH
  '';

  # ── Install: rename to the shipped name + ship a Wayland session ────────────
  # The cargo-install hook copies target/<buildType>/y5_compositor to $out/bin.
  # Upstream installs it as `y5.compositor` (dot-name); make both names resolve.
  postInstall = ''
    ln -sf y5_compositor $out/bin/y5.compositor

    # Default Vulkan settings so a fresh login Just Works (the compositor panics
    # if ~/.config/y5.compositor/settings.json is missing/short a field). The
    # session wrapper seeds the user copy from this on first run.
    install -Dm644 ${../default-settings.json} \
      $out/share/y5-compositor/default-settings.json

    # The login-session wrapper. Paths are @substituted@ afterward so this store
    # path stays fully relocatable.
    install -Dm755 ${./y5-session} $out/lib/y5-compositor/y5-session
    substituteInPlace $out/lib/y5-compositor/y5-session \
      --replace-fail "@compositor@" "$out/bin/y5.compositor" \
      --replace-fail "@defaultSettings@" \
                    "$out/share/y5-compositor/default-settings.json"

    # wayland-sessions entry: what display managers (GDM/SDDM) read to offer the
    # session under the "Y5" name. Exec points at the wrapper, not the raw bin.
    install -Dm644 ${./y5-session.desktop} \
      $out/share/wayland-sessions/y5.desktop
    substituteInPlace $out/share/wayland-sessions/y5.desktop \
      --replace-fail "@sessionBin@" "$out/lib/y5-compositor/y5-session"

    # Wrap the raw compositor so direct CLI invocation also finds its dlopen'd
    # runtime libs. (Vulkan loader sets VK_ICD_FILENAMES as needed; we add the
    # `vulkan-tools` bin to PATH so `vulkaninfo` is one keystroke away for
    # debugging "is my Vulkan stack actually working?")
    wrapProgram $out/bin/y5.compositor \
      --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
      --prefix PATH : "${lib.makeBinPath [ vulkan-tools ]}"
  '';

  # The native backend needs a real DRM device to even start, so don't run
  # cargo tests in the build env. A passthru.tests could build the winit
  # backend + `cargo test` — left as future work.
  doCheck = false;

  # The nixpkgs display-manager infra (services.displayManager.sessionPackages
  # → sessionData.desktops/​sessionNames) REQUIRES each session package to
  # declare which .desktop session names it provides. We ship one
  # wayland-sessions file (y5.desktop) → `providedSessions = [ "y5" ]`. Without
  # this the `sessionData.desktops` runCommand would find no listed session to
  # validate, the `defaultSession = "y5"` assertion would fail at build time,
  # and ly / SDDM / GDM would never list the Y5 entry. (Mirrors what the niri
  # package does: `passthru.providedSessions = [ "niri" ];`.)
  passthru.providedSessions = [ "y5" ];

  meta = {
    description = "y5 — a Wayland compositor with an infinite, zoomable canvas (the Nourish desktop)";
    homepage = "https://nourish.snowies.com";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "y5.compositor";
    # ash + the Vulkan renderer link Linux DRM/Vulkan ICDs.
    platforms = lib.platforms.linux;
    badPlatforms = lib.platforms.darwin;
    hydra.skip = true; # ~1400 crates — heavy.
  };
}
