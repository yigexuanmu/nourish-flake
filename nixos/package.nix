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

  # xwayland-satellite (nourish's forked variant — see prepare.sh step 5):
  # both for the satellite binary and for the satellite `.service` at install
  # (it hardcodes `/usr/bin/xwayland-satellite` and `/bin/sh`; we substitute
  # both to Nix store paths).
  libxcb,
  xcb-util-cursor,
  bash,

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

  # ─── y5.compositor.settings (the settings-editor, schema-v4 aware) ──────
  # The compositor's panic on a missing/partial settings file explicitly tells
  # the user to "Create it with `y5.compositor.settings`" — so ship the tool so
  # that advice is actually actionable on NixOS. It's the SAME `config.base`
  # schema crate the compositor parses (path-dep), so the file it writes can
  # never drift from what the compositor validates. Standalone cargo workspace
  # (own Cargo.toml + Cargo.lock, zero git sources) — built with the whole repo
  # as src because its path-deps climb back up the tree.
  settingsEditor = rustPlatform.buildRustPackage {
    pname = "y5-settings-editor";
    inherit version;
    src = src;
    cargoRoot = "compositor.installer/component/settings-editor";
    # Set so cargo-build-hook pushes into the settings-editor's own subdir to
    # build (cargoRoot alone only points the lockfile/unpack at it).
    buildAndTestSubdir = "compositor.installer/component/settings-editor";
    # The tarball's own committed Cargo.lock at f28b3d2c drifted from the
    # generator's pinned catalog (serde 1.0.228 in-tree vs. the =1.0.229 that
    # workspace.generate.js bakes into config.base's manifest), so imports fail
    # with "failed to select a version for serde =1.0.229". Pin OUR copy here
    # (generated against the same catalog), same deal as the root Cargo.lock.
    cargoLock = {
      lockFile = ./../settings-editor.Cargo.lock;
      # No git sources in this lockfile (verified: zero `git+`) → outputHashes
      # stays empty, same as the other lockfiles this flake consumes.
    };
    buildType = "release";

    nativeBuildInputs = [
      nodejs # generate the config.base / gpu.base / preference.base manifests
    ];
    buildInputs = [
      libdrm # drm probe (pre-generated bindings; no bindgen needed)
    ];

    # The src tree ships NO Cargo.toml for the linked crates — every one is
    # generated by the same workspace generator. Run it so the path-deps the
    # settings editor climbs up to (config.base etc.) have manifests.
    postPatch = ''
      node compositor.workspace/workspace.generate.js

      # Overwrite the tarball's drifted Cargo.lock with our catalog-consistent
      # copy BEFORE cargoSetupPostPatchHook compares src-lock ≟ vendored-lock,
      # else the consistency check fails at the stale serde pin.
      cp "${./../settings-editor.Cargo.lock}" \
        compositor.installer/component/settings-editor/Cargo.lock
      chmod 644 compositor.installer/component/settings-editor/Cargo.lock
    '';

    doCheck = false;

    meta = {
      description =
        "y5.compositor.settings — interactive author of ~/.config/y5.compositor/settings.json";
      homepage = "https://github.com/y5-snowies/nourish";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      badPlatforms = lib.platforms.darwin;
      hydra.skip = true;
    };
  };

  # ─── xwayland-satellite (nourish's forked v0.8.1 + HiDPI/popup-fix patch) ──
  # The satellite runs as a systemd user unit (After/WantedBy=
  # graphical-session.target) and spawns the system Xwayland in rootless mode,
  # so X11 apps get transparently embedded in the y5 Wayland session. Upstream
  # ships it as a SEPARATE cargo workspace at
  # `compositor.installer/component/xwayland-satellite/xwayland-fixes/` with
  # its OWN `Cargo.lock` (≈140 crates, no git sources) and builds it as a
  # distinct `cargo build` (see `prepare.sh` step 5). We mirror that here with
  # a separate `buildRustPackage` derivation, then bundle its outputs into the
  # main compositor package's postInstall so `programs.nourish.enable = true`
  # brings up the whole X11 stack from one package.
  xwaylandSatellite = rustPlatform.buildRustPackage {
    pname = "y5-xwayland-satellite";
    inherit version;
    # Just take the satellite's sub-tree of the SAME upstream src — it is its
    # own self-contained cargo workspace and cares nothing about the compositor
    # manifests generated up above.
    src = "${src}/compositor.installer/component/xwayland-satellite/xwayland-fixes";
    cargoLock = {
      lockFile = "${src}/compositor.installer/component/xwayland-satellite/xwayland-fixes/Cargo.lock";
      # No git deps in this lockfile either (verified: zero `git+` source
      # entries) → `outputHashes` empty is correct.
    };
    buildType = "release";
    nativeBuildInputs = [
      pkg-config
      rustPlatform.bindgenHook
    ];
    buildInputs = [
      libxcb
      xcb-util-cursor
      wayland
      wayland-protocols
      systemd # sd-notify symbols (libsystemd) when the `systemd` cargo feature
              # is on; harmless when off.
    ];

    # The satellite's `build.rs` calls `vergen-gitcl` to embed `git describe`
    # into the binary. A `fetchFromGitHub` tarball has no `.git` and the
    # emitter errors out. Replace it with a no-op that emits the sentinel
    # `VERGEN_IDEMPOTENT_OUTPUT`: `src/lib.rs::version()` handles exactly this
    # case (line 102) by falling back to `CARGO_PKG_VERSION` (= "0.8.1"). This
    # matches the upstream tarball-without-git invocation path.
    postPatch = ''
      echo 'fn main() { println!("cargo:rustc-env=VERGEN_GIT_DESCRIBE=VERGEN_IDEMPOTENT_OUTPUT"); }' > build.rs
    '';

    postInstall = ''
      # Install the systemd user unit author wrote (`xwayland.service` at the
      # workspace root — the `resources/xwayland-satellite.service` file is the
      # upstream unpatched satellite variant; we want the y5-patched one).
      install -Dm644 xwayland.service \
        $out/lib/systemd/user/xwayland-satellite.service

      # Fix the two hardcoded FHS paths the unit assumes:
      #   /usr/bin/xwayland-satellite     → this derivation's binary
      #   /bin/sh                         → Nix store bash (NixOS has no /bin/sh)
      substituteInPlace $out/lib/systemd/user/xwayland-satellite.service \
        --replace-fail "/usr/bin/xwayland-satellite" "$out/bin/xwayland-satellite" \
        --replace-fail "/bin/sh" "${bash}/bin/sh"

      # Satellite spawns `Xwayland` by relative name (Command::new("Xwayland"))
      # and goes through $PATH. NixOS user units don't inherit a session PATH,
      # so the 'Xwayland' binary added by `programs.xwayland.enable` may not be
      # seen. Inject an explicit `Environment=PATH=` listing the standard
      # NixOS run-time binary dirs (Xwayland lives in /run/current-system/sw/bin
      # once `programs.xwayland.enable` is on).
      sed -i "/^\[Service\]/a Environment=PATH=/run/wrappers/bin:/run/current-system/sw/bin:$out/bin" \
        $out/lib/systemd/user/xwayland-satellite.service
    '';

    # testwl dep needs a running wayland compositor — skip.
    doCheck = false;

    meta = {
      description = "nourish's forked xwayland-satellite (y5 X11 compatibility bridge)";
      homepage = "https://github.com/Supreeeme/xwayland-satellite";
      license = lib.licenses.gpl2Only;
      platforms = lib.platforms.linux;
      badPlatforms = lib.platforms.darwin;
      hydra.skip = true;
    };
  };
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
  # Upstream installs it as `y5.compositor` (dot-name); we additionally ship an
  # auto-seeding launcher under that name (see #y5-compositor below).
  postInstall = ''
    # Default Vulkan settings so a fresh login Just Works (the compositor panics
    # if ~/.config/y5.compositor/settings.json is missing/short a field — schema
    # v4 canonical values, matching upstream `config.base::default_settings()`).
    # Both the session wrapper and the dot-name launcher seed the user copy from
    # this on first run.
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

    # ── The compositor binary itself. ──────────────────────────────────────
    # First, wrap the RAW cargo-install binary so direct CLI invocation finds
    # its dlopen'd runtime libs. (Vulkan loader sets VK_ICD_FILENAMES as needed;
    # we add the `vulkan-tools` bin to PATH so `vulkaninfo` is one keystroke
    # away for debugging "is my Vulkan stack actually working?").
    wrapProgram $out/bin/y5_compositor \
      --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
      --prefix PATH : "${lib.makeBinPath [ vulkan-tools ]}"

    # Then install the DOT-NAME launcher — `y5.compositor` in this package and
    # on users' PATH resolves here. This is the startup-bug fix: a DIRECT launch
    # (`nix run .#y5-compositor`, `./result/bin/y5.compositor`) used to exec the
    # raw binary, which has NO defaults and panics on a missing settings.json —
    # the exact panic from the README. The launcher seeds the file (idempotent)
    # and then execs the wrapped binary above. y5-session still seeds too; both
    # paths are covered.
    install -Dm755 ${./y5-compositor} $out/bin/y5.compositor
    substituteInPlace $out/bin/y5.compositor \
      --replace-fail "@compositor@" "$out/bin/y5_compositor" \
      --replace-fail "@defaultSettings@" \
                    "$out/share/y5-compositor/default-settings.json"

    # The settings-editor companion tool — what the panic message tells you to
    # run ("Create it with `y5.compositor.settings`"). Interactive author of
    # settings.json + preferences.json; `--write-default` non-interactively
    # writes the canonical template. Ships both the upstream dot-name and the
    # cargo `[[bin]]` name (dashes) so either invocation resolves.
    install -Dm755 ${settingsEditor}/bin/y5-compositor-settings \
      $out/bin/y5.compositor.settings
    ln -sf y5.compositor.settings $out/bin/y5-compositor-settings

    # ── Bring along the satellite binary + its systemd user unit (mirrors ─────
    # upstream `prepare.sh` step 5): every y5 session needs xwayland-satellite
    # in PATH for X11 apps to work, and the user unit under graphical-session.
    # Installing it under THIS package means `systemd.packages = [cfg.package]`
    # in the NixOS module picks up BOTH the satellite unit and y5-service/
    # shutdown target in one place.
    install -Dm755 ${xwaylandSatellite}/bin/xwayland-satellite \
      $out/bin/xwayland-satellite
    install -Dm644 \
      ${xwaylandSatellite}/lib/systemd/user/xwayland-satellite.service \
      $out/lib/systemd/user/xwayland-satellite.service

    # ── The main compositor systemd user unit (y5.service) + shutdown target ──
    # Upstream ships no such unit — they assume the distro's DM directly exec's
    # the compositor. That model doesn't get systemd user units to start (no
    # graphical-session.target gets pulled in, so the satellite never rises).
    # We fill the gap the same way the `niri` flake ships its own `niri.service`:
    # `BindsTo=graphical-session.target` so the satellite (After=…ạt.arget)
    # chains up correctly. We put the compositor under this unit so the session
    # wrapper can `systemctl --user --wait start y5.service`.
    install -Dm644 ${./y5.service} $out/lib/systemd/user/y5.service
    substituteInPlace $out/lib/systemd/user/y5.service \
      --replace-fail "@compositor@" "$out/bin/y5.compositor"

    install -Dm644 ${./y5-shutdown.target} \
      $out/lib/systemd/user/y5-shutdown.target
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
