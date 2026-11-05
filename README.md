# Dagu KDE rootfs（Debian 13）

小米平板 5 Pro 12.4（`dagu`，SM8250，内核 `4.19.157`）上跑的 Droidspaces 根文件系统：Debian 13 + Plasma 6.7，画面经 Termux:X11 输出，渲染走 Mesa 的 kgsl 后端。

本分支只产出一个模板 `Dagu-KDE`。

| 项目 | 内容 |
| --- | --- |
| 发行版 | Debian 13（trixie），arm64 |
| 桌面 | KDE Plasma 4:6.7.4-2 / KDE Frameworks 6.30.0 / Qt 6.11.2，X11 会话 |
| 显示 | Termux:X11，`DISPLAY=:5`，socket `/tmp/.X11-unix/X5` |
| 渲染 | Mesa 26.3.0（`MESA_LOADER_DRIVER_OVERRIDE=kgsl`），Adreno 650 / freedreno |
| init | systemd 257.13（4.19 内核上验证过的版本） |
| 容器 | Docker 29.9.2 + buildx 0.38.1 + compose 5.7.0（官方仓库），overlay2 |
| 浏览器 | Firefox ESR（首启不等外网、首页 `about:blank`） |
| 用户 | `dagu` / `1234`，`sudo` 免密 |

## 1. 对 Debian 13 基础镜像做了什么

基础镜像是 `debian:trixie`（未装任何桌面）。构建开头先 `apt-get update && apt-get upgrade -y`，把 trixie 与 trixie-updates 升到构建时的最新版，然后再装下面的包；此时还没有加 unstable 源，不会出现跨套件升级。三张表分别是加进去的包、改过的系统文件、启用的单元。

### 1.1 安装的软件包

| 类别 | 包 |
| --- | --- |
| 基础运行时 | `bash` `ca-certificates` `curl` `wget` `jq` `locales` `tzdata` `systemd-sysv` `systemd-resolved` `dbus` `dbus-user-session` `udev` `kmod` `libpam-systemd` `sudo` `openssh-server` |
| 网络工具 | `net-tools` `iproute2` `iputils-ping` `iptables` `bind9-dnsutils` |
| 常用工具 | `procps` `psmisc` `util-linux` `file` `findutils` `grep` `sed` `gawk` `tar` `gzip` `xz-utils` `unzip` `zip` `bash-completion` `less` `git` `nano` `vim` `htop` `lsof` `pciutils` `dialog` `logrotate` |
| 压缩 | `7zip` `unzip` `bzip2` |
| 图形依赖 | `libllvm19`（Mesa-for-Android 的 `libEGL_mesa` 链接 `libLLVM.so.19.1`，缺它 GLX/EGL 全部不可用） |
| 桌面（Plasma 6.7 栈） | `plasma-desktop` `plasma-desktop-data` `plasma-workspace` `kwin-x11` `plasma-pa` `kscreen` `powerdevil` `systemsettings` `kinfocenter` `plasma-systemmonitor` `kde-config-screenlocker` `kio-extras` `xdg-desktop-portal-kde` `kde-cli-tools` `polkit-kde-agent-1` `libpam-kwallet5` |
| 桌面（应用） | `ark` `konsole` `dolphin` `kate` `kfind` `filelight` `dolphin-plugins` `ffmpegthumbs` `kdegraphics-thumbnailers` `kimageformat6-plugins` `breeze` `breeze-icon-theme` `desktop-base` `webext-plasma-browser-integration` |
| 字体与翻译 | `fonts-noto-cjk` `fonts-noto-color-emoji` `qt6-translations-l10n` |
| 显示与 X11 | `xserver-xorg` `x11-xserver-utils` `x11-utils` `xauth` `xkb-data` `libxcb-cursor0` |
| 音频 | `pipewire` `pipewire-alsa` `pipewire-pulse` `wireplumber` `libcanberra-pulse` `pulseaudio-utils` `alsa-utils` `gstreamer1.0-plugins-base` `gstreamer1.0-plugins-good` `sound-theme-freedesktop` |
| 图形验证 | `mesa-utils` `vulkan-tools` `clinfo` `glmark2` `vkmark` `dmidecode` `libdisplay-info-bin` `wayland-utils` `aha` `upower` `xdg-user-dirs` |
| 浏览器 | `firefox-esr` `scrot` |
| amd64 兼容 | `qemu-user-static` `binfmt-support`（注册 binfmt 处理器，静态 x86_64 二进制可直接运行；动态程序还需要 amd64 的 `libc6`，见下） |
| 容器 | `docker-ce` `docker-ce-cli` `containerd.io` `docker-buildx-plugin` `docker-compose-plugin`（Docker 官方仓库，非 trixie 的 26.1.5） |

amd64 兼容只到解释器层面：`qemu-user-static` 提供处理器，`binfmt-support` 负责注册，静态 x86_64 二进制可以直接运行。动态链接的 amd64 程序还需要 amd64 的 `libc6`，而镜像的 glibc 已被 KDE 6.7 栈升到 2.43，trixie 的 amd64 `libc6` 只有 2.41，两个架构的 `libc6` 必须同版本，因此没有装；`ENABLE_binfmt_ARG=false` 可以整套关掉。

Mesa 不用发行版包：构建时调用 `scripts/tui/install-mesa.sh --1`，从 `Goldzxcbug/droidspaces-package` 的 `mesa-for-android-container` 取 `debian_trixie_arm64` 的 arm64 包（26.3.0-devel），并在 `/etc/apt/preferences.d/hold-anland-package` 里把 `libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers` 钉住，避免被 apt 换回发行版版本。

### 1.2 改过的系统文件

| 文件 | 改成了什么 | 原因 |
| --- | --- | --- |
| `/etc/apt/apt.conf.d/99parallel-downloads` | 并行连接、pipeline 深度 10、重试 3 次 | 缩短 CI 构建时间 |
| `/etc/apt/sources.list.d/20-droidspaces-unstable.sources` | 构建期临时加 unstable，装完删除 | 6.7 只能从 unstable 取 |
| `/etc/apt/preferences.d/10-droidspaces-unstable.pref` | 构建期把 `systemd` `udev` `dbus` `init-system-helpers` `kmod` 按精确版本钉在 trixie，装完删除 | 4.19 只验证过 systemd 257，被升到 262 就起不来 |
| `/etc/environment` | `MESA_LOADER_DRIVER_OVERRIDE=kgsl` `TU_DEBUG=noconform` `PULSE_SERVER=unix:/tmp/.pulse-socket` `DISPLAY=:5` `XCURSOR_SIZE=48` `XDG_SESSION_CLASS=user` | 4.19 没有 `msm` DRM，kgsl 是唯一的硬件 GL 路径 |
| `/etc/droidspaces-desktop.conf` | `DISPLAY_BACKEND=x11` | `start-desktop-session` 据此选择 `startplasma-x11` |
| `~/.config/kwinrc` | `[Compositing] Enabled=false` | kwin 的 OpenGL 合成在 kgsl 上采样窗口内容得到全黑 |
| `~/.config/kscreenlockerrc` | `Autolock=false` `LockOnStart=false` | 没有虚拟终端可以执行 `loginctl unlock`，锁屏一失败就是一块黑板 |
| `/home/dagu/.bashrc` | 追加 `XDG_RUNTIME_DIR=/run/user/$(id -u)` | 容器里没有 pam_systemd 自动设置 |
| `/etc/systemd/network/10-droidspaces.network` | `DHCP=yes` `IPv6AcceptRA=no` `KeepConfiguration=yes` | networkd 257 用 nexthop 对象下发 IPv6 RA 路由，4.19 不支持 |
| `/etc/systemd/journald.conf` + `journald.conf.d/ds-logging.conf` | `ReadKMsg=no` `Audit=no` `Storage=volatile`，上限 200M / 7 天 | 容器没有内核日志与审计权限 |
| `/etc/systemd/logind.conf.d/99-power-key.conf` | 电源键、休眠键全部 `ignore` | 避免容器内 logind 抢宿主按键 |
| `/etc/systemd/system/systemd-udev-*.d/99-readonly-fix.conf` | `ConditionPathIsReadWrite=` | 容器 `/sys` 只读，不覆盖会起不来 |
| `/etc/systemd/system/systemd-udev-trigger.service.d/override.conf` | `udevadm trigger` 只扫 `usb block input tty net` | 全量 trigger 在容器里没有意义且很慢 |
| `/etc/systemd/system/*.d/99-netmode-limit.conf` | `ExecCondition` 检查 `net_mode=(nat\|gateway)` | 非 NAT 模式不起网络单元 |
| `/etc/systemd/system/*.d/99-hwaccess-limit.conf` | `ExecCondition` 检查 `enable_hw_access=1` | 没开硬件访问就不起 udev |
| `/etc/logrotate.conf` | `maxsize 50M` | 容器长期运行时的日志上限 |
| `/etc/tmpfiles.d/x11.conf` | `d /tmp/.X11-unix 1777 root root -`，覆盖 `D!` | 该目录是宿主 `$TMPDIR/.X11-unix` 的 bind 挂载，开机清空会删掉活着的 X5 |
| `/etc/ssh/sshd_config` | `PermitRootLogin no`，`PasswordAuthentication yes` | 只允许 `dagu` 登录 |
| `/usr/lib/firefox-esr/defaults/pref/droidspaces.js` | 关 `about:welcome`、首页 `about:blank`、关遥测、用系统标题栏 | 首次启动不去等 mozilla.org；CSD 按钮在无 GTK 主题的镜像里不画图标，改回 KWin 标题栏 |
| `/etc/passwd`、`/etc/group`、`/etc/adduser.conf` | 建 `aid_inet:3003` `aid_net_raw:3004` `aid_net_admin:3005` `droidspaces-gpu:786`，`dagu` 加入 `sudo input video tty aid_inet aid_net_raw droidspaces-gpu` | Android 侧的 AID 与 GPU 节点属组 |
| `/etc/droidspaces` | 写入构建时间戳 | 标记解包后修复已执行 |
| `/etc/droidspaces-kde-stack` | 记录 `stack` `plasma` `qt` `glibc` `systemd` `systemd-verified` | 排查时一眼看到装的是哪套栈 |

locale 默认 `zh_CN.UTF-8`，时区 `Asia/Shanghai`（`ENABLE_ZH_TZ=false` 时切回 `en_US.UTF-8`）。

### 1.3 启用的单元

| 单元 | 作用 |
| --- | --- |
| `desktop-session.service` | 以 `dagu` 身份执行 `start-desktop-session` → `startplasma-x11`，`User=1000`、`PAMName=login`、失败自动重启 |
| `droidspaces-x11-watch.path` | 盯着 `/tmp/.X11-unix/X5`，socket 出现就拉起 `desktop-session.service` |
| `droidspaces-x11-bridge.service` | 把 `/mnt/termux/.X11-unix` 挂到 `/tmp/.X11-unix`，让容器看见宿主 Termux:X11 的 socket（挂目录，X 服务器晚启动也立刻可见） |
| `ds-nat6.service` | 从 DHCPv4 地址派生 `fd64:7370::/48` 内的 IPv6 地址，探测通则保留默认路由 |
| `dagu-firstboot.service` | 首次启动写 `machine-id`，重新 enable 需要按实例生成的单元 |
| `systemd-networkd` `systemd-resolved` | NAT 模式下向 Droidspaces 的宿主 DHCP 要地址、做 DNS |
| `dbus` | 系统总线 |
| `ssh` | 可选，`dagu` 密码登录 |
| `docker` `containerd` | 容器运行时 |
| `qemu-binfmt-register.service` | 挂载 `binfmt_misc` 并确认 qemu 处理器已注册，让 amd64 二进制可直接执行 |

`getty@tty1` 关闭；Anland 专用单元（`anland-session.service`、`/usr/local/bin/start-anland-session`）在打包前删除。

### 1.4 与 trixie 的版本偏离

| 组件 | 镜像内 | trixie 原生 | 说明 |
| --- | --- | --- | --- |
| Plasma | `4:6.7.4-2` | `4:6.3.6-2` | 6.7 是最后一个带 X11 会话的 Plasma |
| KDE Frameworks | `6.30.0` | `6.13` | 6.7 栈要求 KF ≥ 6.26 |
| Qt | `6.11.2+dfsg-7` | `6.8.2` | 6.7 栈要求 Qt 6.11.2（私有 ABI 精确匹配） |
| glibc | `2.43-7` | `2.41-12` | sid 的 Qt 6.11.2 依赖 `libc6 (>= 2.43)` |
| libstdc++6 / libgcc-s1 / libpcre2 / libexpat / zlib | 随之上移 | — | 与 glibc 一起被拉起的 18 个基础包 |
| systemd / udev / dbus | `257.13-1~deb13u1` / `1.16.2-2` | 同 | 钉死在 trixie |

这是 Debian 不支持的混装：装完即摘掉 unstable 源，容器里只面对 trixie，`apt upgrade` 不会触发 partial upgrade。依赖解析过程见 [docs/debian-plasma67.md](docs/debian-plasma67.md)。

## 2. 设备侧前提

1. **内核补丁**：这台机器的 4.19 内核关闭了 `CONFIG_USER_NS`、`CONFIG_SYSVIPC`、`CONFIG_POSIX_MQUEUE`、`CONFIG_IP6_NF_NAT`、`CONFIG_MACVLAN`，需要按 [droidspaces-dagu-kpm](https://github.com/univers629/droidspaces-dagu-kpm) 的说明刷入 KPM。
2. **Termux + Termux:X11**：Termux 提供 `pulseaudio` 与 Termux:X11 的 loader；Termux:X11 应用负责把画面显示出来。两者都要放行后台运行，不要被系统冻结。
3. **ADB**（可选）：命令行建容器、`adb push` 大文件时用。

## 3. 安装

### 3.1 导入镜像

从本仓库 Release 下载 `Dagu-KDE-Droidspaces-rootfs-aarch64-<日期>-<版本>.tar.xz`，放到设备存储（约 790 MB）。打开 Droidspaces，**容器 → + → 从文件安装**，选中该文件。

### 3.2 向导逐项取值

按向导里出现的顺序列全，未列出的项保持默认即可。

| # | 位置 | 项 | 取值 |
| --- | --- | --- | --- |
| 1 | 基本 | 容器名称 | `deb13`（自定，后面命令按这个名字写） |
| 2 | 基本 | 主机名 | `deb13` |
| 3 | 配置 · 网络 | 网络模式 | **NAT** |
| 4 | 配置 · 网络 | DNS | `223.5.5.5,8.8.8.8` |
| 5 | 配置 · 网络 | 禁用 IPv6 | **关**（关掉才走 `ds-nat6` 派生） |
| 6 | 配置 · 集成与硬件 | GPU 访问 | **开** |
| 7 | 配置 · 集成与硬件 | 硬件访问 | 关（不需要 udev 全量扫描） |
| 8 | 配置 · 集成与硬件 | 配置 Termux:X11 | **关**（`--x11` 会让设备重启，见 5.3） |
| 9 | 配置 · 集成与硬件 | 配置 PulseAudio | **开** |
| 10 | 配置 · 集成与硬件 | Anland 显示 | 关 |
| 11 | 配置 · 集成与硬件 | Android 存储 | 按需（开了会挂 `/sdcard`） |
| 12 | 配置 · 安全与启动 | 允许沙箱 | **开** |
| 13 | 配置 · 安全与启动 | 允许 VTS | 关 |
| 14 | 配置 · 安全与启动 | SELinux 宽容 | 关 |
| 15 | 配置 · 安全与启动 | 开机自启 | 关（Termux:X11 得先起来，容器自启没有意义） |
| 16 | 配置 · 高级选项 | 绑定挂载点 | `/data/data/com.termux/files/usr/tmp:/mnt/termux` |
| 17 | 配置 · 高级选项 | 指定 init | `/sbin/init` |
| 18 | 配置 · 高级选项 | 内存 / CPU / PID 上限 | 留空 |
| 19 | 存储 | 使用稀疏镜像 | **开**（`sudo` 需要 ext4 镜像；目录模式挂在 f2fs 上带 `nosuid`） |
| 20 | 存储 | 镜像大小 | ≥ 12 GiB（rootfs 解开约 2.6 GiB） |

### 3.3 命令行等价形式

```sh
su -c "droidspaces --name=deb13 --hostname=deb13 \
  --rootfs-img=/data/local/Droidspaces/Containers/deb13/rootfs.img \
  --init=/sbin/init --net=nat --dns=223.5.5.5,8.8.8.8 \
  --gpu --pulse-audio \
  -B /data/data/com.termux/files/usr/tmp:/mnt/termux start"
```

目录模式把 `--rootfs-img=` 换成 `--rootfs=/data/local/Droidspaces/Containers/deb13/rootfs`。

## 4. 首次启动

显示号 `:5` 每次开机只能启动一次，并且要在容器启动之前起来。容器挂的是宿主 `$TMPDIR/.X11-unix` 这个目录，目录里没有 `X5` 时桥接挂进来也是空的，会话不会被拉起。

1. **在 Termux 里启动 X 服务器**，只启动一次，并确认 socket 文件出现：

```sh
termux-x11 :5 &
sleep 2
ls -l "$TMPDIR/.X11-unix"      # 要能看到 srwxrwxrwx X5
```

2. **启动容器**（Droidspaces 卡片，或 3.3 的命令）。
3. **最后打开 Termux:X11 应用**当显示器。服务器已经在跑，应用只连上去显示画面；此时不要再执行 `termux-x11 :5`，第二次启动会先删掉 `X5` 再 bind 失败，文件消失后容器里一直是空目录。
4. 等 10–30 秒，Termux:X11 窗口里出现壁纸与底部面板。

反过来把应用放在最前面也能用：应用会自己把 `:5` 拉起来，那就跳过第 1 步，不要再执行命令。

容器内依次发生：

- `systemd-networkd` 在 `eth0` 上取 DHCP 地址，同一个单元里把 MTU 钉在 1400；
- `droidspaces-x11-bridge.service` 把 `/mnt/termux/.X11-unix` 挂到 `/tmp/.X11-unix`；
- `desktop-session.service` 等到 socket 后执行 `startplasma-x11`；
- `docker.service`、`containerd.service` 启动。

## 5. 常用命令

宿主侧命令在 `su -c "…"` 里执行；容器内命令用 `sudo droidspaces --name=deb13 enter` 进去后执行。

### 5.1 容器

| 操作 | 命令 |
| --- | --- |
| 启动 | `su -c "droidspaces --name=deb13 start"`（参数同 3.3） |
| 进入终端 | `su -c "droidspaces --name=deb13 enter"` |
| 执行单条命令 | `su -c "droidspaces --name=deb13 run -- <命令>"` |
| 停止 | `su -c "droidspaces --name=deb13 stop"` |
| 查看状态 | `su -c "droidspaces show"` |

`stop` 报 `Container PID … is in an unkillable state` 时，4.19 上容器 init 杀不掉，只能重启设备。

### 5.2 桌面会话

| 操作 | 命令（容器内） |
| --- | --- |
| 重启会话 | `sudo systemctl restart desktop-session` |
| 看会话状态 | `systemctl status desktop-session --no-pager` |
| 手工补挂 X11 socket | `sudo /usr/local/bin/droidspaces-x11-bridge` |
| 检查 socket 是否挂进来 | `ls -l /tmp/.X11-unix` |
| 截图 | `DISPLAY=:5 scrot -o ~/shot.png` |

### 5.3 桌面不出现时按这个顺序排

`--x11` 不要开：Droidspaces 用 termux 用户 `app_process` 拉 Termux:X11 的那条路径在这台设备上会让机器重启。socket 桥接和会话启动由镜像里的 `droidspaces-x11-bridge.service` 与 `droidspaces-x11-watch.path` 负责，正常情况不需要手工执行：只要 X 服务器的 socket 文件出现，会话会被自动拉起。下面三步是兜底排查。

```sh
# 1) Termux：确认 X 服务器活着、socket 文件在
pgrep -f "termux-x11 com.termux.x11"
ls -l "$TMPDIR/.X11-unix"                 # 空的话重启服务器

# 2) Termux：重启 X 服务器（socket 文件被删掉时用）
pkill -f "termux-x11 com.termux.x11"
sleep 1
termux-x11 :5 &
ls -l "$TMPDIR/.X11-unix"                 # 必须能看到 X5

# 3) 容器内：socket 存在的前提下手工补一次（正常由 path 单元自动触发）
sudo /usr/local/bin/droidspaces-x11-bridge
sudo systemctl start desktop-session
systemctl status desktop-session --no-pager | head -5
```

如果 `termux-x11 :5` 报 `Cannot establish any listening sockets` / `server already running`，说明显示号 `:5` 被占：`pgrep -af termux-x11` 找到旧进程并 `kill -9`，再启动一次。打开 Termux:X11 应用本身不会再启动服务器；`X5` 在打开应用之后消失，说明这次开机里 `:5` 被启动了第二次。

### 5.4 浏览、音频、网络

| 操作 | 命令 |
| --- | --- |
| 打开浏览器 | `firefox-esr https://www.bilibili.com`（面板里也有图标） |
| 手动指定软件渲染 | `LIBGL_ALWAYS_SOFTWARE=1 firefox-esr <url>` |
| 看 sink 与音量 | `pactl list short sinks` / `pactl set-sink-volume AAudio_sink 100%` |
| 声音自检 | `pactl info` / `speaker-test -c 2 -t sine -l 1` |
| 看 Android 侧是否真的出声 | 宿主：`su -c "dumpsys media.audio_flinger \| grep 'Tracks of which'"` |
| 改 MTU | `sudo ip link set eth0 mtu 1400`（镜像已默认，临时排查用） |

**Termux 侧音频修补**（只做一次）。默认的 `default.pa` 会建出 sink 但不发声：

```sh
P=$PREFIX/etc/pulse/default.pa
sed -i 's|^load-module module-sles-sink|#&|' "$P"
sed -i 's|^load-module module-console-kit|#&|' "$P"
sed -i 's|^load-module module-suspend-on-idle|#&|' "$P"
# 再确认 module-aaudio-sink 排在 module-always-sink 之前，然后重启 pulseaudio
```

改完的判据：宿主 `dumpsys media.audio_flinger` 播放时显示 `1 Tracks of which 1 are active`。

### 5.5 容器运行时

| 操作 | 命令（容器内） |
| --- | --- |
| 验证 Docker | `docker run --rm hello-world` |
| 看 Docker 版本 | `docker version --format '{{.Server.Version}}'` |
| 装软件 | `sudo apt update && sudo apt install <包>` |

容器里面向 trixie 源，unstable 源在构建完就删了，可以正常 `apt upgrade`（Plasma 会停在 6.7.4）。

## 6. 验证

```sh
systemctl status desktop-session.service      # active (running)
dpkg -s plasma-workspace | grep Version       # 4:6.7.4-*
glxinfo -B | grep -E "Vendor|Device"          # freedreno (0x5143) / FD650
vulkaninfo --summary | grep -m1 deviceName    # Adreno (TM) 650
glmark2 -b build:duration=2 -s 640x360        # 分数参考 280（XRender 会话下）
ip -o link show eth0 | sed 's/.*mtu \([0-9]*\).*/mtu=\1/'   # mtu=1400
pactl info                                    # Server String: unix:/tmp/.pulse-socket
docker version --format '{{.Server.Version}}'  # 29.9.2
```

## 7. 排障

| 症状 | 原因与处理 |
| --- | --- |
| 桌面不出现，`/tmp/.X11-unix` 为空 | Termux:X11 的 socket 文件不存在或没挂进来。按 5.3 走一遍 |
| `desktop-session` 日志里是「X11 socket 尚未出现」 | 会话已按成功退出，`droidspaces-x11-watch.path` 会在 X5 出现后自动再拉起；先确认宿主 `$TMPDIR/.X11-unix` 里有 X5 |
| `termux-x11` 报 `server already running` | 显示号被旧进程占着：`pgrep -af termux-x11` → `kill -9` → 重启 |
| 有画面没声音 | 播放器被自动静音（点喇叭）；或 Termux 的 `default.pa` 没修补（见 5.4） |
| `pactl` 报 `Connection refused` | pulseaudio 重启后 socket inode 变了，容器里挂的还是旧的。用 `PULSE_SERVER=unix:/mnt/termux/.pulse-socket`，或重启容器 |
| 下载 / 视频卡在 0 字节 | MTU 没生效：`ip link show eth0` 应为 1400 |
| `apt update` 先卡十秒再失败 | 镜像已把 IPv4 提到前面（`/etc/gai.conf`）并让 apt 只走 IPv4（`Acquire::ForceIPv4`）；仍失败说明镜像不是最新 |
| 画面全黑只剩光标 | 打开了 OpenGL 合成（`KDE_COMPOSITING=true`）。改回 `false` 并重启会话 |
| `glxinfo` 报 `couldn't find RGB GLX visual` | 缺 `libllvm19`：`ldd /usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0.0.0 \| grep "not found"` |
| 锁屏后只剩黑板 | 锁屏组件在 Termux:X11 下解不开。会话里 `pkill -f kscreenlocker_greet`，或确认 `~/.config/kscreenlockerrc` 里 `Autolock=false` |
| `stop` 报 `unkillable state` | 4.19 下容器 init 杀不掉，重启设备；容器目录仍在，直接再 `start` |

## 8. 已知限制

- **桌面合成器不走 GPU**：kwin 的 OpenGL 合成在 kgsl 上把窗口内容采成黑色（`GLX_EXT_texture_from_pixmap` / DRI3 dmabuf 路径），所以默认 `Compositing=false`，窗口合成走 XRender。应用自身的 GL/EGL 仍是硬件渲染（`glxinfo` 显示 freedreno、`glmark2` 281 分）。
- **没有硬件视频解码**：4.19 厂商内核只有 kgsl、没有 `msm` DRM，VA-API 不可用，1080p 由 4 个核心软解，内存吃满时掉帧。
- **没有 Edge，也没有 Chromium**：`packages.microsoft.com` 的 `binary-arm64` 索引为空，Edge 没有 Linux/arm64 版本；Chromium 在这套 kgsl + Termux:X11 上要额外压启动参数才能正常播放与全屏，镜像只带 Firefox ESR。
- **混装栈**：glibc 2.43、Qt 6.11.2、KF 6.30 来自 unstable，属于 Debian 不支持的组合；要完全原生就 `KDE_STACK=trixie` 构建，得到 Plasma 6.3.6。
- **IPv6 取决于宿主**：宿主没有全局 IPv6 时，容器只有 `fd64:7370::/48` 内地址，出网走 IPv4。
- **`macvlan` 不可用**：Wi-Fi 只收目的地址是自己的帧，用 NAT。
- **声音依赖 Termux 侧修补**：`default.pa` 不改就是不出声的 sink。
- **目录模式不能 `sudo`**：f2fs 挂载带 `nosuid`，要用稀疏镜像或 `droidspaces enter`。

## 9. 自行构建

**GitHub Actions**：推送到 `debian` 分支，或在 Actions 页面手动触发，会构建 `Dagu-KDE` 并发布 Release，同时更新 `rootfs.json`。工作流只构建这一个模板。

**本地**：

```sh
./build.sh -a aarch64 -i Dagu-KDE -v v20261102-120000
```

依赖 Docker（含 buildx）、`jq`、`xz`。产物为 `Dagu-KDE-Droidspaces-rootfs-aarch64-<日期>-<版本>.tar.xz`。模板默认参数在 `templates/aarch64/Dagu-KDE.env`，已导出的环境变量优先。

| 构建变量 | 默认 | 作用 |
| --- | --- | --- |
| `KDE_STACK` | `unstable` | `trixie` 构建 Plasma 6.3.6 原生栈 |
| `KDE_COMPOSITING` | `false` | `true` 打开 kwin OpenGL 合成（kgsl 上黑屏） |
| `ENABLE_MESA` | `true` | 装 Mesa-for-Android（kgsl） |
| `ENABLE_SYSTEMD257` | `true` | 走 `systemd257.sh`；Debian 13 已是 257，脚本检测后跳过 |
| `ENABLE_DOCKER` / `ENABLE_ZIP` / `ENABLE_ZH_TZ` | `true` | 装 Docker / 压缩工具 / 中文 |
| `KDE_UNSTABLE_SNAPSHOT` | 空 | 指定 snapshot 日期可复现构建 |

## 10. 目录结构

```
archs.json                                  架构到 Docker 平台与 CI runner 的映射
build.sh                                    构建单个模板（读取同名 .env 作为默认值）
templates/aarch64/Dagu-KDE.Dockerfile       Debian 13 + Plasma 6.7 镜像定义
templates/aarch64/Dagu-KDE.env              该模板的默认构建参数
scripts/install-desktop.sh                  按发行版安装桌面
scripts/configure-desktop.sh                写桌面配置、装 desktop-session.service
scripts/start-desktop-session.sh            按 DESKTOP:BACKEND 起会话
scripts/desktops/kde.sh                     KDE 的包列表与 unstable 栈安装/校验
scripts/tui/install-mesa.sh                 Mesa-for-Android（kgsl）安装
scripts/systemd257.sh                       systemd 257 兼容检查
scripts/start/desktop-session.service       会话单元模板
scripts/generate_rootfs_json.py             由 Release 资产生成 rootfs.json
docs/debian-plasma67.md                     依赖解析、混装约束与实测记录
rootfs/                                     覆盖进镜像的运行时文件
  etc/systemd/network/10-droidspaces.network
  etc/systemd/system/{ds-nat6,dagu-firstboot,droidspaces-x11-bridge}.service
  etc/systemd/system/droidspaces-x11-watch.path
  etc/docker/daemon.json
  etc/profile.d/90-droidspaces-session.sh
  usr/lib/tmpfiles.d/droidspaces-session.conf
  usr/local/bin/{ds-nat6-up.sh,droidspaces-x11-bridge}
  usr/local/sbin/dagu-firstboot
rootfs.json                                 供 Droidspaces 添加仓库时读取
```

## 11. 许可

MIT。
