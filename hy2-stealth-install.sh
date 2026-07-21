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
    yellow "正在检查并安装必要依赖 (curl, lsof, socat, iptables, cron)..."
    if [[ -f /etc/debian_version ]]; then
        apt update -y >/dev/null 2>&1
        apt install -y curl wget lsof socat iptables cron systemd >/dev/null 2>&1
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y curl wget lsof socat iptables cronie systemd >/dev/null 2>&1
    fi
}

get_ip() {
    IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && red "无法获取公网 IP，请检查网络" && exit 1
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
    # 强制使用 Let's Encrypt 避免 ZeroSSL 各种注册报错
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
    mkdir -p /etc/hysteria
    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
        --key-file /etc/hysteria/server.key \
        --fullchain-file /etc/hysteria/server.crt
    
    if [[ -f /etc/hysteria/server.crt && -f /etc/hysteria/server.key ]]; then
        green "证书安装成功！"
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
    
    # 写入 Hysteria2 配置文件 (服务端必须只监听 443)
    cat > /etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASS

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

outbounds:
  - name: default
    type: direct
EOF

    mkdir -p /root/hy2
    # 写入分享链接，其中 mport=20000-40000 告诉客户端使用端口跳跃
    echo "hysteria2://$PASS@$DOMAIN:443/?mport=20000-40000&sni=$DOMAIN#HY2-$DOMAIN" > /root/hy2/link.txt

    # 生成一个给 Clash Meta / NekoBox 用的标准 yaml 参考
    cat > /root/hy2/client.yaml <<EOF
server: $DOMAIN:443
auth: $PASS
mport: 20000-40000

tls:
  sni: $DOMAIN

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:1081
EOF
}

setup_port_hopping() {
    yellow "正在配置 IPTables 防火墙及端口跳跃 NAT 转发..."
    
    # 清理旧规则（防止重复添加）
    iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
    
    # 放行 443 和 20000-40000 的端口
    iptables -I INPUT -p udp --dport 443 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -I INPUT -p udp -m multiport --dports 20000:40000 -j ACCEPT
    
    # 核心：将 20000-40000 的 UDP 流量重定向到本机的 443 端口
    iptables -t nat -A PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443

    # 尝试保存规则（适配大部分系统）
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v service >/dev/null; then
        service iptables save >/dev/null 2>&1
    fi
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
    green "       Hysteria2 安装配置信息 (高级防封版)"
    green "==================================================="
    if [[ -f /root/hy2/link.txt ]]; then
        yellow "【一键导入链接】 (适用于 v2rayN / v2rayNG / Shadowrocket / Surge 等)："
        cyan "$(cat /root/hy2/link.txt)"
        echo ""
        yellow "【Clash Meta / NekoBox 客户端 yaml 配置文件路径】："
        cyan "/root/hy2/client.yaml"
        echo ""
        yellow "防封锁特性状态："
        green "✓ 已启用 端口跳跃 (Port Hopping: 20000-40000 转发至 443)"
        green "✓ 已启用 深度伪装 (探测流量自动重定向至 Bing)"
    else
        red "未找到配置文件，请确认是否已成功安装。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

uninstall_hy2() {
    read -rp "确定要彻底卸载 Hysteria2 吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop hysteria-server
        systemctl disable hysteria-server
        rm -rf /etc/hysteria
        rm -rf /root/hy2
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
        
        # 移除 NAT 规则
        iptables -t nat -D PREROUTING -p udp --dport 20000:40000 -j REDIRECT --to-ports 443 2>/dev/null
        
        bash <(curl -fsSL https://get.hy2.sh) --remove >/dev/null 2>&1
        green "Hysteria2 已彻底卸载并清理残留！"
    fi
    sleep 2
}

install_menu() {
    get_ip
    install_deps
    
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
    setup_port_hopping
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
        green "    Hysteria2 高级防封版 一键管理脚本 By AI"
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