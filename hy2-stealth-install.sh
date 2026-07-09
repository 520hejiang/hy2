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
    for p in 8443 8444 2053 2096; do
        if ! ss -tuln | grep -q ":$p "; then
            PORT=$p
            yellow "自动选择节点端口: $PORT"
            return
        fi
    done
    PORT=8443
    yellow "使用端口: $PORT"
}

gen_config_self_signed() {
    yellow "生成 10 年期自签证书 (不依赖 80/443 端口，彻底解决 404)..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
    
    read -rp "请输入节点伪装 SNI 域名 (直接回车默认用 www.bing.com): " SNI_DOMAIN
    SNI_DOMAIN=${SNI_DOMAIN:-www.bing.com}

    # 使用 OpenSSL 本地一键生成 10 年证书
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CONFIG_DIR/server.key" \
        -out "$CONFIG_DIR/server.crt" \
        -subj "/CN=$SNI_DOMAIN" >/dev/null 2>&1

    chmod 644 "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"

    PASS=$(openssl rand -base64 32 | tr -d "=+/")

    cat > "$CONFIG_DIR/config.yaml" <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASS

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true
EOF

    # 生成带 insecure=1 参数的导入链接
    echo "hysteria2://$PASS@$IP:$PORT/?insecure=1&sni=$SNI_DOMAIN#HY2-SelfSigned" > "$CLIENT_DIR/link.txt"

    cat > "$CLIENT_DIR/client.yaml" <<EOF
server: $IP:$PORT
auth: $PASS
tls:
  sni: $SNI_DOMAIN
  insecure: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:1081
EOF

    echo "MODE=selfsigned" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    green "自签证书及节点配置成功完成！"
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
    if systemctl is-active --quiet hysteria-server; then 
        green "服务启动成功！"
    else 
        red "服务启动失败，请运行 journalctl -u hysteria-server -n 50 查看具体原因"
    fi
}

optimize_system() {
    yellow "开启 BBR & UDP 系统网络优化..."
    cat > /etc/sysctl.d/99-hysteria.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.ip_forward=1
EOF
    sysctl --system >/dev/null 2>&1
    
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    firewall-cmd --add-port="${PORT}/udp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null
    ufw allow "${PORT}/udp" 2>/dev/null
}

show_info() {
    blue "============ 节点连接信息 ============"
    cat "$CLIENT_DIR/link.txt" 2>/dev/null || echo "未找到配置"
    echo ""
    yellow "⚠️ 提示：因为使用的是自签证书，客户端（如小火箭/v2rayN）导入后请确认已开启【允许不安全/跳过证书验证 (insecure)】选项！"
    echo ""
    yellow "当前服务运行状态:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "服务未运行"
}

uninstall() {
    red "⚠️ 确认彻底卸载 Hysteria2？(y/N)"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
        systemctl disable --now hysteria-server 2>/dev/null
        rm -rf "$CONFIG_DIR" "$CLIENT_DIR" "$SERVICE_FILE" /etc/sysctl.d/99-hysteria.conf
        sysctl --system >/dev/null 2>&1
        green "卸载完成！"
    fi
}

main_menu() {
    clear
    green "========================================"
    green "   Hysteria2 面板 (自签证书·零折腾版)   "
    green "========================================"
    get_ip
    echo ""
    check_installed
    echo ""
    echo "1) 安装 - 自签证书模式 (最推荐：无需域名/零报错/不影响网站)"
    echo "2) 查看连接信息"
    echo "3) 重启服务"
    echo "4) 查看运行日志"
    echo "5) 一键卸载"
    echo "0) 退出"
    echo ""
    read -rp "请选择 [0-5]: " choice

    case "$choice" in
        1)
            install_hysteria_bin
            choose_port
            gen_config_self_signed
            optimize_system
            start_service
            show_info
            ;;
        2) show_info ;;
        3) systemctl restart hysteria-server && green "重启成功" ;;
        4) journalctl -u hysteria-server -f -n 100 ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac
    echo ""
    read -rp "按 Enter 返回主菜单..."
    main_menu
}

main_menu
