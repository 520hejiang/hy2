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
install_deps() {
    yellow "正在检查并安装必要依赖 (curl, lsof, socat, iptables, iproute2, openssl, cron, gnupg)..."
    if [[ -f /etc/debian_version ]]; then
        apt update -y >/dev/null 2>&1
        apt install -y curl wget lsof socat iptables iproute2 openssl cron systemd gnupg >/dev/null 2>&1
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget lsof socat iptables iproute2 openssl cronie systemd gnupg2 >/dev/null 2>&1
    fi
}

get_ip() {
    IP=$(curl -s --max-time 5 -4 https://api.ipify.org 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 -4 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 -4 https://icanhazip.com 2>/dev/null)
    [[ -z "$IP" ]] && red "无法获取公网 IPv4，请检查网络" && exit 1
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
# 证书申请模块 (Acme.sh) —— 仅保留 DNS API 方式
# 说明：已移除"自动启停 80 端口"申请方式。
# 该服务器 80/443 端口由 1Panel 的 openresty 容器占用（管理面板 + 多个静态站点），
# 强行停止/强杀该进程风险很高，且脚本无法自动恢复 Docker 容器，
# 因此只保留完全不碰 80 端口的 DNS API 方式。
# ==========================================
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        yellow "正在安装 acme.sh 证书申请工具..."
        curl https://get.acme.sh | sh >/dev/null 2>&1
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    ~/.acme.sh/acme.sh --register-account -m "admin@${DOMAIN}" --server letsencrypt >/dev/null 2>&1
}

apply_cert_dns() {
    install_acme
    echo ""
    cyan "【Cloudflare API 证书申请】"
    yellow "获取方法: 登录CF -> 右上角我的个人资料 -> API 令牌 -> 创建令牌 -> 使用'编辑区域 DNS'模板"
    read -rp "请输入 Cloudflare API Token: " CF_Token
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
    # 确保 hysteria 用户存在（证书文件统一存放在 /etc/hysteria，AnyTLS 也复用这一份）
    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria

    mkdir -p /etc/hysteria

    # 安装证书，续期时同时重启 Hysteria2 和 AnyTLS(sing-box)，谁没装就静默跳过
    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "systemctl restart hysteria-server 2>/dev/null; systemctl restart sing-box 2>/dev/null; true" >/dev/null 2>&1

    # 权限：私钥 640，证书 644；sing-box 以 root 运行可直接读取
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

# ==========================================
# Hysteria2 安装与防封配置
# ==========================================
install_hy2_core() {
    yellow "正在安装 Hysteria2 内核..."
    bash <(curl -fsSL https://get.hy2.sh) || { red "核心安装失败"; exit 1; }
}

generate_config() {
    PASS=$(openssl rand -base64 16 | tr -d "=+/")
    OBFS_PASS=$(openssl rand -base64 12 | tr -d "=+/")

    cat > /etc/hysteria/config.yaml <<EOF
listen: :443

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

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

bandwidth:
  up: 1 gbps
  down: 1 gbps

outbounds:
  - name: default
    type: direct
EOF

    mkdir -p /root/hy2
    chmod 700 /root/hy2

    echo "hysteria2://${PASS}@${DOMAIN}:443/?obfs=salamander&obfs-password=${OBFS_PASS}&mport=20000-40000&sni=${DOMAIN}#HY2-${DOMAIN}" > /root/hy2/link.txt

    cat > /root/hy2/client.yaml <<EOF
server: ${DOMAIN}:443
auth: ${PASS}
mport: 20000-40000

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}

tls:
  sni: ${DOMAIN}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:1081
EOF
}

setup_firewall() {
    yellow "正在配置防火墙及端口跳跃 NAT 转发（安全加固版）..."

    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')

    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443 2>/dev/null

    iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT 2>/dev/null

    iptables -I INPUT -p udp --dport 443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -I INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT

    iptables -t nat -A PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443

    if [[ -f /etc/debian_version ]]; then
        if ! dpkg -l | grep -q iptables-persistent; then
            apt install -y iptables-persistent >/dev/null 2>&1
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
# AnyTLS 安装与配置 (基于 sing-box 内核)
# 说明：复用 Hysteria2 申请的同一张真实证书，走标准 TLS 模式
# （未使用 AnyTLS+REALITY 的实验性组合，因为那个模式目前客户端支持面更窄，
#  小火箭是否兼容还不确定，稳定性优先）
# ==========================================
install_singbox_core() {
    yellow "正在安装 sing-box 内核 (AnyTLS 依赖)..."
    if command -v sing-box >/dev/null 2>&1; then
        yellow "sing-box 已安装，跳过安装步骤。"
        return
    fi

    if [[ -f /etc/debian_version ]]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
        chmod a+r /etc/apt/keyrings/sagernet.asc
        cat > /etc/apt/sources.list.d/sagernet.sources <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
        apt-get update -y >/dev/null 2>&1
        apt-get install -y sing-box >/dev/null 2>&1
    else
        yellow "非 Debian/Ubuntu 系统，使用二进制方式安装..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) SB_ARCH="amd64" ;;
            aarch64) SB_ARCH="arm64" ;;
            *) red "暂不支持的架构: $ARCH"; exit 1 ;;
        esac
        SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | head -1 | sed -E 's/.*"v([0-9.]+)".*/\1/')
        curl -fsSL -o /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
        tar -xzf /tmp/sing-box.tar.gz -C /tmp
        install -m 755 /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box

        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    if ! command -v sing-box >/dev/null 2>&1; then
        red "sing-box 安装失败，请检查网络。"
        exit 1
    fi
    green "sing-box 内核安装成功。"
}

generate_anytls_config() {
    ANYTLS_PASS=$(openssl rand -base64 18 | tr -d "=+/")

    if lsof -iTCP:443 -sTCP:LISTEN -t >/dev/null 2>&1; then
        yellow "检测到 TCP 443 端口已被占用（大概率是你的 openresty/1Panel）。"
        read -rp "请为 AnyTLS 指定一个未占用的 TCP 端口 (直接回车使用默认 8443): " ANYTLS_PORT
        [[ -z "$ANYTLS_PORT" ]] && ANYTLS_PORT=8443
    else
        ANYTLS_PORT=443
    fi

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        { "name": "user", "password": "${ANYTLS_PASS}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "/etc/hysteria/server.crt",
        "key_path": "/etc/hysteria/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

    mkdir -p /root/anytls
    chmod 700 /root/anytls

    echo "anytls://${ANYTLS_PASS}@${DOMAIN}:${ANYTLS_PORT}?sni=${DOMAIN}&insecure=0#AnyTLS-${DOMAIN}" > /root/anytls/link.txt
    echo "${ANYTLS_PORT}" > /root/anytls/port.txt

    cat > /root/anytls/client.json <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${DOMAIN}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASS}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}"
  }
}
EOF
}

setup_firewall_anytls() {
    yellow "正在为 AnyTLS 放行端口 ${ANYTLS_PORT}/tcp..."
    iptables -D INPUT -p tcp --dport ${ANYTLS_PORT} -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport ${ANYTLS_PORT} -j ACCEPT

    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save >/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ ! -f /etc/iptables/rules.v4 ] && iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
    green "端口 ${ANYTLS_PORT}/tcp 已放行并持久化。"
}

start_anytls_service() {
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        green "AnyTLS (sing-box) 启动成功！"
    else
        red "启动失败，请用 journalctl -u sing-box -n 50 查看日志。"
    fi
}

install_anytls_menu() {
    install_deps
    get_ip

    if [[ -f /etc/hysteria/server.crt && -f /etc/hysteria/server.key ]]; then
        yellow "检测到已有证书（来自 Hysteria2 安装），AnyTLS 将复用这张证书。"
        read -rp "请输入证书对应的域名 (需和 Hysteria2 一致): " DOMAIN
        [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1
    else
        yellow "未检测到已有证书，需先申请一张（同样走 Cloudflare DNS API，不碰 80 端口）。"
        read -rp "请输入你的域名 (如 a.example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1
        apply_cert_dns
    fi

    install_singbox_core
    generate_anytls_config
    setup_firewall_anytls
    start_anytls_service
    show_anytls_info
}

show_anytls_info() {
    clear
    green "==================================================="
    green "         AnyTLS 安装配置信息（防封更强版）"
    green "==================================================="
    if [[ -f /root/anytls/link.txt ]]; then
        yellow "【一键导入链接】(NekoBox / sing-box 内核客户端 / 小火箭)："
        cyan "$(cat /root/anytls/link.txt)"
        echo ""
        yellow "【sing-box outbound JSON】(链接导入失败时，手动填这里的参数)："
        cyan "/root/anytls/client.json"
        echo ""
        yellow "提醒："
        echo " - AnyTLS 是较新协议，各客户端的分享链接解析还没完全统一。"
        echo " - 小火箭较新版本已支持 AnyTLS 协议类型，若导入链接失败，改用手动填参数。"
        echo " - 证书复用的是 Hysteria2 那张真实证书，续期时两个服务会一起自动重启。"
    else
        red "未找到配置文件，请确认是否已成功安装。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

uninstall_anytls() {
    read -rp "确定要彻底卸载 AnyTLS (sing-box) 吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null

        if [[ -f /root/anytls/port.txt ]]; then
            AP=$(cat /root/anytls/port.txt)
            iptables -D INPUT -p tcp --dport ${AP} -j ACCEPT 2>/dev/null
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            fi
        fi

        rm -rf /etc/sing-box
        rm -rf /root/anytls

        if [[ -f /etc/debian_version ]] && dpkg -l sing-box >/dev/null 2>&1; then
            apt-get remove -y sing-box >/dev/null 2>&1
        else
            rm -f /usr/local/bin/sing-box
            rm -f /etc/systemd/system/sing-box.service
        fi
        systemctl daemon-reload

        green "AnyTLS 已彻底卸载并清理残留！"
    fi
    sleep 2
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
        green "✓ 已启用 端口跳跃 (Port Hopping: 20000-40000 转发至 443)"
        green "✓ 已启用 深度伪装 (探测流量自动重定向至 Bing)"
        green "✓ 已启用 Salamander 混淆 (防主动探测与流量特征识别)"
        green "✓ 已启用 BBR 加速 (TCP 拥塞控制优化)"
        green "✓ 已启用 证书自动续期 (acme.sh 自动维护)"
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

        LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
        [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443 2>/dev/null
        iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null
        iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT 2>/dev/null

        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi

        rm -rf /etc/hysteria
        rm -rf /root/hy2
        rm -f /etc/systemd/system/hysteria-server.service
        rm -rf /etc/systemd/system/hysteria-server.service.d
        systemctl daemon-reload

        bash <(curl -fsSL https://get.hy2.sh) --remove >/dev/null 2>&1
        green "Hysteria2 已彻底卸载并清理残留！"
    fi
    sleep 2
}

install_menu() {
    get_ip
    install_deps
    enable_bbr

    echo ""
    cyan "证书申请方式：Cloudflare DNS API（完全不占用 80 端口，不影响你现有的 openresty/1Panel 站点）"
    read -rp "请输入你的域名 (如 a.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1

    apply_cert_dns

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
        green "   Hysteria2 + AnyTLS 双协议防封版管理脚本 By AI"
        green "==================================================="
        echo " 1) 安装 Hysteria2 (UDP，端口跳跃 + Salamander 混淆)"
        echo " 2) 安装 AnyTLS   (TCP，抗主动探测能力更强)"
        echo " 3) 查看 Hysteria2 节点信息"
        echo " 4) 查看 AnyTLS 节点信息"
        echo " 5) 重启 Hysteria2 服务"
        echo " 6) 重启 AnyTLS 服务"
        echo " 7) 停止 Hysteria2 服务"
        echo " 8) 停止 AnyTLS 服务"
        echo " 9) 卸载 Hysteria2"
        echo "10) 卸载 AnyTLS"
        echo " 0) 退出脚本"
        green "==================================================="
        read -rp "请输入选项 [0-10]: " menu_choice

        case $menu_choice in
            1) install_menu ;;
            2) install_anytls_menu ;;
            3) show_info ;;
            4) show_anytls_info ;;
            5) systemctl restart hysteria-server && green "重启成功" && sleep 2 ;;
            6) systemctl restart sing-box && green "重启成功" && sleep 2 ;;
            7) systemctl stop hysteria-server && yellow "已停止" && sleep 2 ;;
            8) systemctl stop sing-box && yellow "已停止" && sleep 2 ;;
            9) uninstall_hy2 ;;
            10) uninstall_anytls ;;
            0) exit 0 ;;
            *) red "请输入正确的数字!" && sleep 2 ;;
        esac
    done
}

main
