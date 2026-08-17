# nourish-flake

把 **Nourish(`y5` 合成器)** 在 NixOS 下**纯源码编译**出来,并配一个 `programs.nourish`
模块把整张桌面接好 —— 和 nixpkgs 里 `programs.niri` 是同一种做法。

本 flake **不**用上游的预编译二进制 bundle,也**不**用 `nix-ld`。它拉源码、生成缺失的
Cargo 清单、对着你本机的 nixpkgs 系统库编译合成器 —— **Vulkan 优先**。

---

## 安装教程(中文)

### 方式一:Flake(推荐)

把本 flake 加为 input,在系统配置里导入模块、打开开关即可。下面以 flake 化的
NixOS 配置(`flake.nix` + `configuration.nix`)为例。

**1. 在你的 `flake.nix` 里加 input 并导入模块**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nourish-flake.url = "github:yigexuanmu/nourish-flake";   # 本 flake
  };

  outputs = { self, nixpkgs, nourish-flake, ... }@inputs: {
    nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hardware-configuration.nix
        ./configuration.nix
        nourish-flake.nixosModules.nourish     # 注入 programs.nourish.*
      ];
    };
  };
}
```

**2. 在 `configuration.nix` 里启用 nourish + 选一个登录管理器**

```nix
{ ... }:
{
  # —— 打开 nourish 桌面 ——
  programs.nourish.enable = true;

  # —— 登录管理器:三选一(ly / GDM / SDDM 任一即可) ——

  # (a) ly —— 轻量 TTY 登录管理器(详见下方「与 ly 配合」一节)
  services.displayManager.ly.enable = true;

  # (b) 或者 GDM(GNOME 自带的)
  # services.xserver.displayManager.gdm.enable = true;

  # (c) 或者 SDDM
  # services.displayManager.sddm.enable = true;

  # 用户
  users.users.<你的用户名> = { isNormalUser = true; initialPassword = "changeme"; };
  # 某发行版装系统还要这一行让 rebuild 能找到 nixpkgs:
  # system.stateVersion = "25.11";
}
```

**3. 构建并切换**

```sh
sudo nixos-rebuild switch --flake .#mybox
```

第一次构建会编译 ~1400 个 crate,大约 10~30 分钟(取决于机器),之后会被 Nix 缓存。

**4. 重启,在登录界面选 "Y5 (Nourish)" 会话,登录。**

首次登录会自动播种 `~/.config/y5.compositor/settings.json`(Vulkan 默认值)。想改设置,
编辑该文件即可。

---

### 与 ly 配合(把 ly 设为登录管理器)

`ly` 是基于 TTY 的轻量登录管理器。它**会自动发现** `/usr/share/wayland-sessions/*.desktop`
里的会话,NixOS 把这些会话统一聚合在 `services.displayManager.sessionData.desktops` 下。
本 flake 的包带了一个 `y5.desktop` 并声明了 `passthru.providedSessions = [ "y5" ]`,
所以只要:

```nix
services.displayManager.ly.enable = true;
programs.nourish.enable = true;
```

ly 的会话列表里就会出现 **"Y5 (Nourish)"**。背后的启动链是:

```
ly (用户在 TTY 输用户名/密码后,选中 "Y5")
  → setup_cmd  = services.displayManager.sessionData.wrapper   (nixpkgs 的 xsession-wrapper:
                  source /etc/profile、~/.profile、~/.xprofile,import-environment,
                  起 fake-graphical-session.target,然后 eval exec "$1")
  → $1 = 我们 y5.desktop 的 Exec= = $out/lib/y5-compositor/y5-session
  → y5-session 包装器:播种 settings.json、清掉继承来的 WAYLAND_DISPLAY/DISPLAY、
       导出 XDG_CURRENT_DESKTOP=Y5Compositor / XDG_SESSION_TYPE=wayland
  → exec y5.compositor (native DRM/KMS + Vulkan 渲染器)
```

如果想固定默认进 y5 会话(ly 默认会记住上次选择),可以在 ly 配置里设
`services.displayManager.ly.settings.load = false` 关掉"记住上次",或干脆开 autologin:

```nix
services.displayManager.autoLogin.enable = true;
services.displayManager.autoLogin.user = "<你的用户名>";
services.displayManager.defaultSession = "y5";   # Nourish-only + GDM 时建议明说默认(避 GDM 50 环)
```

> **注意**:ly 在 SELinux 发行版(Fedora、openSUSE)上偶有会话启动问题,见
> [ly README](https://github.com/fairyglade/ly#selinux)。NixOS 默认不开 SELinux,
> 所以这条一般不影响。

---

### 方式二:没有用 flake 的 NixOS(channel / `configuration.nix`)

如果你还在用传统 `configuration.nix` + channel,可以用 `fetchFromGitHub` 拉本 flake:

```nix
{ pkgs, ... }:
let
  nourish-flake = builtins.getFlake "github:yigexuanmu/nourish-flake";
in
{
  imports = [ nourish-flake.nixosModules.nourish ];
  programs.nourish.enable = true;
  services.displayManager.ly.enable = true;
}
```

(`builtins.getFlake` 需要 Nix 2.13+ 且 `nix.settings.experimental-features` 含 `nix-command flakes`。)

---

### 方式三:只想拿到二进制,不启用整张桌面

```sh
nix build github:yigexuanmu/nourish-flake#y5-compositor
./result/bin/y5.compositor   # native 后端需要真实 TTY + DRM 设备
```

---

### 开发 shell(镜像上游 `environment/install-deps.sh`)

```sh
git clone https://github.com/y5-snowies/nourish && cd nourish
nix develop github:yigexuanmu/nourish-flake
./environment/build.sh udev          # release-fast,native 后端
./environment/run-host.sh winit      # 已有会话里嵌套跑(调试用)
```

---

## 验证 Vulkan 跑通了

登录 y5 会话后,在终端里:

```sh
vulkaninfo | head -40          # 模块已把 vulkan-tools 加进 PATH
# 应能看到你的 GPU + "apiVersion = 1.3.xxx"
```

若想开 Vulkan 校验层(排错用),临时开:

```nix
{ programs.nourish.enableVulkanValidation = true; }
```

这会给合成器加 `vulkan-validation-layers`,并设好 `VK_LAYER_PATH`。正式使用时请关掉。

---

## `programs.nourish.enable = true` 背后做了什么

这和 nixpkgs 里 [`programs.niri.enable`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/programs/wayland/niri.nix)
是同一套路。NixOS 的 `programs.*` 选项是把"组装一整张桌面"这种繁琐事集中在一个开关后面。翻开这一闸:

| 系统旋钮 | 为 nourish 干的事 |
| --- | --- |
| `environment.systemPackages` | 合成器 + `xwayland`(二进制)+ `vulkan-tools`(`vulkaninfo` 在 PATH 方便首检 GPU)+ `libxcb` + `xcb-util-cursor`(X11 client lib surface);`enableVulkanValidation` 开启时再加 `vulkan-validation-layers` |
| `services.displayManager.sessionPackages` | 注册 `wayland-sessions/y5.desktop`,GDM/SDDM/ly 能列出 "Y5" 会话。包带 `passthru.providedSessions = [ "y5" ]`,这是 nixpkgs `sessionData.desktops` 聚合 derivation 的硬性要求。**不钉 `defaultSession`**(与 hyprland 一致),从而能和 `programs.niri` 等共存不撞;Nourish-only + GDM 时自己设 `defaultSession = "y5"` 防 GDM 循环 |
| `systemd.packages` | 把包里 `lib/systemd/user/` 的三个 unit 装进系统:`y5.service`(主合成器,`BindsTo=graphical-session.target`,由会话封装 `systemctl --user --wait start` 拉起)、`y5-shutdown.target`(退出时撕掉 graphical-session.target)、`xwayland-satellite.service`(X11 桥,作者的 y5-fork)。canonical nixpkgs 模式(见 `services/system/systemd-lock-handler.nix`) |
| `systemd.user.services.xwayland-satellite` | `wantedBy = [graphical-session.target]`——会话 target 一拉起 satellite 自动跟起,所以「X11 应用能用」是零配置。`y5.service` 与 satellite 均设 `restartIfChanged=false`(rebuild switch 不杀活跃会话)、`enableDefaultPath=false` 防 NixOS 默认 unit 的 `Environment="PATH=…"` 踩会话封装的 PATH |
| `xdg.portal.enable` + `extraPortals` | `xdg-desktop-portal-gtk` + `xdg-desktop-portal-gnome` |
| `xdg.portal.config.nourish` | 路由标准实现:`default=[gnome gtk]`、`Access→gtk`、`FileChooser→gtk`(无 nautilus 依赖)、`Notification→gtk`、`Secret→gnome-keyring`。以 `XDG_CURRENT_DESKTOP=Y5Compositor`(会话封装设的)为键 |
| `security.pam.services.y5-lock` | 合成器锁屏调 `pam_start("y5-lock", …)`;没有这个服务 PAM 走默认路径会**拒绝**解锁 |
| `security.polkit.enable` | 合成器 `y5-polkit-agent` 对话的 daemon |
| `hardware.graphics.enable`(+x86 上 `enable32Bit`) | GL(mesa)**以及** Vulkan loader(`libvulkan` + ICDs)——合成器运行时 `dlopen` 这些;没有会在 `vkCreateInstance` 崩 |
| `programs.xwayland.enable` | 装 freedesktop 官方 `Xwayland` 二进制到 system PATH——`xwayland-satellite` 运行时 `Command::new("Xwayland")` spawn 它做 rootless X11。此旋钮**只装二进制不启进程**;真正起 X 桥的是上面那个 `xwayland-satellite.service` user unit |
| `services.gnome.gnome-keyring.enable` | 背书 portal `Secret` 实现 + 一般秘密存储 |

一切用 `lib.mkDefault` / `lib.mkIf`,所以你有最终决定权——上面每一行都能从自己的 config 覆盖。

---

## 为什么这个构建不平凡(以及 flake 怎么处理)

fresh clone 的 nourish 仓库**一个 `Cargo.toml` 都没有**。962 个清单全部由一个 Node 脚本**生成**:

```
vendor.catalog.json      外部 crate(精确钉、vendor fork 路径、preset)
workspace.catalog.json   每个 workspace 根的成员/resolver/links/profiles
<crate>/crate.json       该 crate 的依赖名——仅此而已
                ↓  node compositor.workspace/workspace.generate.js
                ↓  写出 962 个 Cargo.toml + .gitignore 的忽略块
```

上游自己的 `environment/build.sh` 在每次 `cargo build` 前都跑这个生成器。我们在 `package.nix` 的 `postPatch` 里做件完全一样的事——而且 `postPatch` 在 `cargoSetupPostPatchHook` 的 Cargo.lock 一致性检查之**前**跑,所以待 worktree 被校验时清单+锁文件都在位。

一份预生成的 `./Cargo.lock`(1494 个 crate,**全是 crates.io,line git+ 一个没有**,所以 `importCargoLock` 无需 `outputHashes`)作为 fixed-output derivation 提交,实现 hermetic 离线构建。本地路径依赖(`smithay`/`input`/`pam-sys` 走 `[patch.crates-io]`,另外约 600 个 `compositor_*` 内部 crate)在构建时从完整拉下来的源码树 resolve,不走 vendor 目录。

### 编译产物:native 后端 + Vulkan 渲染器

`cargo build --no-default-features --features backend-native,renderer-vulkan`:

- `backend-native`——真机上的 DRM/KMS(默认的 `backend-winit` 只能在已有 Wayland 会话**嵌套**跑,做登录桌面没用)。
- `renderer-vulkan`——经 `native-wire-entry` crate 级联拉进整个 `kernel.vulkan` 渲染器 + `ash = =0.38.0+1.3.281`(Vulkan 1.3.281 头) + smithay 的 `backend_vulkan`。这是本 flake 的重点。

`buildType` 默认是 **`releasefast`**——这是仓库日常 `release-fast` 配置(发布优化、无 fat LTO、16 个 codegen units)的**去连字符**化名。为何要改名:nixpkgs 的 cargo-build-hook 做的是 `export "CARGO_PROFILE_${cargoBuildType@U}_STRIP"=false`,连字符会让变量名变成 `RELEASE-FAST` 而在 shell 里失效。`postPatch` 里加了 `[profile.releasefast]` (`inherits = "release"`, `lto = false`, `codegen-units = 16`) 这个等价别名。发布 tag 时改 fat-LTO `release`:

```nix
{ programs.nourish.package =
    inputs.nourish-flake.packages.x86_64-linux.y5-compositor.override
      (_: { buildType = "release"; });
}
```

`vk_diag`、GpuAss 等诊断路径要多一个 cargo 特性:`extraBuildFeatures = [ "vulkan-validate" ]`(NixOS 模块也提供了 `programs.nourish.enableVulkanValidation = true` 这个开关)。

### X11:作者 fork 的 xwayland-satellite

nourish 不走 smithay 内置的 rootless Xwayland,而是在 `compositor.installer/component/xwayland-satellite/xwayland-fixes/` 自带一份上游 [xwayland-satellite](https://github.com/Supereeeme/xwayland-satellite) 0.8.1 的 fork,带三个 y5 专属补丁(`--force-scale 1 --ignore-fractional-scale --popup-fix`,后者是为了修 Isaac Sim 的「拖到外部窗口」面板边框崩)。本 flake 照实 mirror:

- `package.nix` 里开一个独立的 `let`-bound `buildRustPackage`(卫星有自己的 `Cargo.lock` ≈ 140 crate、无 git 依赖),把子树 `compositor.installer/component/xwayland-satellite/xwayland-fixes` 当 src。
- tarball 里没 `.git`,作者的 `build.rs` 用 `vergen-gitcl` 嵌 `git describe` 会失败──所以在 `postPatch` 里把 `build.rs` 替成 no-op 只发 `VERGEN_GIT_DESCRIBE=VERGEN_IDEMPOTENT_OUTPUT`,`src/lib.rs` 里已有这个 sentinel 的 fallback(退到 `CARGO_PKG_VERSION` = 0.8.1)。
- 作者的 `xwayland.service` 装 `lib/systemd/user/` 里(`substituteInPlace` 修 `/usr/bin/xwayland-satellite` 与 `/bin/sh` 为 Nix store 路径,并注入 `Environment=PATH=/run/wrappers/bin:/run/current-system/sw/bin:…` 让 satellite 找得到系统 `Xwayland`)。

启动链路(这才是「X11 应用能用」的完整路径):

```
DM 选 y5.desktop → y5-session 封装
  ├ systemctl --user --wait start y5.service
  │     ↑ BindsTo=graphical-session.target → 自动拉起该 target
  │         ↑ xwayland-satellite.service 的 [Install] WantedBy=graphical-session.target
  │             (module 里设的 wantedBy 生成 .wants 软链)
  │             ↑ ExecStartPre 等 60s 直到 compositor 把 WAYLAND_DISPLAY 推到 dbus-activation env
  │             ↑ Command::new("Xwayland") : 12 --force-scale 1 --ignore-fractional-scale --popup-fix
  └ 退出 → y5-shutdown.target 撕掉 graphical-session.target
```

---

## 维护:更新钉住的 commit / Cargo.lock

flake 钉一个 commit (`1280e12c…) + 一份匹配的 `./Cargo.lock`。跟进上游:

```sh
NEW=$(git ls-remote https://github.com/y5-snowies/nourish \
        refs/heads/upstream-integration | cut -f1)
# 1. 重算 fetchFromGitHub 的哈希(用 FOD 构建验证):
nix-prefetch-url --unpack --type sha256 \
  "https://github.com/y5-snowies/nourish/archive/$NEW.tar.gz"
nix hash to-sri --type sha256 <那个输出>
# 2. 把新 SRI 贴进 flake.nix 和 nixos/module.nix 两处 srcMeta。rev 也要改。
```

从**新** rev 源码树重新生成锁文件(FOD 从 source resolve,所以这一步要在本地 checkout 上做):

```sh
git clone --branch upstream-integration https://github.com/y5-snowies/nourish
cd nourish && node compositor.workspace/workspace.generate.js
cargo generate-lockfile --manifest-path compositor.kernel/kernel.loader/Cargo.toml
cp compositor.kernel/kernel.loader/Cargo.lock <path-to>/nourish-flake/Cargo.lock
```

### 需不需要迭代 cargoHash?

当前 flake 用 `cargoLock.lockFile`,所以**没有** `cargoHash` 要迭代。`importCargoLock` 直接从锁文件本身派生 vendor 目录的 FOD 哈希。你唯二要修的哈希是:

1. `srcMeta.hash`——GitHub tarball(上面)。
2. 如果上游往锁文件里引入了 `git+` 源,把它加进 `cargoLock.outputHashes` 并钉死(跑 `nix build`,从报错里拷"got: sha256-…")。本次提交的锁文件一行 `git+` 都没:

   ```sh
   grep -c 'source = "git+' ./Cargo.lock   # → 0
   ```

---

## 文件

```
flake.nix                 入口:packages + devShells + nixosModules + overlay
Cargo.lock                预生成(1494 crate,全 crates.io,default-settings.json     首次登录播种用的 Vulkan-默认 settings.json
nixos/
  package.nix             from-source buildRustPackage(postPatch 里跑生成器);并 build 一个 `let` 子派生编译作者的 xwayland-satellite fork
  module.nix              programs.nourish.*——整张桌面管道
  devshell.nix            镜像 install-deps.sh 的 nix develop shell
  y5-session              登录会话封装(播种 settings.json、清 WAYLAND_DISPLAY、设 XDG_CURRENT_DESKTOP;有 systemd-user 时 `systemctl --user --wait start y5.service`,退时拉 `y5-shutdown.target`;否则 fallback 直 exec 合成器)
  y5.service              主合成器 user unit(`BindsTo=graphical-session.target`);`@compositor@` 在 package.nix 里被 substitute 成 store bin。拉起后自动带起 satellite
  y5-shutdown.target      退出时撕掉 graphical-session.target 的 shutdown target
  y5-session.desktop      GDM/SDDM/ly 读的 wayland-sessions 条目
  y5-lock.pam             锁屏 PAM 服务(pam_start "y5-lock")
```

---

## 已验证的状态

- **结构**:`nix flake check --no-build` → `all checks passed!`(packages、devShells、formatter、两个 NixOS module、overlay 全部 eval 通过)。
- **NixOS 模块**:`nixosSystem { modules=[nourish]; programs.nourish.enable=true; services.displayManager.ly.enable=true; }` 评估通过,每个选项都 resolve——`sessionPackages=[y5-compositor]`、portal config、PAM `y5-lock` 服务、`hardware.graphics`、xwayland、polkit、keyring 全部经真实 module-system eval 断言通过。与 `programs.niri` 同开验证了**不撞 `defaultSession`**(改成 hyprland 风格:只注册会话、不钉默认)。
- **ly 启动链**:经 ly C 源码 (`src/auth.zig`) + nixpkgs `ly.nix` + nixpkgs `xsession-wrapper` 三方验对——`ly` 调 `setup_cmd=sessionData.wrapper` 再 exec `y5.desktop` 的 `Exec=`(我们的 `y5-session` 封装),后者播种 settings.json、导出 `XDG_CURRENT_DESKTOP=Y5Compositor`、exec 合成器。
- **源 FOD**:`fetchFromGitHub` 哈希与 `nix-prefetch-url` 一致(`sha256-FldDOOO+JLyFjW6zaJa7FTJWA+33qiox9HlNbATLhTQ=`)。
- **Cargo.lock**:`importCargoLock` 接受(返回有效 cargo-vendor-dir);无 `git+` 源。
- **清单生成**:fresh clone 上跑 `node workspace.generate.js` → 962 个 `Cargo.toml`,`cargo generate-lockfile` 成功(1494 包,ash=0.38.0+1.3.281=Vulkan 1.3.281)。
- **端到端编译** ✅:用本地等价源树跑通了完整 `nix build .#y5-compositor`——修复了一个只有真编译才会暴露的 bug(cargo-build-hook 的 `CARGO_PROFILE_<TYPE>_STRIP` 不接受连字符 profile 名;改用 `releasefast` 化名)。产物 `y5_compositor` 是 185 MB ELF,正确链接 `libvulkan.so`/`libdrm.so`/`libgbm.so`,`providedSessions = ["y5"]`、session 封装、`y5.desktop` 均已安装入位。
- **xwayland-satellite 子派生** ✅:作者 fork 的 satellite 作为独立 `buildRustPackage` 成功编译(`--profile release`,115s,140 crate),FOD 子树源在 `compositor.installer/component/xwayland-satellite/xwayland-fixes` 正确切出;独立的 `Cargo.lock` 经 `cargoSetupPostPatchHook` 一致性校验通过(无 git 依赖)。关键的 `build.rs` 在无 `.git` tarball 里的问题以 `postPatch` 替成 no-op 发 `VERGEN_GIT_DESCRIBE=VERGEN_IDEMPOTENT_OUTPUT` sentinel 解决,生成 `src/lib.rs` 退到 `CARGO_PKG_VERSION`=0.8.1 的 fallback 路径。`xwayland.service` 被装入 `$out/lib/systemd/user/xwayland-satellite.service`(nixpkgs 的 hook 把 `lib/systemd/user` 重定位为指向 `share/systemd/user` 的符号链,一套文件原 inode);`substituteInPlace` 把 `/usr/bin/xwayland-satellite` → Nix store bin、`/bin/sh` → Nix store bash,`sed` 注入的 `Environment=PATH=/run/wrappers/bin:/run/current-system/sw/bin:…` 全部落位;三个 y5 专属 flag(`--popup-fix --force-scale 1 --ignore-fractional-scale`)完整保留。
- **systemd 线联调**:真 `nixosSystem` eval 确认 `systemd.user.services.xwayland-satellite.wantedBy = ["graphical-session.target"]` 进入了模块图(即 compositor 一拉 `y5.service` 自动带起 satellite),`sessionNames=["y5"]`,`sat`/`y5` 均 `restartIfChanged=false`。
