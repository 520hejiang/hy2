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

install_acme() {
    yellow "检查并安装 acme.sh 及其依赖..."
    apt-get update -y || yum update -y
    apt-get install -y socat cron curl || yum install -y socat cronie curl
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        curl https://get.acme.sh | sh -s email="$EMAIL"
        source ~/.bashrc
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
}

# 模式 1：Webroot 自动申请证书
gen_config_acme() {
    yellow "配置 ACME Webroot 自动续订模式..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
    
    install_acme

    DEFAULT_WEBROOT="/www/sites/$DOMAIN"
    echo ""
    blue "利用现有的 Web 服务申请证书，网站零停机。"
    read -rp "请输入网站根目录路径 (回车默认使用 $DEFAULT_WEBROOT): " WEBROOT
    WEBROOT=${WEBROOT:-$DEFAULT_WEBROOT}

    yellow "正在向 Let's Encrypt 申请证书..."
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot "$WEBROOT" \
        --force || { red "证书申请失败！请检查域名解析和网站根目录是否匹配"; exit 1; }

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CONFIG_DIR/server.key" \
        --fullchain-file "$CONFIG_DIR/server.crt" \
        --reloadcmd "systemctl restart hysteria-server"

    build_hy2_config
}

# 模式 2：手动填入现有证书路径或内容
gen_config_manual_cert() {
    yellow "配置自定义证书..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"

    read -rp "请输入你的域名: " DOMAIN
    read -rp "请输入证书 (.crt/pem) 文件绝对路径: " CRT_PATH
    read -rp "请输入私钥 (.key) 文件绝对路径: " KEY_PATH

    if [[ ! -f "$CRT_PATH" || ! -f "$KEY_PATH" ]]; then
        red "未找到指定的证书或私钥文件，请检查路径！"
        exit 1
    fi

    cp "$CRT_PATH" "$CONFIG_DIR/server.crt"
    cp "$KEY_PATH" "$CONFIG_DIR/server.key"

    build_hy2_config
}

# 生成 Hysteria2 统一配置文件
build_hy2_config() {
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

    echo "MODE=tls" > "$INFO_FILE"
    echo "DOMAIN=$DOMAIN" >> "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    green "Hysteria2 配置完毕！"
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
        green "服务启动成功"
    else 
        red "服务启动失败，请使用 journalctl -u hysteria-server -n 50 查看日志"
    fi
}

optimize_system() {
    yellow "开启 BBR & UDP 优化..."
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
    blue "============ 连接信息 ============"
    cat "$CLIENT_DIR/link.txt" 2>/dev/null || echo "未找到配置"
    echo ""
    yellow "服务状态:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "服务未运行"
}

uninstall() {
    red "⚠️ 确认卸载？(y/N)"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
        systemctl disable --now hysteria-server 2>/dev/null
        rm -rf "$CONFIG_DIR" "$CLIENT_DIR" "$SERVICE_FILE" /etc/sysctl.d/99-hysteria.conf
        sysctl --system >/dev/null 2>&1
        ~/.acme.sh/acme.sh --remove -d "$(grep DOMAIN "$INFO_FILE" 2>/dev/null | cut -d= -f2)" 2>/dev/null || true
        green "卸载完成"
    fi
}

main_menu() {
    clear
    green "========================================"
    green "    Hysteria2 管理面板 (兼容建站环境)   "
    green "========================================"
    get_ip
    echo ""
    check_installed
    echo ""
    echo "1) 安装 - 自动 ACME 证书 (推荐: 无感全自动续订)"
    echo "2) 安装 - 手动指定已有证书路径 (.crt / .key)"
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
            read -rp "请输入节点域名 (需已解析到本服务器IP): " DOMAIN
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
            gen_config_manual_cert
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

main_menu
