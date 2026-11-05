# Debian 13 + Plasma 6.7 + X11 + GPU 渲染

`debian` 分支只有这一个模板 `templates/aarch64/Dagu-KDE.Dockerfile`：Debian 13 (trixie) 底座，KDE Plasma 6.7.4 桌面，显示走 Termux:X11（`DISPLAY=:5`），渲染走 Mesa + `kgsl`（Freedreno），面向 dagu（`4.19.157`）的 Droidspaces 容器。

## 结论

可行，但有一个不能绕开的代价：**Plasma 6.7 必须把 glibc 从 trixie 的 2.41 升到 2.43**。

| 结论 | 证据 |
| --- | --- |
| Debian 13 自带 Plasma 6.3.6，trixie-backports 没有 Plasma | trixie 的 `plasma-workspace 4:6.3.6-2`；`trixie-backports` 查 `plasma-desktop` 为 "Package not available in this suite" |
| 6.7.4 只在 unstable/forky | `plasma-workspace 4:6.7.4-2`、`plasma-desktop 4:6.7.4-1+b1`、`kwin-x11 4:6.7.4-1+b1`（arm64 均有） |
| Qt 6.11.2 要求 glibc ≥ 2.43 | `libqt6gui6:arm64=6.11.2+dfsg-7 依赖 libc6 (>= 2.43)`，trixie 只有 2.41 |
| X11 会话随 6.7 一起结束 | 上游在 Plasma 6.8 去掉了 X11 会话，6.7 是最后一个带 `kwin-x11` 的版本；unstable 里 `plasma-workspace` 仍提供 `/usr/bin/startplasma-x11` 与 `/usr/share/xsessions/plasmax11.desktop` |
| 4.19 内核只能配 systemd 257 | systemd 262 依赖的接口 4.19 没有，本方案因此把运行时栈钉在 257 |

所以本模板做的是「trixie 底座 + unstable 的 KDE 栈」：底座（systemd、udev、dbus、kmod、init-system-helpers）按精确版本钉死在 trixie，只让 KDE/Qt/KF6 以及它们硬依赖的少数库走 unstable。

## 依赖解析结果

在 arm64 的 trixie + unstable 索引上，用 61 个 unstable 目标包跑 `apt-get -s install --no-install-recommends`（prefs 只有 trixie 精确版本 pin 1001）：

```
升级了 18 个软件包，新安装了 880 个软件包，要卸载 0 个软件包
```

| 类别 | 包 |
| --- | --- |
| glibc 族（被迫） | `libc6 2.41 → 2.43`、`libc-bin`、`locales`、`libc-l10n` |
| 编译器运行时 | `libstdc++6`、`libgcc-s1` |
| 基础库 | `libpcre2-8-0`、`libexpat1`、`libelf1t64`、`zlib1g`、`dmidecode` |
| ncurses 族 | `ncurses-base`、`ncurses-bin`、`ncurses-term`、`libncursesw6`、`libtinfo6` |
| dbus 数据包 | `dbus-session-bus-common`、`dbus-system-bus-common`（`dbus-daemon` 仍是 trixie 1.16.2） |

systemd、udev、dbus-daemon、libdbus-1-3、kmod 全部保持 trixie 版本；`debian_unstable_verify` 在装完 KDE 后把 unstable 源排除在外，逐包比对「已安装版本」与「trixie 候选版本」，两者不一致即构建失败。trixie-updates 的补丁版本可以通过，unstable 的版本不能。

三处与 apt 有关的实现约束（`scripts/desktops/kde.sh` 内有对应注释）：

| 约束 | 原因 | 处理 |
| --- | --- | --- |
| `Pin: release n=unstable` 不生效 | 镜像的 suite 是 `sid`，apt 按 sources 里写的套件名匹配，pin 静默失效 | pin 与 sources 用同一个套件名（默认 `sid`） |
| `Package: *` 低优先级兜底 | 求解器在 `(= 精确版本)` 依赖上先挑高优先级候选再报不可安装，`breeze` 因 `breeze-wallpaper (= 4:6.7.4-1)` 失败 | 不加兜底 pin，只钉底座 |
| `dbus-x11` 作为 unstable 目标 | 它的 `dbus-daemon (= 1.16.2-8)` 会把整个 dbus 拉到 unstable 并卸载 `dbus` 元包 | 从 unstable 目标列表移除 |

## 显示与渲染

| 环节 | 配置 |
| --- | --- |
| 显示服务 | Droidspaces `--x11`：Android 端起 Termux:X11，socket `/tmp/.X11-unix/X5` 挂进容器，登录 shell 得到 `DISPLAY=:5` |
| 会话 | `/etc/droidspaces-desktop.conf` 写 `DESKTOP=kde`、`DISPLAY_BACKEND=x11`；`desktop-session.service` 以 1000 号用户执行 `/usr/local/bin/start-desktop-session` → `startplasma-x11` |
| 渲染 | `/etc/environment` 写 `MESA_LOADER_DRIVER_OVERRIDE=kgsl`、`TU_DEBUG=noconform`；Mesa 来自 `install-mesa`（`debian_trixie_arm64` 包，arm64 专用构建） |
| 合成器 | `KDE_COMPOSITING=true` 时 kwin 走 OpenGL 合成，在 kgsl 上采样窗口内容得到全黑；默认关闭（`kwinrc` `[Compositing] Enabled=false`），应用自身的 GL/EGL 仍走 GPU |
| GPU 节点 | Droidspaces `--gpu` 镜像 `/dev/kgsl-3d0`、`/dev/dri/renderD*`；容器用户需在 `droidspaces-gpu` 组（gid 786，构建时已加） |
| socket 桥接 | `droidspaces-x11-bridge.service` 把 `/mnt/termux/.X11-unix` 整个目录挂到 `/tmp/.X11-unix`；`droidspaces-x11-watch.path` 盯着 `/tmp/.X11-unix/X5`，socket 出现就拉起 `desktop-session.service` |

4.19 厂商内核没有 `msm` DRM，只有 `/dev/kgsl-3d0`，因此不能走 Zink/VirGL 那套；Freedreno 的 `kgsl` 后端是唯一的硬件 GL 路径。Mesa-for-Android 的 `libEGL_mesa`/`libgallium` 链接 `libLLVM.so.19.1`，所以镜像必须装发行版的 `libllvm19`（trixie 自带 `1:19.1.7-3+b1`）；缺它时 `libEGL_mesa` 加载失败，`glxinfo` 报 `couldn't find RGB GLX visual or fbconfig`，kwin 与 plasmashell 都起不来。

### kwin 合成器实测

| 后端 | 结果 |
| --- | --- |
| OpenGL / GLX（freedreno kgsl） | 窗口内容全黑，只剩 kwin 自己绘制的标题栏与按钮 |
| OpenGL + `LIBGL_ALWAYS_SOFTWARE=1`（llvmpipe） | 正常 |
| QPainter | 正常 |
| OpenGL ES / EGL（`KWIN_COMPOSE=O2ES`） | 上下文创建失败（`Invalid QOpenGLContext::globalShareContext()`），kwin 退出 |

同一份 kwin、同一个 X 服务器，只换 GL 实现，结果在「全黑」与「正常」之间切换，因此失败点在把其他窗口的 pixmap 采成 GL 纹理这一步（`GLX_EXT_texture_from_pixmap` / DRI3 dmabuf 导入）。llvmpipe 与 QPainter 都改用 X 端拷贝，不经过这条路径。`MESA_DRI3_DISABLE_PRESENT_WAIT_FENCE=1` 不改变结果。termux-packages 上同类非原生 GL 栈的合成失败见 [#32067](https://github.com/termux/termux-packages/issues/32067)。

## 构建

```sh
./build.sh -a aarch64 -i Dagu-KDE -v v20261102-120000
```

`templates/aarch64/Dagu-KDE.env` 提供默认值，环境变量优先：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `KDE_STACK` | `unstable` | `trixie` 时退回发行版原生 Plasma 6.3.6，完全不碰 unstable |
| `DISPLAY_BACKEND` | `x11` | 只能是 `x11`，本模板没有 Wayland 后端 |
| `KDE_COMPOSITING` | `false` | `true` 时打开 kwin 的 OpenGL 合成器 |
| `ENABLE_MESA` | `true` | 装 arm64 的 Mesa；关掉则用发行版 Mesa（无 kgsl 驱动） |
| `KDE_UNSTABLE_SNAPSHOT` | 空 | 填 snapshot.debian.org 的时间戳可复现构建，套件改用 `unstable` |
| `ENABLE_SYSTEMD257` | `true` | 调用 `systemd257.sh` 做版本闸门；Debian 13 已是 257，脚本检测后跳过 |

### systemd 与 4.19

4.19 内核上验证过的 systemd 是 257，本镜像在两个层面把它固定下来：

- 构建期：`KDE_DEBIAN_BASE_PINNED` 把 systemd 家族按精确版本钉在 trixie，`debian_unstable_verify` 在装完 KDE 后逐包比对已安装版本与 trixie 候选版本，不一致即失败；模板随后再断言 `systemctl --version` 的主版本为 257、`systemd`/`udev`/`libsystemd*`/`libudev*` 全部落在 `257.*`。断言失败直接中断构建，不会产出镜像。
- 运行期：发行版自带的 257 即目标版本，不再替换整套 systemd；networkd 仍使用 `rootfs/` 里的 `10-droidspaces.network`（`IPv6AcceptRA=no`）与 `ds-nat6.service`，绕开 networkd 257 用 nexthop 对象下发 RA 路由、而 4.19 不支持的老问题。

`ENABLE_SYSTEMD257=true` 调用的是与上游同一份 `systemd257.sh`：它的预构建包族只覆盖 Ubuntu 26.04、Fedora 43/44 和 Arch；对已经是 257 的发行版（Debian 13 就是）只记录一行后返回，不重装也不报错。改成 `false` 只跳过这一层检查，构建期的版本断言仍然生效。

## 使用

导入与向导的逐项取值见 [README 的安装章节](../README.md#32-向导逐项取值)，这里只记与本模板实现相关的部分。

命令行等价形式：

```sh
droidspaces --name=kde --rootfs-img=dagu-kde.img --init=/sbin/init \
  --net=nat --dns=223.5.5.5,8.8.8.8 --gpu --pulse-audio --allow-sandboxing \
  -B /data/data/com.termux/files/usr/tmp:/mnt/termux start
```

`--x11` 会让 Droidspaces 以 termux 用户 `app_process` 起 Termux:X11，这一步在 dagu 上会直接重启设备（命令无输出、`uptime` 归零），因此容器启动时不开它，X 服务器由 Android 侧的 Termux:X11 应用提供。镜像内的 `droidspaces-x11-bridge.service` 在启动时把 `/mnt/termux/.X11-unix` 挂到 `/tmp/.X11-unix`，`desktop-session.service` 排在它之后。手工补这一步仍然可用：

```sh
/usr/local/bin/droidspaces-x11-bridge      # 幂等：已挂载或源目录不存在时直接返回
systemctl restart desktop-session
```

`desktop-session.service` 的 `ExecCondition` 只判断后端是不是 x11。socket 就绪与否不参与判断：开机时 Termux:X11 通常还没启动，把「还没到」当成「不需要启动」会让单元被判 `exec-condition` 之后不再重试。会话脚本自己最多等 15 秒，等不到按成功退出并把原因写进 journal；`droidspaces-x11-watch.path` 监视 `/tmp/.X11-unix/X5`，文件一出现就再次 start 该单元，所以不需要手工介入。按成功退出而不是失败退出，是为了避免撞上 `StartLimitBurst` 之后 path 触发的 start 被拒绝。

顺序不能反：`-B` 在启动时就把源目录挂进来，先起容器再起 X 服务器会挂到空目录。显示号 `:5` 每次开机只能启动一次；在已有服务器的情况下再执行 `termux-x11 :5`，会先删掉 `X5` 再 bind 失败，文件消失后容器里一直是空目录。没有图形界面时可以用 loader 手工起服务器（显示号固定 `:5`）：

```sh
su -c 'T=/data/data/com.termux/files/usr; CLASSPATH=$T/libexec/termux-x11/loader.apk \
  TMPDIR=$T/tmp setsid /system/bin/app_process -Xnoimage-dex2oat / \
  --nice-name="termux-x11 com.termux.x11 :5" com.termux.x11.Loader :5'
```

实测（Adreno 650 / 4.19）：`glxinfo -B` 报 `freedreno (0x5143)`、`FD650`、Mesa 26.3.0、`direct rendering: Yes`；`glmark2 -b build:duration=2` 在 640x360 下 935 分；`systemctl is-active desktop-session` 为 `active`，`plasmashell`、`kwin_x11`、`ksmserver` 都在。

## 音频与 Docker

**音频**：容器以 `enable_pulseaudio=1` 启动时，Droidspaces 用 Termux 的 `pulseaudio`（以 `u0_a289` 运行，留在 `droidspacesd` permissive 域）在 Android 侧起服务，并把 socket 桥到 `/tmp/.pulse-socket`。

能否出声取决于 Termux 那份 `pulseaudio` 的配置，不是镜像能决定的。原样安装的 `$PREFIX/etc/pulse/default.pa` 里有一条 `load-module module-sles-sink`，它在多数设备上缺 Android HAL 依赖：sink 会出现、`speaker-test` 也不报错，但 `dumpsys media.audio_flinger` 里 track 永远是 `0 are active`，也就是没有声音。上游的 `setup-termux.sh` 做的正是这份修补，手工装过 Termux 环境的话需要自己补：

```sh
P=/data/data/com.termux/files/usr/etc/pulse/default.pa
sed -i 's|^load-module module-sles-sink|#&|' "$P"
sed -i 's|^load-module module-console-kit|#&|' "$P"          # Android 没有 system bus，会 futex 死锁
sed -i 's|^load-module module-suspend-on-idle|#&|' "$P"      # 切音频设备时会死锁
# 把 module-aaudio-sink 放到 module-always-sink 之前，然后重启 pulseaudio
```

改完只剩 `AAudio_sink` 时，播放期间 AudioFlinger 会显示 `1 Tracks of which 1 are active`，声音正常。另外 pulseaudio 重启后 `.pulse-socket` 是新 inode，容器里 bind 的 `/tmp/.pulse-socket` 还是旧 inode，`pactl` 会报 `Connection refused`；此时在容器内用 `/mnt/termux/.pulse-socket`（宿主 tmp 目录整目录 mount 进来的）即可绕过，或重启容器。

`droidspaces run` 用的是 Android 的 PATH 与环境，里面没有 `PULSE_SERVER`，ALSA 的 pulse 插件会连默认路径并报 `-112 Host is down`；用 `su -l dagu -c ...` 或自己 export 即可。开 `enable_pulseaudio=1` 本身不会像 `--x11` 那样重启设备。

**网络**：Droidspaces 的 NAT 走宿主转发，链路 MTU 不足 1500。容器 eth0 按 1500 走时，超路径 MTU 的报文被静默丢弃，表现是下载、视频加载偶发卡在 0 字节——同一个文件 1500 下 5 次里 2 次超时，1400 下 5 次全部成功（3.4–7 MB/s）。镜像里把 `MTUBytes=1400` 写在 `/etc/systemd/network/10-droidspaces.network` 的 `[Link]` 段，跟 DHCP 同一个文件——networkd 对同一接口只取第一个匹配的 `.network`，拆开写会让其中一份失效。

**Docker**：trixie 自带的 `docker.io` 冻结在 26.1.5，模板改用 Docker 官方仓库（`download.docker.com/linux/debian`，trixie/arm64）装 `docker-ce` 29.9.2、`containerd.io` 2.4.2、`docker-buildx-plugin` 0.38.1、`docker-compose-plugin` 5.7.0，`update-alternatives` 仍切到 `iptables-legacy`。版本由 `DOCKER_VERSION` / `CONTAINERD_VERSION` 控制，留空装候选版本；`DOCKER_SOURCE=debian` 可退回发行版包。dockerd 以 overlay2 起得来，`docker run --rm hello-world` 实测通过；`/etc/docker/daemon.json` 预设了 `docker.m.daocloud.io` 与 `docker.1ms.run` 两个镜像源。

**浏览器**：镜像只装 `firefox-esr`，并用 `/usr/lib/firefox-esr/defaults/pref/droidspaces.js` 关掉 `about:welcome`、把首页设成 `about:blank`、关掉遥测与默认浏览器询问，同时设 `browser.tabs.inTitlebar=0` 让窗口使用 KWin 标题栏——镜像不装 GTK 主题，Firefox 自带标题栏（CSD）的最小化/最大化/关闭按钮画不出符号。Chromium 不再预装：它的内容进程在这套 kgsl + Termux:X11 上要 `--disable-gpu-compositing` 才不全屏回退、要 `--autoplay-policy=no-user-gesture-required` 才不静音自动播放，参数负担重。Edge 没有 Linux/arm64 版本，`packages.microsoft.com` 的 `binary-arm64` 索引为空。

## 验证

容器内：

```sh
cat /etc/droidspaces-desktop.conf          # DESKTOP=kde / DISPLAY_BACKEND=x11
systemctl status desktop-session.service   # active (running)
startplasma-x11 --version                  # Plasma 6.7.x
dpkg -s plasma-workspace | grep Version    # 4:6.7.4-*
systemd --version                          # systemd 257
glxinfo -B | grep -E "renderer|OpenGL"     # Vendor: freedreno / Device: FD650 / direct rendering: Yes
glxgears -info                             # 5 秒约 600 帧（vsync 封顶 120 FPS）
```

宿主：

```sh
su -c "cat /run/droidspaces/containers/kde/container.config" | grep -E "enable_x11|enable_gpu_mode"
```

## 已知风险

| 风险 | 说明 | 回退 |
| --- | --- | --- |
| glibc 混装 | 2.43 的 `libc6` 配 257 的 systemd 属于 Debian 不支持的 partial upgrade | `KDE_STACK=trixie` 重新构建，退回 Plasma 6.3.6 |
| kwin 合成器 | 打开后窗口内容全黑，只剩 kwin 绘制的装饰（矩阵见上）；属于 kgsl 的 texture-from-pixmap 限制 | 默认关闭（`KDE_COMPOSITING=false`）；需要合成时用 `KWIN_COMPOSE=Q` 或 llvmpipe，应用仍走 GPU 的 GLX/EGL |
| 视频解码 | 没有 `msm` DRM 就没有 VA-API，1080p 由 CPU 软解；内存吃满时掉帧 | 降低播放分辨率、关闭多余程序 |
| 浏览器 | Microsoft Edge 没有 Linux/arm64 版本；Chromium 需额外参数才能正常全屏/发声 | 镜像内置 Firefox ESR，默认值见上 |
| 容器网络 | Droidspaces `--net=nat` 依赖容器内 DHCP 客户端；`systemd-networkd` 被屏蔽时 eth0 拿不到地址、DNS 全失效 | 镜像已保留 networkd/resolved，只屏蔽 udevd 与 NetworkManager |
| Plasma 6.8 | 上游去掉 X11 会话，本方案停在 6.7.x 不再上移 | 无：再往上必须转 Wayland |
| amd64 动态程序 | 装了 `qemu-user-static` 与 `binfmt-support`，静态 x86_64 二进制可执行；动态程序缺 amd64 的 `libc6`（glibc 2.43 与 trixie 的 2.41 无法并存） | 只用静态二进制，或另行从 unstable 取同版本 `libc6:amd64` |
| Mesa 版本 | `install-mesa` 装的是预编译 arm64 包，版本跟随上游发布 | `install-mesa --uninstall` 回到发行版 Mesa（kgsl 不可用） |

## 复现依赖解析

不需要设备或构建机，用 arm64 索引即可验证 apt 计划（索引取自 tuna 镜像）：

```sh
export APT_CONFIG=/tmp/deb-sim/apt.conf   # 指向 arm64 的 trixie + sid 索引与合成 status
apt-get -s install --no-install-recommends $(sed 's|$|/sid|' pkgs.txt)
```

61 个 unstable 目标、18 个升级、880 个新装、0 卸载，见上表。
