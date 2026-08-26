#!/bin/bash
# ==========================================
# Tor 私有 obfs4 桥接 一键部署脚本（自用备用逃生通道）
#   - 使用 Tor 官方软件源（deb.torproject.org），随官方持续更新
#   - 私有桥接：不上报 Tor 桥接数据库，仅自己使用
#   - obfs4 流量混淆 + 随机高位端口，抗 DPI 与主动扫描
#   - 不做公共中继/出口，不消耗多余流量，符合 Hetzner ToS
# ==========================================

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; PLAIN="\033[0m"
red()    { echo -e "${RED}$1${PLAIN}"; }
green()  { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }
cyan()   { echo -e "${CYAN}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本" && exit 1

TORRC=/etc/tor/torrc
BRIDGE_INFO=/root/tor-bridge-info.txt

get_ip() {
    IP=$(curl -s --max-time 5 -4 https://api.ipify.org 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 -4 https://ifconfig.me 2>/dev/null)
    [[ -z "$IP" ]] && red "无法获取公网 IPv4，请检查网络" && exit 1
}

port_used() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

rand_free_port() {
    local base=$1 p
    while :; do
        p=$(( base + RANDOM % 9000 ))
        if ! port_used "$p" && [[ "$p" != "$2" ]]; then echo "$p"; return; fi
    done
}

install_deps() {
    yellow "正在安装依赖并添加 Tor 官方软件源..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y >/dev/null 2>&1
    apt install -y curl gnupg lsb-release ca-certificates >/dev/null 2>&1

    install -d /usr/share/keyrings /etc/apt/sources.list.d
    CODENAME=$(lsb_release -cs 2>/dev/null)
    case "$CODENAME" in
        focal|jammy|noble|bullseye|bookworm|trixie|sid) : ;;
        *) CODENAME=bookworm; yellow "当前发行版代号未被 Tor 官方源收录，回退使用 bookworm 源。" ;;
    esac
    curl -fsSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
        | gpg --dearmor > /usr/share/keyrings/tor-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org ${CODENAME} main" > /etc/apt/sources.list.d/tor-official.list

    apt update -y >/dev/null 2>&1
    apt install -y tor obfs4proxy deb.torproject.org-keyring iptables-persistent >/dev/null 2>&1 \
        || { red "Tor 安装失败，请检查软件源与系统版本"; exit 1; }
    green "Tor $(tor --version | awk '{print $3}') 及 obfs4 安装完成。"
}

write_config() {
    yellow "正在生成私有桥接配置..."
    get_ip
    mkdir -p /root
    [[ -f $TORRC ]] && cp $TORRC "${TORRC}.bak.$(date +%s)"

    # 重复安装时先移除上一轮端口的放行规则，避免 iptables 规则堆积
    OLD_ORPORT=$(grep -oP '(?<=^ORPort )\d+' $TORRC 2>/dev/null)
    OLD_OBFS4_PORT=$(grep -oP "(?<=obfs4 0\.0\.0\.0:)\d+" $TORRC 2>/dev/null)
    [[ -n "$OLD_ORPORT" ]] && iptables -D INPUT -p tcp --dport "$OLD_ORPORT" -j ACCEPT 2>/dev/null
    [[ -n "$OLD_OBFS4_PORT" ]] && iptables -D INPUT -p tcp --dport "$OLD_OBFS4_PORT" -j ACCEPT 2>/dev/null
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1

    ORPORT=$(rand_free_port 10000 "")
    OBFS4_PORT=$(rand_free_port 40000 "$ORPORT")
    NICK="pv$(( RANDOM % 90000 + 10000 ))"

    cat > $TORRC <<EOF
# ===== Tor 私有 obfs4 桥接（由脚本生成）=====
User debian-tor
Nickname ${NICK}
ContactInfo none

# 私有桥接核心两行：开启桥接但不公开上报
BridgeRelay 1
PublishServerDescriptor 0

ORPort ${ORPORT}
ExtORPort auto

ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:${OBFS4_PORT}

ExitPolicy reject *:*
SocksPort 0
Log notice syslog
EOF

    # Ubuntu 上 tor 的 AppArmor 配置可能阻止读取 obfs4 状态文件，按需解除限制
    if [[ -f /etc/apparmor.d/system_tor ]]; then
        ln -sf /etc/apparmor.d/system_tor /etc/apparmor.d/disable/system_tor 2>/dev/null
        apparmor_parser -R /etc/apparmor.d/system_tor 2>/dev/null
    fi

    systemctl restart tor

    yellow "等待 Tor 启动并生成桥接凭据（约 10-60 秒）..."
    local waited=0
    while (( waited < 90 )); do
        grep -q "^obfs4" /var/lib/tor/pt_state/obfs4_bridgeline.txt 2>/dev/null && break
        sleep 3; waited=$((waited+3))
    done

    if ! grep -q "^obfs4" /var/lib/tor/pt_state/obfs4_bridgeline.txt 2>/dev/null; then
        red "凭据未生成，请执行 journalctl -u tor -n 50 排查"
        exit 1
    fi

    open_firewall
    save_info
    green "桥接部署完成！"
}

open_firewall() {
    iptables -D INPUT -p tcp --dport "$ORPORT" -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport "$OBFS4_PORT" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport "$ORPORT" -j ACCEPT
    iptables -I INPUT -p tcp --dport "$OBFS4_PORT" -j ACCEPT
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save >/dev/null; then
        mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
}

close_firewall() {
    iptables -D INPUT -p tcp --dport "$ORPORT" -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport "$OBFS4_PORT" -j ACCEPT 2>/dev/null
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1
}

save_info() {
    # 强制 iat-mode=1：启用包间延迟抖动，对抗长期时序分析（牺牲延迟换强度）
    CERT_LINE=$(grep "^obfs4" /var/lib/tor/pt_state/obfs4_bridgeline.txt | head -1 \
        | sed "s|<IP ADDRESS>:<PORT>|${IP}:${OBFS4_PORT}|; s|iat-mode=[0-9]|iat-mode=1|")
    cat > $BRIDGE_INFO <<EOF
===== Tor 私有桥接信息 =====
桥接线路（已启用 iat-mode=1 时序混淆）：
${CERT_LINE}

ORPort:     ${IP}:${ORPORT}
obfs4 端口: ${IP}:${OBFS4_PORT}
昵称:       ${NICK}
配置文件:   ${TORRC}
EOF
    chmod 600 $BRIDGE_INFO
}

show_info() {
    clear
    green "==================================================="
    green "       Tor 私有桥接信息"
    green "==================================================="
    if [[ -f $BRIDGE_INFO ]] && grep -q "^obfs4" $BRIDGE_INFO; then
        cyan "$(cat $BRIDGE_INFO)"
        echo ""
        yellow "【客户端导入方法】"
        cyan "1. 打开 Tor Browser -> 菜单 -> 设置 -> 连接"
        cyan "2. 选择『添加桥接-手动输入』，把上面 obfs4 开头整行粘进去"
        cyan "3. 保存并连接即可（iat-mode=1 已开启时序混淆，速度慢属正常）"
    else
        red "未找到桥接信息，请先安装（选项 1）。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

renew_ports() {
    if [[ ! -f $TORRC ]]; then red "尚未安装桥接"; sleep 2; return; fi
    yellow "正在更换身份（重新生成密钥与桥接线）..."
    rm -rf /var/lib/tor/pt_state
    systemctl restart tor
    sleep 5
    get_ip
    ORPORT=$(grep -oP '(?<=^ORPort )\d+' $TORRC)
    OBFS4_PORT=$(grep -oP "(?<=obfs4 0\.0\.0\.0:)\d+" $TORRC)
    NICK=$(grep -oP '(?<=^Nickname ).+' $TORRC)
    local waited=0
    while (( waited < 90 )); do
        grep -q "^obfs4" /var/lib/tor/pt_state/obfs4_bridgeline.txt 2>/dev/null && break
        sleep 3; waited=$((waited+3))
    done
    save_info
    green "已更换完成，新桥接线见选项 2。"
}

uninstall_bridge() {
    read -rp "确定要卸载 Tor 桥接吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then sleep 1; return; fi
    ORPORT=$(grep -oP '(?<=^ORPort )\d+' $TORRC 2>/dev/null)
    OBFS4_PORT=$(grep -oP "(?<=obfs4 0\.0\.0\.0:)\d+" $TORRC 2>/dev/null)
    [[ -n "$ORPORT" ]] && close_firewall
    systemctl stop tor 2>/dev/null
    systemctl disable tor 2>/dev/null
    apt purge -y tor obfs4proxy deb.torproject.org-keyring >/dev/null 2>&1
    rm -rf /var/lib/tor /var/log/tor /etc/tor "$BRIDGE_INFO" /etc/apt/sources.list.d/tor-official.list
    rm -f /usr/share/keyrings/tor-archive-keyring.gpg /etc/apparmor.d/disable/system_tor
    green "Tor 桥接已彻底卸载。"
    sleep 2
}

main() {
    while true; do
        clear
        green "==================================================="
        green "   Tor 私有桥接管理脚本 (obfs4)"
        green "==================================================="
        echo " 1) 部署桥接"
        echo " 2) 查看桥接信息与客户端用法"
        echo " 3) 重启 Tor 服务"
        echo " 4) 更换端口/身份（重新生成桥接线）"
        echo " 5) 彻底卸载"
        echo " 0) 退出"
        green "==================================================="
        read -rp "请输入选项 [0-5]: " choice
        case $choice in
            1) install_deps && write_config && sleep 2 ;;
            2) show_info ;;
            3) systemctl restart tor && green "已重启" && sleep 2 ;;
            4) renew_ports && sleep 2 ;;
            5) uninstall_bridge ;;
            0) exit 0 ;;
            *) red "无效输入!" && sleep 1 ;;
        esac
    done
}

main
