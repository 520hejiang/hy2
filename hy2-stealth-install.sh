#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

red()    { echo -e "${RED}$1${PLAIN}"; }
green()  { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }
blue()   { echo -e "${BLUE}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "请使用 root 权限运行！" && exit 1

CONFIG_DIR="/etc/hysteria"
CLIENT_DIR="/root/hy2"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
INFO_FILE="/root/hy2/install.info"

# ==================== 基础函数 ====================

get_ip() {
    IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || curl -s --max-time 8 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && { red "无法获取公网 IP，请检查网络"; exit 1; }
    yellow "当前服务器 IP: $IP"
}

check_installed() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null || [[ -f "$CONFIG_DIR/config.yaml" ]]; then
        green "检测到 Hysteria2 已安装"
        return 0
    fi
    return 1
}

install_dependency() {
    local pkg=$1
    if ! command -v $pkg >/dev/null 2>&1; then
        yellow "正在安装依赖: $pkg"
        if command -v apt >/dev/null; then
            apt update -qq && apt install -y $pkg
        elif command -v yum >/dev/null; then
            yum install -y $pkg epel-release 2>/dev/null || true
        elif command -v dnf >/dev/null; then
            dnf install -y $pkg
        else
            yellow "无法自动安装 $pkg，请手动安装"
        fi
    fi
}

check_dependencies() {
    install_dependency curl
    install_dependency openssl
    install_dependency qrencode   # 可选，失败不影响主功能
}

install_hysteria_bin() {
    yellow "安装/更新 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh) || { red "安装失败"; exit 1; }
    green "Hysteria2 安装成功"
}

# ==================== 配置生成（保持不变，省略部分以节省篇幅） ====================

gen_config_acme() {
    PASS=$(openssl rand -base64 32 | tr -d "=+/")
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
listen: :$PORT

acme:
  domains:
    - $DOMAIN
  email: $EMAIL

auth:
  type: password
  password: $PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 67108864
EOF

    echo "hysteria2://$PASS@$DOMAIN:$PORT/?sni=$DOMAIN#HY2-$DOMAIN" > "$CLIENT_DIR/link.txt"
    cat > "$CLIENT_DIR/client.yaml" <<EOF
server: $DOMAIN:$PORT
auth: $PASS

tls:
  sni: $DOMAIN

socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:1081
EOF

    echo "MODE=acme" > "$INFO_FILE"
    echo "DOMAIN=$DOMAIN" >> "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
}

gen_config_selfsign() {
    PASS=$(openssl rand -base64 32 | tr -d "=+/")
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"

    openssl ecparam -genkey -name prime256v1 -out "$CONFIG_DIR/server.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$CONFIG_DIR/server.key" -out "$CONFIG_DIR/server.crt" -subj "/CN=www.bing.com" 2>/dev/null

    CERT_HASH=$(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')

    cat > "$CONFIG_DIR/config.yaml" <<EOF
listen: :$PORT

tls:
  cert: $CONFIG_DIR/server.crt
  key: $CONFIG_DIR/server.key

auth:
  type: password
  password: $PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 67108864
EOF

    echo "hysteria2://$PASS@$IP:$PORT/?pinSHA256=$CERT_HASH&sni=www.bing.com#HY2-SelfSign" > "$CLIENT_DIR/link.txt"
    cat > "$CLIENT_DIR/client.yaml" <<EOF
server: $IP:$PORT
auth: $PASS

tls:
  sni: www.bing.com
  pinSHA256: $CERT_HASH

socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:1081
EOF

    echo "MODE=selfsign" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    yellow "证书指纹: $CERT_HASH"
}

start_service() {
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    sleep 2
    systemctl is-active --quiet hysteria-server && green "服务启动成功 ✅" || red "服务启动失败"
}

optimize_system() {
    yellow "应用系统优化..."
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl -p >/dev/null 2>&1

    iptables -I INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null || true
}

show_info() {
    echo ""
    blue "============= 连接信息 ============="
    if [[ -f "$CLIENT_DIR/link.txt" ]]; then
        cat "$CLIENT_DIR/link.txt"
        echo ""
        if command -v qrencode >/dev/null; then
            yellow "二维码："
            qrencode -t ANSIUTF8 < "$CLIENT_DIR/link.txt"
        else
            yellow "提示：安装 qrencode 可显示二维码 (apt install qrencode)"
        fi
    fi
}

uninstall() {
    red "⚠️ 即将彻底卸载"
    read -rp "确认输入 y: " confirm
    [[ "$confirm" != "y" ]] && return
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
    rm -rf "$CONFIG_DIR" "$CLIENT_DIR" "$SERVICE_FILE"
    green "卸载完成"
}

set_port() {
    read -rp "请输入监听端口 (默认 443): " PORT
    PORT=${PORT:-443}
}

# ==================== 主菜单 ====================

main_menu() {
    clear
    green "========================================"
    green "       Hysteria2 管理面板 (增强版)"
    green "========================================"
    get_ip
    echo ""
    check_installed && blue "状态: 已安装" || blue "状态: 未安装"
    echo ""
    echo "1) 全新安装 - 域名 + ACME（推荐）"
    echo "2) 全新安装 - 自签证书"
    echo "3) 查看连接信息 / 二维码"
    echo "4) 重启服务"
    echo "5) 查看实时日志"
    echo "6) 一键卸载"
    echo "0) 退出"
    echo ""
    read -rp "请输入选项: " choice

    case "$choice" in
        1|2)
            check_dependencies
            install_hysteria_bin
            set_port
            if [[ "$choice" == "1" ]]; then
                read -rp "请输入域名: " DOMAIN
                read -rp "请输入 ACME 邮箱: " EMAIL
                gen_config_acme
            else
                gen_config_selfsign
            fi
            optimize_system
            start_service
            show_info
            ;;
        3) show_info ;;
        4) systemctl restart hysteria-server && green "服务已重启" ;;
        5) journalctl -u hysteria-server -f ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac

    echo ""
    read -rp "按 Enter 返回主菜单..." 
    main_menu
}

main_menu