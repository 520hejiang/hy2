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
    # 避开 80 和 443 端口，防止与 OpenResty 冲突
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

# 模式 1：Webroot 网站零停机申请证书
gen_config_acme() {
    yellow "配置 ACME Webroot 模式..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
    
    install_acme

    DEFAULT_WEBROOT="/www/sites/$DOMAIN"
    echo ""
    blue "利用现有的 Web 服务申请证书，网站零停机。"
    read -rp "请输入网站根目录绝对路径 (直接回车默认使用 $DEFAULT_WEBROOT): " WEBROOT
    WEBROOT=${WEBROOT:-$DEFAULT_WEBROOT}

    yellow "正在向 Let's Encrypt 申请证书..."
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot "$WEBROOT" \
        --force || { red "证书申请失败！请检查域名解析和根目录是否正确。"; exit 1; }

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CONFIG_DIR/server.key" \
        --fullchain-file "$CONFIG_DIR/server.crt" \
        --reloadcmd "systemctl restart hysteria-server"

    chmod 644 "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"
    PASS=$(openssl rand -base64 16 | tr -d "=+/")

    write_config_yaml

    # ACME 证书是正规的，不需要指纹
    echo "hysteria2://$PASS@$DOMAIN:$PORT/?sni=$DOMAIN#HY2-$DOMAIN" > "$CLIENT_DIR/link.txt"
    write_client_yaml "$DOMAIN" ""

    echo "MODE=tls" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    green "证书配置完成！"
}

# 模式 2：融合了旧代码优势的自签证书模式 (pinSHA256)
gen_config_selfsign() {
    yellow "生成融合版自签证书 (带有 pinSHA256 指纹锁定)..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"

    read -rp "请输入节点伪装 SNI 域名 (直接回车默认用 bing.com): " SNI_DOMAIN
    SNI_DOMAIN=${SNI_DOMAIN:-bing.com}

    # 使用旧代码的 EC 算法生成证书，兼容性极佳
    openssl ecparam -genkey -name prime256v1 -out "$CONFIG_DIR/server.key" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "$CONFIG_DIR/server.key" \
        -out "$CONFIG_DIR/server.crt" \
        -subj "/CN=$SNI_DOMAIN" 2>/dev/null

    # 计算旧代码里的证书 SHA256 指纹
    CERT_HASH=$(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -fingerprint -sha256 \
        | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
    
    yellow "提取到的证书指纹 (SHA256): $CERT_HASH"
    chmod 644 "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"
    PASS=$(openssl rand -base64 16 | tr -d "=+/")

    write_config_yaml

    # 使用指纹替代 insecure
    echo "hysteria2://$PASS@$IP:$PORT/?pinSHA256=$CERT_HASH&sni=$SNI_DOMAIN#HY2-SelfSign" > "$CLIENT_DIR/link.txt"
    write_client_yaml "$IP" "$CERT_HASH"

    echo "MODE=selfsigned" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    green "指纹自签证书配置完成！"
}

# 提取出的公共写入配置函数 (融入了旧代码的 quic 性能优化)
write_config_yaml() {
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
    url: https://bing.com
    rewriteHost: true

# 引入旧代码的底层网络优化参数
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF
}

write_client_yaml() {
    local SRV=$1
    local HASH=$2

    cat > "$CLIENT_DIR/client.yaml" <<EOF
server: $SRV:$PORT
auth: $PASS
tls:
  sni: bing.com
EOF

    if [[ -n "$HASH" ]]; then
        echo "  pinSHA256: $HASH" >> "$CLIENT_DIR/client.yaml"
    fi

    cat >> "$CLIENT_DIR/client.yaml" <<EOF
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:1081
EOF
}

start_service() {
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then 
        green "服务启动成功"
    else 
        red "服务启动失败，查看日志:"
        journalctl -u hysteria-server -n 10 --no-pager
    fi
}

optimize_system() {
    yellow "写入系统网络规则及防火墙放行..."
    # 结合了旧代码的转发开启
    cat > /etc/sysctl.d/99-hysteria.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
EOF
    sysctl --system >/dev/null 2>&1
    
    iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
    iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD -j ACCEPT
    firewall-cmd --add-port="${PORT}/udp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null
    ufw allow "${PORT}/udp" 2>/dev/null
}

show_info() {
    blue "============ 节点连接信息 ============"
    cat "$CLIENT_DIR/link.txt" 2>/dev/null || echo "未找到配置"
    echo "======================================"
    yellow "服务状态:"
    systemctl status hysteria-server --no-pager -l 2>/dev/null | grep -E "Active:|Server up" || echo "服务未运行"
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
        green "卸载完成！"
    fi
}

main_menu() {
    clear
    green "========================================"
    green "   Hysteria2 完美融合版面板 (无冲突)    "
    green "========================================"
    get_ip
    echo ""
    check_installed
    echo ""
    echo "1) 安装 - ACME 自动证书 (Webroot 网站无缝版)"
    echo "2) 安装 - 自签证书 (指纹锁定 pinSHA256 防报错版)"
    echo "3) 查看连接信息"
    echo "4) 重启服务"
    echo "5) 查看运行日志"
    echo "6) 一键卸载"
    echo "0) 退出"
    echo ""
    read -rp "请选择 [0-6]: " choice

    case "$choice" in
        1)
            install_hysteria_bin
            choose_port
            read -rp "请输入节点域名 (需已解析到本机): " DOMAIN
            read -rp "请输入邮箱 (默认 admin@$DOMAIN): " EMAIL
            EMAIL=${EMAIL:-admin@$DOMAIN}
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
    read -rp "按 Enter 返回主菜单..."
    main_menu
}

main_menu
