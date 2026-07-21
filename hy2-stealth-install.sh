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
    yellow "正在检查并安装必要依赖 (curl, lsof, socat, iptables, iproute2, openssl, cron)..."
    if [[ -f /etc/debian_version ]]; then
        apt update -y >/dev/null 2>&1
        apt install -y curl wget lsof socat iptables iproute2 openssl cron systemd >/dev/null 2>&1
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget lsof socat iptables iproute2 openssl cronie systemd >/dev/null 2>&1
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
# 80端口占用处理模块 (自动暂停与恢复)
# ==========================================
check_and_stop_80() {
    PORT80_PID=$(lsof -i :80 -t | head -n 1)
    WEB_SERVICE=""
    
    if [ -n "$PORT80_PID" ]; then
        WEB_CMD=$(ps -p $PORT80_PID -o comm= | tr -d '\n')
        yellow "检测到 80 端口正被进程 [$WEB_CMD] (PID: $PORT80_PID) 占用。"
        
        if [[ "$WEB_CMD" == *"nginx"* ]]; then WEB_SERVICE="nginx";
        elif [[ "$WEB_CMD" == *"apache2"* ]] || [[ "$WEB_CMD" == *"httpd"* ]]; then WEB_SERVICE="apache2";
        elif [[ "$WEB_CMD" == *"caddy"* ]]; then WEB_SERVICE="caddy";
        fi

        if [ -n "$WEB_SERVICE" ]; then
            yellow "正在暂时停止 $WEB_SERVICE 以释放 80 端口..."
            systemctl stop $WEB_SERVICE
            sleep 3
        else
            red "80端口被未知程序占用，脚本尝试强杀进程..."
            kill -9 $PORT80_PID
            sleep 3
        fi
    fi
}

resume_80() {
    if [ -n "$WEB_SERVICE" ]; then
        yellow "证书申请完毕，正在恢复 $WEB_SERVICE 服务..."
        systemctl start $WEB_SERVICE
        green "$WEB_SERVICE 已恢复运行，您的网站不受影响。"
    fi
}

# ==========================================
# 证书申请模块 (Acme.sh)
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

apply_cert_standalone() {
    install_acme
    check_and_stop_80
    
    yellow "正在使用 Standalone 模式申请证书，请稍候..."
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
    
    if [ $? -ne 0 ]; then
        resume_80
        red "证书申请失败！请检查域名解析是否正确指向了本机 IP: $IP"
        exit 1
    fi
    resume_80
    install_cert
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
    # 确保 hysteria 用户存在
    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria
    
    mkdir -p /etc/hysteria
    
    # 安装证书并设置自动续期钩子
    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt \
        --reloadcmd "systemctl restart hysteria-server" >/dev/null 2>&1
    
    # 修复权限：私钥 640（仅 root/hysteria 可读），证书 644
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
    
    # 写入 Hysteria2 配置文件 (服务端必须只监听 443)
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
    
    # 写入分享链接，其中 mport=20000-40000 告诉客户端使用端口跳跃，并携带 obfs 参数
    echo "hysteria2://${PASS}@${DOMAIN}:443/?obfs=salamander&obfs-password=${OBFS_PASS}&mport=20000-40000&sni=${DOMAIN}#HY2-${DOMAIN}" > /root/hy2/link.txt

    # 生成一个给 Clash Meta / NekoBox 用的标准 yaml 参考
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
    
    # 获取本机主 IP（内网 IP，用于 DNAT 目标）
    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    # 清理旧规则（防止重复添加，包括旧版错误的 REDIRECT）
    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443 2>/dev/null
    
    iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT 2>/dev/null
    
    # 放行 443 和 20000-40000
    iptables -I INPUT -p udp --dport 443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -I INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT
    
    # 核心修复：PREROUTING 链必须使用 DNAT，不能用 REDIRECT
    # REDIRECT 在 PREROUTING 会将目标 IP 改为 127.0.0.1，导致入站 UDP 路由异常、连接追踪失效
    iptables -t nat -A PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443

    # 持久化规则（适配 Debian/Ubuntu / RHEL / CentOS）
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
    
    # 确保 hysteria 用户存在
    id -u hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria
    
    # 添加 drop-in 覆盖：自动重启、文件描述符限制
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
# 菜单与展示
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
        
        # 清理 NAT 规则
        LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\d+\.\d+\.\d+\.\d+' | head -1)
        [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(hostname -I | awk '{print $1}')
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination ${LOCAL_IP}:443 2>/dev/null
        iptables -D INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null
        iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT 2>/dev/null
        
        # 保存清理后的规则
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
    cyan "请选择申请域名证书的方式："
    echo " 1) 自动启停 80 端口申请 (推荐，需要域名 A 记录已指向服务器 IP: $IP)"
    echo " 2) Cloudflare DNS API 申请 (完全不占用 80 端口，需 CF 令牌)"
    read -rp "请选择 [1-2]: " cert_choice
    
    read -rp "请输入你的域名 (如 a.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1
    
    if [ "$cert_choice" == "1" ]; then
        apply_cert_standalone
    elif [ "$cert_choice" == "2" ]; then
        apply_cert_dns
    else
        red "输入错误" && sleep 1 && return
    fi
    
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
        green "    Hysteria2 企业级防封版 一键管理脚本 By AI"
        green "==================================================="
        echo " 1) 一键安装 Hysteria2 (含证书申请与防封配置)"
        echo " 2) 查看 节点分享链接 与 配置信息"
        echo " 3) 重启 Hysteria2 服务"
        echo " 4) 停止 Hysteria2 服务"
        echo " 5) 彻底卸载 Hysteria2"
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
