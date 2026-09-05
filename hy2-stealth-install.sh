#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

red()    { echo -e "${RED}$1${PLAIN}"; }
green()  { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }
cyan()   { echo -e "${CYAN}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本" && exit 1

# ==========================================
# 环境准备与依赖
# ==========================================
# 等待 apt/dpkg 锁释放（unattended-upgrades 经常占着锁），带提示+300s上限；
# 返回0=锁空闲可继续，1=超时。fuser 不存在时直接放行。
wait_apt_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        waited=$((waited + 10))
        if [[ $waited -ge 300 ]]; then
            red "等待 apt 锁超时（300s），请稍后手动执行 apt install 后再重试。"
            return 1
        fi
        yellow "检测到 apt 被占用（一般是系统自动更新），等待锁释放... (${waited}s/300s)"
        sleep 10
    done
    return 0
}

install_deps() {    # 先检查关键命令，齐了就跳过 apt（最常见的"卡死"就是 apt 在这里无提示等待）
    local need=(curl openssl iptables ip)
    local missing=()
    local cmd
    for cmd in "${need[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        green "基础依赖已齐全，跳过 apt 安装。"
        return 0
    fi

    yellow "缺失依赖: ${missing[*]}，正在安装 (curl wget lsof socat iptables iproute2 openssl cron gnupg)..."

    # 等待 apt/dpkg 锁释放（unattended-upgrades 经常占着锁），带提示+上限，不再无声卡死
    wait_apt_lock || return 1

    local apt_opts=(-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=2)
    if [[ -f /etc/debian_version ]]; then
        DEBIAN_FRONTEND=noninteractive timeout 300 apt-get update "${apt_opts[@]}" >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y "${apt_opts[@]}" \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            curl wget lsof socat iptables iproute2 openssl cron systemd gnupg 2>&1 | tail -n 3
    elif [[ -f /etc/redhat-release ]]; then
        timeout 600 yum install -y -q curl wget lsof socat iptables iproute2 openssl cronie systemd gnupg2 2>&1 | tail -n 3
    fi

    # 复查：还缺就警告但不退出（多数情况下已有命令可用，避免误杀整个安装）
    missing=()
    for cmd in "${need[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -ne 0 ]]; then
        red "警告：以下依赖仍缺失: ${missing[*]}，后续步骤可能失败，可手动安装后重试。"
        return 1
    fi
    green "依赖安装完成。"
}

get_ip() {
    IP=$(curl -s --max-time 5 -4 https://api.ipify.org 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 -4 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 -4 https://icanhazip.com 2>/dev/null)
    [[ -z "$IP" ]] && red "无法获取公网 IPv4，请检查网络" && exit 1
}

# 只检测 UDP 占用（Hysteria2 只用 UDP；TCP 443 被 openresty 占用是正常的，不能算冲突）
udp_port_in_use() {
    ss -uln 2>/dev/null | grep -qE ":$1([[:space:]]|$)"
}

pick_port() {
    # 每次安装随机一个四位数端口（1000-9999），不固定 443；
    # 端口跳跃段是 20000-40000，四位数天然不重叠
    yellow "正在随机选择监听端口..."
    local try=0
    while true; do
        PORT=$((1000 + RANDOM % 9000))
        if ! udp_port_in_use "$PORT"; then
            break
        fi
        try=$((try + 1))
        if [[ $try -ge 50 ]]; then
            red "尝试 50 次仍未找到空闲 UDP 端口，请手动释放端口后重试。"
            exit 1
        fi
    done
    green "已选择监听端口: $PORT"
}

# ==========================================
# 系统内核优化 (BBR)
# ==========================================
enable_bbr() {
    yellow "正在检测并开启 BBR 拥塞控制算法..."
    local kernel_major=$(uname -r | cut -d. -f1)
    if [ "$kernel_major" -ge 4 ]; then
        if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
            modprobe tcp_bbr 2>/dev/null
        fi
        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
            if ! grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            fi
            green "BBR 已开启并写入持久化配置。"
        else
            green "BBR 已经处于开启状态。"
        fi
    else
        yellow "内核版本低于 4.9，无法开启 BBR。"
    fi
}

# ==========================================
# 证书模块
# 方式1：Acme.sh + Cloudflare DNS API（需域名，完全不碰 80 端口）。
#   说明：已移除"自动启停 80 端口"申请方式。
#   该服务器 80/443 端口由 1Panel 的 openresty 容器占用（管理面板 + 多个静态站点），
#   强行停止/强杀该进程风险很高，且脚本无法自动恢复 Docker 容器，
#   因此只保留完全不碰 80 端口的 DNS API 方式。
# 方式2：自签证书（无需域名，IP 直连，openssl 本地生成，有效期 100 年，无需续期，
#   客户端用 pinSHA256 指纹锁定，兼容新版 V2rayNG / Shadowrocket / NekoBox）。
# ==========================================
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        yellow "正在安装 acme.sh 证书申请工具..."
        curl --connect-timeout 15 --max-time 120 -fsSL https://get.acme.sh | sh >/dev/null 2>&1
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
}

apply_cert_dns() {
    install_acme
    echo ""
    cyan "【Cloudflare API 证书申请】"
    yellow "获取方法: 登录CF -> 右上角我的个人资料 -> API 令牌 -> 创建令牌 -> 使用'编辑区域 DNS'模板"
    # Token 静默输入（不回显），防屏幕偷窥
    read -rsp "请输入 Cloudflare API Token: " CF_Token
    echo ""
    read -rp "请输入 Cloudflare 账户 ID (Account ID): " CF_Account_ID

    export CF_Token="$CF_Token"
    export CF_Account_ID="$CF_Account_ID"

    yellow "正在使用 DNS API 模式申请证书 (通过 API 验证，无需 80 端口)..."
    yellow "这通常需要 1-2 分钟，请耐心等待..."
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force

    if [ $? -ne 0 ]; then
        red "证书申请失败！请检查 API Token 和 账户 ID 是否正确。"
        exit 1
    fi
    install_cert
}

install_cert() {
    # 确保 hysteria 用户存在（证书文件统一存放在 /etc/hysteria）
    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria

    mkdir -p /etc/hysteria

    # 安装证书；acme.sh v3.1.5 不支持 --key-permissions 参数（会导致 Unknown parameter
    # 并在写文件前直接退出），权限靠下面的 chmod/chown 保证，续期后权限修正写在 reloadcmd 里
    if ! ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "chmod 640 /etc/hysteria/server.key; chmod 644 /etc/hysteria/server.crt; chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt; systemctl restart hysteria-server 2>/dev/null; true"; then
        red "证书写入失败，请检查 acme.sh 日志。"
        exit 1
    fi

    # 权限：私钥 640，证书 644
    chmod 640 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt
    chown -R hysteria:hysteria /etc/hysteria/
    chmod 750 /etc/hysteria

    if [[ -f /etc/hysteria/server.crt && -f /etc/hysteria/server.key ]]; then
        green "证书安装成功，权限已修正！"
    else
        red "证书写入失败，请检查 acme.sh 日志。"
        exit 1
    fi
}

gen_cert_selfsign() {
    # 自签证书模式：无需域名，IP 直连；证书 100 年有效，无需续期
    yellow "正在生成自签证书 (EC prime256v1，有效期 100 年)..."

    # 确保 hysteria 用户存在（证书文件统一存放在 /etc/hysteria）
    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria

    mkdir -p /etc/hysteria

    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key 2>/dev/null
    if [[ ! -s /etc/hysteria/server.key ]]; then
        red "私钥生成失败，请检查 openssl 是否可用。"
        exit 1
    fi

    openssl req -new -x509 -days 36500 \
        -key /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" 2>/dev/null
    if [[ ! -s /etc/hysteria/server.crt ]]; then
        red "自签证书生成失败，请检查 openssl 是否可用。"
        exit 1
    fi

    # 计算证书 SHA256 指纹（去冒号，转小写），供客户端 pinSHA256 锁定
    CERT_HASH=$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$CERT_HASH" ]]; then
        red "证书指纹计算失败，请检查 openssl 是否可用。"
        exit 1
    fi
    yellow "证书指纹 (SHA256): $CERT_HASH"

    # 权限：私钥 640，证书 644（与 DNS 模式保持一致）
    chmod 640 /etc/hysteria/server.key
    chmod 644 /etc/hysteria/server.crt
    chown -R hysteria:hysteria /etc/hysteria/
    chmod 750 /etc/hysteria

    green "自签证书生成成功，权限已修正！"
}

# ==========================================
# Hysteria2 安装与防封配置
# ==========================================
install_hy2_core() {
    yellow "正在安装 Hysteria2 内核..."
    bash <(curl --connect-timeout 15 --max-time 180 -fsSL https://get.hy2.sh) || { red "核心安装失败"; exit 1; }
}

generate_config() {
    # 32 字节随机密码（约 43 字符），长期节点更抗爆破
    PASS=$(openssl rand -base64 32 | tr -d "=+/")
    OBFS_PASS=$(openssl rand -base64 16 | tr -d "=+/")

    if [[ "$CERT_MODE" == "selfsign" ]]; then
        # 自签模式：无域名，IP 直连；SNI 用 bing.com，客户端用 pinSHA256 锁定证书；
        # 伪装指向公网 bing（本机无同域名站点可用）
        ADDR="$IP"
        MASQ_URL="https://www.bing.com"
        LINK="hysteria2://${PASS}@${IP}:$PORT/?obfs=salamander&obfs-password=${OBFS_PASS}&mport=20000-40000&pinSHA256=${CERT_HASH}&sni=bing.com#HY2-${IP}"
        TLS_BLOCK="tls:
  sni: bing.com
  pinSHA256: ${CERT_HASH}"
    else
        # DNS 模式：域名连接，正规 CA 证书无需指纹锁定；
        # 伪装指向本机同域名站点（由 openresty 提供），证书/SNI/内容三者一致
        ADDR="$DOMAIN"
        MASQ_URL="https://${DOMAIN}"
        LINK="hysteria2://${PASS}@${DOMAIN}:$PORT/?obfs=salamander&obfs-password=${OBFS_PASS}&mport=20000-40000&sni=${DOMAIN}#HY2-${DOMAIN}"
        TLS_BLOCK="tls:
  sni: ${DOMAIN}"
    fi

    cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASS

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS

# 伪装配置（见上：DNS 模式指向本机同域名站点，自签模式指向公网 bing）
masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

# 服务端强制 BBR：忽略客户端带宽声明，速率曲线平滑、不易被固定高速率特征识别
ignoreClientBandwidth: true

outbounds:
  - name: default
    type: direct
EOF

    mkdir -p /root/hy2
    chmod 700 /root/hy2

    # 记录本次安装的证书模式，供 show_info 展示（老版本无此文件，缺省按 DNS 模式显示）
    echo "$CERT_MODE" > /root/hy2/mode.txt

    echo "$LINK" > /root/hy2/link.txt

    cat > /root/hy2/client.yaml <<EOF
server: ${ADDR}:$PORT
auth: ${PASS}
mport: 20000-40000

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}

${TLS_BLOCK}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:1081
EOF
}

setup_firewall() {
    yellow "正在配置防火墙及端口跳跃 NAT 转发（IPv4，监听端口 $PORT）..."

    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')

    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports $PORT 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:$PORT 2>/dev/null

    iptables -D INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT

    iptables -t nat -A PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:$PORT

    if [[ -f /etc/debian_version ]]; then
        if ! dpkg -l 2>/dev/null | grep -q iptables-persistent; then
            yellow "正在安装 iptables-persistent（持久化防火墙规则）..."
            # 预设 debconf 自动保存规则，否则安装中弹交互框+输出被隐藏=看起来卡死
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null
            if wait_apt_lock; then
                DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y \
                    -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=2 \
                    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                    iptables-persistent >/dev/null 2>&1
            else
                yellow "跳过 iptables-persistent 安装：规则本次已生效，重启后需重新运行脚本。"
            fi
        fi
    fi

    if command -v netfilter-persistent >/dev/null; then
        mkdir -p /etc/iptables
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save >/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        if [ ! -f /etc/iptables/rules.v4 ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
    fi

    green "防火墙规则已配置并持久化（DNAT 模式）。"
}

setup_systemd() {
    yellow "正在加固 systemd 服务配置..."

    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria

    if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
        mkdir -p /etc/systemd/system/hysteria-server.service.d
        cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=5
LimitNOFILE=1048576

# 沙箱加固：即使内核被攻破也锁死在最小权限
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/etc/hysteria
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF
        systemctl daemon-reload
    fi

    green "systemd 服务加固完成。"
}

start_service() {
    systemctl daemon-reload
    systemctl enable hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        green "Hysteria2 启动成功！"
    else
        red "Hysteria2 启动失败，请使用 journalctl -u hysteria-server -n 50 查看日志。"
    fi
}

# ==========================================
# 菜单与展示 (Hysteria2)
# ==========================================
show_info() {
    clear
    green "==================================================="
    green "       Hysteria2 安装配置信息 (企业级防封版)"
    green "==================================================="
    if [[ -f /root/hy2/link.txt ]]; then
        yellow "【一键导入链接】 (v2rayN / v2rayNG / Shadowrocket / NekoBox / Surge)："
        cyan "$(cat /root/hy2/link.txt)"
        echo ""
        yellow "【Clash Meta / NekoBox 客户端 yaml 配置文件路径】："
        cyan "/root/hy2/client.yaml"
        echo ""
        yellow "防封锁特性状态："
        PORT_SHOW=$(grep -oP '(?<=:)[0-9]+(?=/\?)' /root/hy2/link.txt 2>/dev/null | head -1)
        [[ -z "$PORT_SHOW" ]] && PORT_SHOW="443"
        green "✓ 已启用 端口跳跃 (Port Hopping: 20000-40000 转发至 ${PORT_SHOW}, IPv4)"
        if [[ -f /root/hy2/mode.txt && "$(cat /root/hy2/mode.txt)" == "selfsign" ]]; then
            green "✓ 自签证书 (有效期 100 年，无需续期，客户端已用 pinSHA256 锁定)"
        else
            green "✓ 已启用 一致性伪装 (探测流量重定向至本机同域名站点)"
            green "✓ 已启用 证书自动续期 (acme.sh 自动维护, 私钥权限 640)"
        fi
        green "✓ 已启用 Salamander 混淆 (防主动探测与流量特征识别)"
        green "✓ 服务端强制 BBR 模式 (ignoreClientBandwidth, 流量曲线平滑)"
        green "✓ 已启用 systemd 沙箱加固 (最小权限运行)"
    else
        red "未找到配置文件，请确认是否已成功安装。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

uninstall_hy2() {
    read -rp "确定要彻底卸载 Hysteria2 吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop hysteria-server 2>/dev/null
        systemctl disable hysteria-server 2>/dev/null

        # 本次安装使用的端口（老版本无此信息则按 443 清理）
        UPORT=$(grep -oP '(?<=:)[0-9]+(?=/\?)' /root/hy2/link.txt 2>/dev/null | head -1)
        [[ -z "$UPORT" ]] && UPORT=443

        LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
        [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports $UPORT 2>/dev/null
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:$UPORT 2>/dev/null
        iptables -D INPUT -p udp --dport $UPORT -j ACCEPT 2>/dev/null
        iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT 2>/dev/null

        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi

        # 清理 acme.sh 中的域名证书与续期任务（必须在删文件前先读出域名；
        # 自签模式用 IP 直连、无 acme 证书可清；mode.txt 缺失的老版本按是否为 IP 判断）
        if [[ -f /root/hy2/link.txt && -f ~/.acme.sh/acme.sh ]]; then
            OLD_DOMAIN=$(grep -oP '(?<=@)[^:/?#]+(?=:443)' /root/hy2/link.txt | head -1)
            if [[ -n "$OLD_DOMAIN" && ! "$OLD_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                yellow "正在清理 acme.sh 中 $OLD_DOMAIN 的证书与续期任务..."
                ~/.acme.sh/acme.sh --remove -d "$OLD_DOMAIN" --ecc >/dev/null 2>&1
            fi
        fi

        rm -rf /etc/hysteria
        rm -rf /root/hy2
        rm -f /etc/systemd/system/hysteria-server.service
        rm -rf /etc/systemd/system/hysteria-server.service.d
        systemctl daemon-reload

        bash <(curl --connect-timeout 15 --max-time 180 -fsSL https://get.hy2.sh) --remove >/dev/null 2>&1

        # 删除 hysteria 系统用户（服务已停，无残留进程，此时删除安全）
        if id -u hysteria &>/dev/null; then
            userdel hysteria 2>/dev/null && green "hysteria 系统用户已删除。"
        fi

        green "Hysteria2 已彻底卸载并清理残留！"
    fi
    sleep 2
}

install_menu() {
    get_ip
    pick_port
    install_deps
    enable_bbr

    echo ""
    cyan "请选择证书模式："
    echo " 1) Cloudflare DNS API（需域名，完全不占用 80 端口，不影响现有的 openresty/1Panel 站点）"
    echo " 2) 自签证书（无需域名，IP 直连，有效期 100 年，无需续期）"
    echo ""
    read -rp "请输入选项 [1/2]: " CERT_MODE_CHOICE

    case "$CERT_MODE_CHOICE" in
        1)
            CERT_MODE="dns"
            echo ""
            read -rp "请输入你的域名 (如 a.example.com): " DOMAIN
            [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1

            apply_cert_dns
            ;;
        2)
            CERT_MODE="selfsign"
            gen_cert_selfsign
            ;;
        *)
            red "无效选项" && exit 1
            ;;
    esac

    install_hy2_core
    generate_config
    setup_firewall
    setup_systemd
    start_service
    show_info
}

# ==========================================
# 主控循环菜单
# ==========================================
main() {
    while true; do
        clear
        green "==================================================="
        green "   Hysteria2 防封版管理脚本 By AI"
        green "==================================================="
        echo " 1) 安装 Hysteria2 (UDP，端口跳跃 + Salamander 混淆)"
        echo " 2) 查看 Hysteria2 节点信息"
        echo " 3) 重启 Hysteria2 服务"
        echo " 4) 停止 Hysteria2 服务"
        echo " 5) 卸载 Hysteria2"
        echo " 0) 退出脚本"
        green "==================================================="
        read -rp "请输入选项 [0-5]: " menu_choice

        case $menu_choice in
            1) install_menu ;;
            2) show_info ;;
            3) systemctl restart hysteria-server && green "重启成功" && sleep 2 ;;
            4) systemctl stop hysteria-server && yellow "已停止" && sleep 2 ;;
            5) uninstall_hy2 ;;
            0) exit 0 ;;
            *) red "请输入正确的数字!" && sleep 2 ;;
        esac
    done
}

main
