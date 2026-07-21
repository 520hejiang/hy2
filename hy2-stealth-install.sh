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
# 伪装成普通系统服务名，降低特征
SERVICE_NAME="system-network-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INFO_FILE="/root/hy2/install.info"

# 供 choose_port 使用的自定义端口（全局）
CUSTOM_PORT=""
CUSTOM_MASQ=""

# 记录被暂停的 Web 服务
WEB_SERVICES_STOPPED=""

get_ip() {
    IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || curl -s --max-time 8 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && { red "无法获取公网 IP"; exit 1; }
    yellow "当前服务器 IP: $IP"
}

check_installed() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || [[ -f "$CONFIG_DIR/config.yaml" ]]; then
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
    if [[ -n "$CUSTOM_PORT" ]]; then
        PORT="$CUSTOM_PORT"
        yellow "使用自定义端口: $PORT"
        if ss -tuln | grep -q ":$PORT "; then
            red "端口 $PORT 已被占用！"
            exit 1
        fi
        return
    fi
    # 随机选择高端口，提高隐蔽性
    while true; do
        PORT=$((10000 + RANDOM % 50000))
        if ! ss -tuln | grep -q ":$PORT "; then
            break
        fi
    done
    yellow "随机选择节点端口: $PORT"
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

get_masquerade_site() {
    local defaults=("bing.com" "cloudflare.com" "mozilla.org" "github.com" "wikipedia.org")
    if [[ -n "$CUSTOM_MASQ" ]]; then
        MASQ_URL="$CUSTOM_MASQ"
    else
        MASQ_URL="${defaults[$RANDOM % ${#defaults[@]}]}"
    fi
    yellow "伪装反代站点: $MASQ_URL"
}

# 暂停占用80端口的 Web 服务
stop_web_servers_if_needed() {
    WEB_SERVICES_STOPPED=""
    for srv in nginx apache2 httpd; do
        if systemctl is-active --quiet "$srv" 2>/dev/null; then
            systemctl stop "$srv" && WEB_SERVICES_STOPPED="$WEB_SERVICES_STOPPED $srv"
        fi
    done
    if [ -n "$WEB_SERVICES_STOPPED" ]; then
        blue "已暂停: ${WEB_SERVICES_STOPPED# }"
    fi
}

# 恢复之前暂停的 Web 服务
start_web_servers_if_needed() {
    if [ -n "$WEB_SERVICES_STOPPED" ]; then
        for srv in $WEB_SERVICES_STOPPED; do
            systemctl start "$srv" >/dev/null 2>&1
        done
        blue "已恢复: ${WEB_SERVICES_STOPPED# }"
        WEB_SERVICES_STOPPED=""
    fi
}

# 模式 1：Standalone 模式 (暂停80端口)
gen_config_acme() {
    yellow "配置 ACME Standalone 模式..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
    
    install_acme

    echo ""
    blue "将临时暂停占用80端口的 Web 服务，以完成 HTTP 验证。"
    
    # 暂停可能占用80端口的服务
    stop_web_servers_if_needed

    yellow "正在向 Let's Encrypt 申请证书..."
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force || {
        red "证书申请失败！请检查域名解析和80端口是否可用。"
        # 恢复 Web 服务后退出
        start_web_servers_if_needed
        exit 1
    }

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CONFIG_DIR/server.key" \
        --fullchain-file "$CONFIG_DIR/server.crt" \
        --reloadcmd "systemctl restart $SERVICE_NAME"

    # 恢复 Web 服务
    start_web_servers_if_needed

    chmod 644 "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"
    PASS=$(openssl rand -base64 16 | tr -d "=+/")

    # 伪装站点
    get_masquerade_site

    write_config_yaml

    # ACME 证书 sni 必须为真实域名，否则证书不匹配
    CLIENT_SNI="$DOMAIN"
    echo "hysteria2://$PASS@$DOMAIN:$PORT/?sni=$DOMAIN#HY2-$DOMAIN" > "$CLIENT_DIR/link.txt"
    write_client_yaml "$DOMAIN" ""

    echo "MODE=tls" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    echo "SERVICE_NAME=$SERVICE_NAME" >> "$INFO_FILE"
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

    # 自签模式下伪装站点与 SNI 一致，避免特征差异
    MASQ_URL="$SNI_DOMAIN"

    write_config_yaml

    CLIENT_SNI="$SNI_DOMAIN"
    # 使用指纹替代 insecure
    echo "hysteria2://$PASS@$IP:$PORT/?pinSHA256=$CERT_HASH&sni=$SNI_DOMAIN#HY2-SelfSign" > "$CLIENT_DIR/link.txt"
    write_client_yaml "$IP" "$CERT_HASH"

    echo "MODE=selfsigned" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    echo "SERVICE_NAME=$SERVICE_NAME" >> "$INFO_FILE"
    green "指纹自签证书配置完成！"
}

# 模式 3：ACME DNS 验证 (Cloudflare) 增加重试机制
gen_config_acme_cf() {
    yellow "配置 ACME DNS (Cloudflare) 模式..."
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"

    install_acme

    echo ""
    blue "使用 Cloudflare DNS API 验证域名所有权。请确保域名已解析到本机且 Cloudflare 未开启橙色云代理。"
    export CF_Email="$CF_EMAIL"
    export CF_Key="$CF_KEY"

    yellow "正在通过 Cloudflare DNS 验证申请证书..."
    MAX_RETRY=3
    local success=0
    for i in $(seq 1 $MAX_RETRY); do
        if ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force; then
            green "证书申请成功 (尝试次数: $i)"
            success=1
            break
        else
            yellow "第 ${i} 次尝试失败..."
            if [ $i -lt $MAX_RETRY ]; then
                yellow "等待 15 秒后重试..."
                sleep 15
            fi
        fi
    done

    if [ $success -ne 1 ]; then
        red "证书申请失败！请检查 Cloudflare 凭据和域名解析是否正确。"
        exit 1
    fi

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CONFIG_DIR/server.key" \
        --fullchain-file "$CONFIG_DIR/server.crt" \
        --reloadcmd "systemctl restart $SERVICE_NAME"

    chmod 644 "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"
    PASS=$(openssl rand -base64 16 | tr -d "=+/")

    get_masquerade_site

    write_config_yaml

    CLIENT_SNI="$DOMAIN"
    echo "hysteria2://$PASS@$DOMAIN:$PORT/?sni=$DOMAIN#HY2-CFDNS" > "$CLIENT_DIR/link.txt"
    write_client_yaml "$DOMAIN" ""

    echo "MODE=tls_cf" > "$INFO_FILE"
    echo "PORT=$PORT" >> "$INFO_FILE"
    echo "SERVICE_NAME=$SERVICE_NAME" >> "$INFO_FILE"
    echo "DOMAIN=$DOMAIN" >> "$INFO_FILE"
    green "Cloudflare DNS 证书配置完成！"
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
    url: https://${MASQ_URL}
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
  sni: ${CLIENT_SNI:-bing.com}
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
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=System Network Monitor Service
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
    systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then 
        green "服务启动成功"
    else 
        red "服务启动失败，查看日志:"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
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
net.ipv4.icmp_echo_ignore_all=1
net.ipv4.tcp_fastopen=3
fs.file-max=1048576
EOF
    sysctl --system >/dev/null 2>&1

    modprobe xt_connlimit 2>/dev/null || true
    
    # 单 IP 并发连接数上限，防止扫描/暴力探测
    iptables -C INPUT -p udp --dport "$PORT" -m connlimit --connlimit-above 100 -j DROP 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$PORT" -m connlimit --connlimit-above 100 -j DROP
    iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
    iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD -j ACCEPT
    firewall-cmd --add-port="${PORT}/udp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null
    ufw allow "${PORT}/udp" 2>/dev/null
}

show_info() {
    blue "============ 节点连接信息 ============"
    cat "$CLIENT_DIR/link.txt" 2>/dev/null || echo "未找到配置"
    echo "======================================"
    yellow "服务状态:"
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | grep -E "Active:|Server up" || echo "服务未运行"
}

uninstall() {
    red "⚠️ 确认卸载？(y/N)"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
        if [[ -f "$INFO_FILE" ]]; then
            local srv_name=$(grep "^SERVICE_NAME=" "$INFO_FILE" | cut -d= -f2)
            [[ -n "$srv_name" ]] && systemctl disable --now "$srv_name" 2>/dev/null
        fi
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null
        rm -rf "$CONFIG_DIR" "$CLIENT_DIR" "$SERVICE_FILE" /etc/sysctl.d/99-hysteria.conf
        sysctl --system >/dev/null 2>&1
        local domain_to_remove=$(grep DOMAIN "$INFO_FILE" 2>/dev/null | cut -d= -f2)
        [[ -n "$domain_to_remove" ]] && ~/.acme.sh/acme.sh --remove -d "$domain_to_remove" 2>/dev/null || true
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
    echo "1) 安装 - ACME 自动证书 (Standalone 模式，临时暂停80端口)"
    echo "2) 安装 - 自签证书 (指纹锁定 pinSHA256 防报错版)"
    echo "3) 安装 - ACME DNS 验证 (Cloudflare) [增强重试]"
    echo "4) 查看连接信息"
    echo "5) 重启服务"
    echo "6) 查看运行日志"
    echo "7) 一键卸载"
    echo "0) 退出"
    echo ""
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1)
            install_hysteria_bin
            read -rp "请输入希望使用的端口 (直接回车随机生成 10000-60000): " user_port
            CUSTOM_PORT="$user_port"
            choose_port
            read -rp "请输入节点域名 (需已解析到本机): " DOMAIN
            read -rp "请输入邮箱 (默认 admin@$DOMAIN): " EMAIL
            EMAIL=${EMAIL:-admin@$DOMAIN}
            read -rp "请输入伪装反代网站域名 (直接回车随机选择知名站点): " CUSTOM_MASQ
            gen_config_acme
            optimize_system
            start_service
            show_info
            ;;
        2)
            install_hysteria_bin
            read -rp "请输入希望使用的端口 (直接回车随机生成 10000-60000): " user_port
            CUSTOM_PORT="$user_port"
            choose_port
            gen_config_selfsign
            optimize_system
            start_service
            show_info
            ;;
        3)
            install_hysteria_bin
            read -rp "请输入希望使用的端口 (直接回车随机生成 10000-60000): " user_port
            CUSTOM_PORT="$user_port"
            choose_port
            read -rp "请输入节点域名 (需已解析到本机): " DOMAIN
            read -rp "请输入邮箱 (默认 admin@$DOMAIN): " EMAIL
            EMAIL=${EMAIL:-admin@$DOMAIN}
            read -rp "请输入 Cloudflare 账户邮箱: " CF_EMAIL
            read -rsp "请输入 Cloudflare Global API Key (输入不会显示): " CF_KEY
            echo
            read -rp "请输入伪装反代网站域名 (直接回车随机选择知名站点): " CUSTOM_MASQ
            gen_config_acme_cf
            optimize_system
            start_service
            show_info
            ;;
        4) show_info ;;
        5) systemctl restart "$SERVICE_NAME" && green "重启成功" ;;
        6) journalctl -u "$SERVICE_NAME" -f -n 100 ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac
    echo ""
    read -rp "按 Enter 返回主菜单..."
    main_menu
}

main_menu
