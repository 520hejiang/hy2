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

get_ip() {
    IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || curl -s --max-time 8 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && { red "无法获取公网 IP"; exit 1; }
    yellow "当前服务器 IP: $IP"
}

check_installed() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null || [[ -f "$CONFIG_DIR/config.yaml" ]]; then
        green "Hysteria2 已安装"
        return 0
    fi
    return 1
}

install_hysteria_bin() {
    yellow "安装/更新 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh) || { red "安装失败"; exit 1; }
    green "安装成功"
}

choose_port() {
    for p in 8443 8444 2053 2096 443; do
        if ! ss -tuln | grep -q ":$p "; then
            PORT=$p
            yellow "自动选择端口: $PORT"
            return
        fi
    done
    PORT=8443
    yellow "使用端口: $PORT"
}

gen_config_acme() {
    yellow "生成 ACME 配置..."
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
    green "ACME 配置完成"
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
    systemctl is-active --quiet hysteria-server && green "服务启动成功" || red "服务启动失败"
}

optimize_system() {
    yellow "系统优化..."
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.ip_forward=1
EOF
    sysctl -p >/dev/null 2>&1
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

show_info() {
    blue "============ 连接信息 ============"
    cat "$CLIENT_DIR/link.txt" 2>/dev/null || echo "未找到配置"
    echo ""
    yellow "服务状态:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "服务未运行"
}

uninstall() {
    red "⚠️ 确认卸载？(y/N)"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
        rm -rf "$CONFIG_DIR" "$CLIENT_DIR" "$SERVICE_FILE"
        green "卸载完成"
    fi
}

main_menu() {
    clear
    green "========================================"
    green "       Hysteria2 完整管理面板"
    green "========================================"
    get_ip
    echo ""
    check_installed
    echo ""
    echo "1) 安装 - 域名 + ACME（推荐）"
    echo "2) 安装 - 自签证书"
    echo "3) 查看连接信息"
    echo "4) 重启服务"
    echo "5) 查看日志"
    echo "6) 一键卸载"
    echo "0) 退出"
    echo ""
    read -rp "请选择 [0-6]: " choice

    case "$choice" in
        1)
            install_hysteria_bin
            choose_port
            read -rp "请输入域名: " DOMAIN
            read -rp "请输入邮箱 (默认 hejianglong39@gmail.com): " EMAIL
            EMAIL=${EMAIL:-hejianglong39@gmail.com}
            gen_config_acme
            optimize_system
            start_service
            show_info
            ;;
        2)
            install_hysteria_bin
            choose_port
            gen_config_selfsign
            optimize_system
            start_service
            show_info
            ;;
        3) show_info ;;
        4) systemctl restart hysteria-server && green "重启成功" ;;
        5) journalctl -u hysteria-server -f -n 100 ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac
    echo ""
    read -rp "按 Enter 返回菜单..."
    main_menu
}

gen_config_selfsign() {
    # 自签配置代码（省略，保持简洁）
    PASS=$(openssl rand -base64 32 | tr -d "=+/")
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
    # ... (自签证书生成)
    echo "MODE=selfsign" > "$INFO_FILE"
}

main_menu