# Dagu KDE (Debian 13)：Plasma + Termux:X11 + Mesa/kgsl。
#
# 目标环境是 dagu（Xiaomi / SM8250 / Linux 4.19.157）上的 Droidspaces 容器：
# 没有 msm DRM 节点，只有 /dev/kgsl-3d0，因此硬件渲染走 Mesa 的 kgsl 后端，
# 显示走 Droidspaces 的 --x11（Termux:X11 服务，DISPLAY=:5，socket /tmp/.X11-unix/X5）。
#
# Plasma 版本由 KDE_STACK 决定：
#   trixie   Debian 13 原生 Plasma 6.3.6（KF 6.13 / Qt 6.8.2），可长期维护。
#   unstable Debian 13 底座 + unstable 的 Plasma 6.7.4（KF 6.30 / Qt 6.11.2）。
#            sid 的 Qt 6.11.2 依赖 glibc >= 2.43，trixie 只有 2.41，所以这条路径
#            必然把 libc6 升到 unstable；而 4.19 内核只验证过 systemd 257，
#            systemd/udev/dbus 运行时仍钉在 trixie（见 scripts/desktops/kde.sh）。
FROM debian:trixie AS customizer

#######################################################
ARG DESKTOP=kde
ARG DESKTOP_AUTOSTART=true
ARG DISPLAY_BACKEND=x11
ARG KDE_STACK=trixie
# kwin 的 OpenGL 合成器（X11）：默认关闭，KDE_COMPOSITING=true 时交给 Mesa/kgsl 合成。
ARG KDE_COMPOSITING=false
ARG PulseAudio=socket
ARG ENABLE_zh_tz_ARG=true
ARG ENABLE_zip_ARG=true
ARG ENABLE_docker_ARG=true
ARG ENABLE_mesa_ARG=true
ARG ENABLE_systemd257_ARG=true
ARG ENABLE_binfmt_ARG=true
ARG ENABLE_yj_ARG=false
ARG USERNAME=dagu
ARG KDE_UNSTABLE_BASE=https://deb.debian.org/debian
ARG KDE_UNSTABLE_SNAPSHOT=
######################################################

ENV DEBIAN_FRONTEND=noninteractive

# 启用 APT 并行连接、HTTP(S) pipeline 和下载重试
RUN printf '%s\n' \
    'Acquire::Queue-Mode "host";' \
    'Acquire::http::Pipeline-Depth "10";' \
    'Acquire::https::Pipeline-Depth "10";' \
    'Acquire::Retries "3";' \
    > /etc/apt/apt.conf.d/99parallel-downloads

# 桌面 profile 与构建期脚本；打包前删除一次性脚本。
COPY scripts/install-desktop.sh /usr/local/sbin/install-desktop
COPY scripts/configure-desktop.sh /usr/local/sbin/configure-desktop
COPY scripts/start-desktop-session.sh /usr/local/bin/start-desktop-session
COPY scripts/desktops/ /usr/local/lib/droidspaces/desktops/
COPY scripts/tui/install-mesa.sh /usr/local/sbin/install-mesa
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/start/ /tmp/droidspaces-start/

RUN chmod +x /usr/local/sbin/install-desktop /usr/local/sbin/configure-desktop \
        /usr/local/bin/start-desktop-session /usr/local/sbin/install-mesa \
        /usr/local/sbin/systemd257 \
        /usr/local/lib/droidspaces/desktops/*.sh && \
    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

# 基础运行时：systemd 257 / dbus / ssh / 网络工具，然后由 profile 安装 KDE。
# libllvm19 是 Mesa-for-Android（26.3.0-devel）的硬依赖：缺它 libEGL_mesa 无法
# 加载，GLX/EGL 全部退化，kwin 与 Qt Quick 都起不来。trixie 自带这个版本，
# 由 sid 引入的 libllvm22 不会被卸载。
# 与官方 base 一致：先在 trixie 内升到构建时的最新版，再装包。此时还没有加
# unstable 源，这一步只会更新 trixie/trixie-updates，不会触发跨套件升级。
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget jq locales tzdata \
    systemd-sysv systemd-resolved dbus dbus-user-session udev kmod libpam-systemd \
    sudo openssh-server net-tools iproute2 iputils-ping iptables bind9-dnsutils \
    procps psmisc util-linux file findutils grep sed gawk \
    tar gzip xz-utils unzip zip bash-completion less git nano \
    vim htop lsof pciutils dialog logrotate \
    libllvm19 \
    && /usr/local/sbin/install-desktop "$DESKTOP"

# 可选：压缩工具与 Docker（容器内由 Droidspaces 提供网络与 GPU 节点）。
RUN if [ "$ENABLE_zip_ARG" = "true" ]; then \
        apt-get install -y --no-install-recommends 7zip unzip bzip2; \
    fi

# Docker：trixie 自带的 docker.io 冻结在 26.1.5，官方仓库有 arm64/trixie 的 29.x。
# DOCKER_SOURCE=debian 可退回发行版包；DOCKER_VERSION / CONTAINERD_VERSION 留空装
# 候选版本，指定版本号可钉住（4.19 上若新版 containerd 有问题就钉回 1.7.x）。
ARG DOCKER_SOURCE=ce
ARG DOCKER_CHANNEL=stable
ARG DOCKER_VERSION=
ARG CONTAINERD_VERSION=
RUN if [ "$ENABLE_docker_ARG" = "true" ] && [ "$DOCKER_SOURCE" = "ce" ]; then \
        install -d -m 0755 /etc/apt/keyrings && \
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
        chmod a+r /etc/apt/keyrings/docker.asc && \
        printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: trixie\nComponents: %s\nArchitectures: arm64\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$DOCKER_CHANNEL" \
            > /etc/apt/sources.list.d/docker.sources && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            "docker-ce${DOCKER_VERSION:+=$DOCKER_VERSION}" \
            "docker-ce-cli${DOCKER_VERSION:+=$DOCKER_VERSION}" \
            "containerd.io${CONTAINERD_VERSION:+=$CONTAINERD_VERSION}" \
            docker-buildx-plugin docker-compose-plugin && \
        { update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true; }; \
    elif [ "$ENABLE_docker_ARG" = "true" ]; then \
        apt-get install -y --no-install-recommends docker.io docker-cli docker-buildx docker-compose && \
        { update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true; }; \
    fi

# 记录容器运行时版本，并确保开机自启（官方包不会自己 enable）。
RUN if [ "$ENABLE_docker_ARG" = "true" ]; then \
        systemctl enable docker containerd >/dev/null 2>&1 || true; \
        printf 'docker=%s\ncontainerd=%s\n' \
            "$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || dpkg-query -W -f='${Version}' docker.io 2>/dev/null || echo unknown)" \
            "$(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null || echo none)" \
            >> /etc/droidspaces-kde-stack; \
    fi

# amd64 兼容：binfmt-support 注册 qemu-user-static 的解释器，x86_64 的静态二进制
# 可以直接在容器里跑。动态链接的 amd64 程序另外还需要 libc6:amd64；本镜像的 glibc
# 已经被 KDE 6.7 栈升到 2.43，amd64 侧只能从同版本源取，因此不装。
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        apt-get install -y qemu-user-static binfmt-support; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# 容器内不需要真正的 X 服务器进程，但 X11 客户端工具（xauth/xrdb/xset/xrandr）要在。
RUN if [ "$DISPLAY_BACKEND" = "x11" ]; then \
        apt-get install -y --no-install-recommends x11-xserver-utils x11-utils xauth xkb-data libxcb-cursor0; \
    fi

# 浏览器：只带 Firefox ESR。Chromium 的内容进程在这套 kgsl + Termux:X11 上需要
# 额外压参数才不静音、不全屏回退，维护成本高，不再预装。Firefox 的默认值另写一份
# 到 defaults/pref，让首次启动不去拉 about:welcome（那页要连 mozilla.org）。
# scrot 用于在容器内截取 X 画面。
RUN if [ "$DISPLAY_BACKEND" = "x11" ]; then \
        apt-get install -y --no-install-recommends firefox-esr scrot && \
        install -d -m 0755 /usr/lib/firefox-esr/defaults/pref && \
        printf '%s\n' \
            '// 首启不依赖外网，也不弹默认浏览器询问。' \
            'pref("browser.aboutwelcome.enabled", false);' \
            'pref("browser.startup.homepage", "about:blank");' \
            'pref("browser.newtabpage.enabled", false);' \
            'pref("browser.shell.checkDefaultBrowser", false);' \
            'pref("datareporting.policy.dataSubmissionEnabled", false);' \
            'pref("toolkit.telemetry.enabled", false);' \
            'pref("browser.tabs.inTitlebar", 0);' \
            > /usr/lib/firefox-esr/defaults/pref/droidspaces.js && \
        chmod 0644 /usr/lib/firefox-esr/defaults/pref/droidspaces.js; \
    fi

# Debian 13 自带 systemd 257，即 4.19 上验证过的版本。systemd257.sh 只对
# Ubuntu 26.04 与 Fedora/Arch 提供预构建包族，对已经运行 257 的发行版检测后直接
# 跳过；只有发行版既不是这些目标、systemd 又不是 257 时才会失败。
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 兼容检查"; \
    fi

RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        export DEBIAN_FRONTEND=noninteractive && \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "Asia/Shanghai" > /etc/timezone && \
        dpkg-reconfigure -f noninteractive tzdata && \
        sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen && \
        locale-gen && \
        update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8; \
    else \
        locale-gen && \
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; \
    fi && \
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 创建自定义用户并加入 shadow 组，锁屏验证需要该组
    useradd -m -s /bin/bash -G shadow ${USERNAME} && echo "${USERNAME}:1234" | chpasswd && \
    systemctl enable ssh

# 初始化环境变量文件；桌面专属变量由对应 profile 管理。
RUN : > /etc/environment

# kgsl 是 4.19 厂商内核上唯一的硬件 GL 路径（没有 msm DRM，不能用 zink/msm）。
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        printf '%s\n' \
            '# Mesa kgsl 后端：直接走 /dev/kgsl-3d0（Adreno 6xx）' \
            'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
            'TU_DEBUG=noconform' \
            >> /etc/environment; \
    fi

RUN case "$PulseAudio" in \
        socket|true) echo 'PULSE_SERVER=unix:/tmp/.pulse-socket' >> /etc/environment ;; \
        tcp) echo 'PULSE_SERVER=tcp:127.0.0.1:4713' >> /etc/environment ;; \
    esac

# 桌面会话：写 /etc/droidspaces-desktop.conf、kwinrc，并安装 desktop-session.service。
# 锁屏默认关闭：X11 会话跑在 Termux:X11 上，没有虚拟终端可以切过去执行
# loginctl unlock，锁屏组件一旦失败就只剩一块黑板。
RUN echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "/home/${USERNAME}/.bashrc" && \
    KDE_COMPOSITING="${KDE_COMPOSITING}" /usr/local/sbin/configure-desktop \
        "$DESKTOP" "$DISPLAY_BACKEND" "$DESKTOP_AUTOSTART" "$USERNAME" && \
    install -d -m 0700 -o 1000 -g 1000 "/home/${USERNAME}/.config" && \
    printf '[Daemon]\nAutolock=false\nLockOnStart=false\n' \
        > "/home/${USERNAME}/.config/kscreenlockerrc" && \
    chown -R 1000:1000 "/home/${USERNAME}/.config" && \
    rm -rf /tmp/droidspaces-start

# Mesa 驱动适配：从 droidspaces-package 取 Debian 13(arm64) 的 Mesa 并按发行版持包。
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        /usr/local/sbin/install-mesa --1; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

# 4.19 内核只验证过 systemd 257：断言运行时主版本与 systemd 包族都没有被 unstable 替换。
RUN <<'EOF_SYSTEMD'
set -eu

version_line="$(systemctl --version 2>/dev/null || /usr/lib/systemd/systemd --version)"
major="$(printf '%s\n' "$version_line" | sed -n '1s/^systemd \([0-9][0-9]*\).*/\1/p')"
if [ "$major" != "257" ]; then
    echo "systemd ${major:-unknown} 未在 4.19 内核上验证" >&2
    exit 1
fi

bad=0
for package in systemd systemd-sysv systemd-resolved systemd-timesyncd udev \
               libsystemd0 libsystemd-shared libudev1 libpam-systemd; do
    version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    [ -n "$version" ] || continue
    case "$version" in
        257.*) ;;
        *) echo "$package $version 不在 257 系列" >&2; bad=1 ;;
    esac
done
[ "$bad" = 0 ] || exit 1

printf 'systemd-verified=%s\n' "$(dpkg-query -W -f='${Version}' systemd)" \
    >> /etc/droidspaces-kde-stack
EOF_SYSTEMD

# 应用 Android 运行环境兼容性修复（重点针对 Systemd 和 Udev）
RUN <<'EOF_RUN'
# --- 1. 常规兼容性修复 ---
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,sudo,droidspaces-gpu ${USERNAME} || true

grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
fi

# --- 2. 针对 Systemd 的特定修复 ---
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/lib/systemd/system"

if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" "/etc/systemd/system/multi-user.target.wants/dbus.service"
fi

if [ "$ENABLE_yj_ARG" = "true" ]; then
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done
else
    # systemd-networkd 与 systemd-resolved 必须保留：Droidspaces 的 --net=nat 会在
    # 宿主侧起内建 DHCP 服务器，容器这一侧靠 systemd-networkd 按
    # /etc/systemd/network/10-droidspaces.network 去要地址；把它屏蔽掉 eth0 就永远
    # 没有 IPv4，DNS 也一起失效。udevd 与 NetworkManager 仍然屏蔽。
    for service in systemd-udevd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
    for service in systemd-resolved.service systemd-networkd.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done
fi

# Droidspaces 的 NAT 走宿主的转发路径，链路 MTU 不是 1500。容器 eth0 继承 1500 时，
# 超过路径 MTU 的报文会被静默丢弃，表现出来就是下载或视频加载偶发卡在 0 字节：
# 同一个文件在 1500 下 5 次里 2 次超时，1400 下 5 次全部成功（3.4–7 MB/s）。
# MTU 和 DHCP 写在同一个 .network 里（rootfs 覆盖层的 10-droidspaces.network）：
# networkd 对同一个接口只取第一个匹配的文件，拆开写会让其中一份永远不生效。
# 容器只有 NAT 一条路，IPv6 拿不到默认路由：apt/curl 若先解析出 AAAA 就会连不
# 过去（connect (101: 网络不可达)）再退回 IPv4，白白多等一轮。这里把 IPv4 提到
# 前面，并让 apt 直接只走 IPv4。
sed -i 's|^#precedence ::ffff:0:0/96  100|precedence ::ffff:0:0/96  100|' /etc/gai.conf
grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || \
    printf '\n# 双栈都可用时优先 IPv4\nprecedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
EOF
    fi
done

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-hwaccess-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
    fi
done

if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# 运行时覆盖层：网络、NAT6、首次启动单元。
COPY rootfs/ /

# KDE 用 desktop-session.service 起会话（由 configure-desktop 安装并 enable），
# 这里只启用网络与首次启动相关的单元；Anland 专用单元一并清掉。
RUN chmod +x /usr/local/bin/ds-nat6-up.sh /usr/local/sbin/dagu-firstboot \
        /usr/local/bin/droidspaces-x11-bridge && \
    systemctl enable ds-nat6 dagu-firstboot droidspaces-x11-bridge droidspaces-x11-watch.path

RUN systemctl disable getty@tty1 2>/dev/null || true

RUN rm -f /etc/systemd/system/anland-session.service \
        /usr/local/bin/start-anland-session \
        /etc/systemd/system/multi-user.target.wants/anland-session.service

# 打包前删除仅用于构建的一次性脚本；TUI 和运行时脚本保留。
RUN rm -f \
        /usr/local/sbin/configure-desktop \
        /usr/local/sbin/install-desktop \
        /usr/local/sbin/install-mesa \
        /usr/local/sbin/systemd257 && \
    rm -rf /usr/local/lib/droidspaces/desktops && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

FROM scratch AS export
COPY --from=customizer / /
LABEL droidspaces.name="Dagu KDE (Debian 13)" \
      droidspaces.distro="Debian" \
      droidspaces.description="Debian 13 + KDE Plasma on Termux:X11 with Mesa kgsl" \
      droidspaces.author="Goldzxcbug"
