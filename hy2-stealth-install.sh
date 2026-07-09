#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red()    { echo -e "${RED}$1${PLAIN}"; }
green()  { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "请使用 root 运行" && exit 1

# ────────────────────────────────────────────
# 获取公网 IP
# ────────────────────────────────────────────
get_ip() {
  IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
  [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
  [[ -z "$IP" ]] && red "无法获取公网 IP，请检查网络" && exit 1
  yellow "服务器 IP: $IP"
}

# ────────────────────────────────────────────
# 安装 Hysteria2
# ────────────────────────────────────────────
install_hysteria() {
  yellow "安装 Hysteria2..."
  bash <(curl -fsSL https://get.hy2.sh) || { red "安装失败"; exit 1; }
  green "安装成功"
}

# ────────────────────────────────────────────
# 随机可用端口
# ────────────────────────────────────────────
set_port() {
  PORT=443
  yellow "监听端口: $PORT"
}

# ────────────────────────────────────────────
# 模式A：域名 + ACME 自动证书
# ────────────────────────────────────────────
gen_config_acme() {
  PASS=$(openssl rand -base64 16 | tr -d "=+/")
  mkdir -p /etc/hysteria

  cat > /etc/hysteria/config.yaml <<EOF
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
    url: https://bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

  mkdir -p /root/hy2
  # ACME 证书是正规证书，不需要 insecure 也不需要指纹
  echo "hysteria2://$PASS@$DOMAIN:$PORT/?sni=$DOMAIN#HY2-$DOMAIN" > /root/hy2/link.txt

  cat > /root/hy2/client.yaml <<EOF
server: $DOMAIN:$PORT
auth: $PASS

tls:
  sni: $DOMAIN

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:1081
EOF
}

# ────────────────────────────────────────────
# 模式B：自签证书 + pinnedPeerCertSha256
# ────────────────────────────────────────────
gen_config_selfsign() {
  PASS=$(openssl rand -base64 16 | tr -d "=+/")
  mkdir -p /etc/hysteria

  # 生成自签证书
  openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key 2>/dev/null
  openssl req -new -x509 -days 36500 \
    -key /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" 2>/dev/null

  # 计算证书 SHA256 指纹（去掉冒号，转小写）
  CERT_HASH=$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 \
    | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
  yellow "证书指纹 (SHA256): $CERT_HASH"

  cat > /etc/hysteria/config.yaml <<EOF
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

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

  mkdir -p /root/hy2
  # 用 pinSHA256 替代已废弃的 insecure=1，新版 V2rayNG/Xray 兼容
  echo "hysteria2://$PASS@$IP:$PORT/?pinSHA256=$CERT_HASH&sni=bing.com#HY2-SelfSign" > /root/hy2/link.txt

  cat > /root/hy2/client.yaml <<EOF
server: $IP:$PORT
auth: $PASS

tls:
  sni: bing.com
  pinSHA256: $CERT_HASH

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:1081
EOF
}

# ────────────────────────────────────────────
# systemd 服务
# ────────────────────────────────────────────
start_service() {
  cat > /etc/systemd/system/hysteria-server.service <<EOF
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
  systemctl enable hysteria-server >/dev/null 2>&1
  systemctl restart hysteria-server

  sleep 2
  if systemctl is-active --quiet hysteria-server; then
    green "服务启动成功"
  else
    red "服务启动失败，查看日志:"
    journalctl -u hysteria-server -n 20 --no-pager
    exit 1
  fi
}

# ────────────────────────────────────────────
# 系统优化
# ────────────────────────────────────────────
optimize() {
  local SYSCTL=/etc/sysctl.conf

  add_sysctl() {
    grep -q "^$1" "$SYSCTL" || echo "$1" >> "$SYSCTL"
  }

  add_sysctl "net.ipv4.ip_forward=1"
  add_sysctl "net.ipv6.conf.all.forwarding=1"
  add_sysctl "net.core.default_qdisc=fq"
  add_sysctl "net.ipv4.tcp_congestion_control=bbr"
  add_sysctl "net.core.rmem_max=33554432"
  add_sysctl "net.core.wmem_max=33554432"

  sysctl -p >/dev/null 2>&1

  # 防火墙放行
  iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
  iptables -C FORWARD -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD -j ACCEPT
}

# ────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────
main() {
  clear
  green "========================================"
  green "       Hysteria2 安装脚本"
  green "========================================"
  echo ""

  get_ip
  echo ""

  # 选择证书模式
  echo "请选择证书模式:"
  echo "  1) 域名 + ACME 自动证书（推荐，无需 insecure）"
  echo "  2) 自签证书（兼容新版 V2rayNG，使用指纹锁定）"
  echo ""
  read -rp "请输入选项 [1/2]: " CERT_MODE

  case "$CERT_MODE" in
    1)
      echo ""
      read -rp "请输入你的域名 (例: vpn.example.com): " DOMAIN
      [[ -z "$DOMAIN" ]] && red "域名不能为空" && exit 1

      read -rp "请输入 ACME 邮箱 (用于证书申请通知): " EMAIL
      [[ -z "$EMAIL" ]] && red "邮箱不能为空" && exit 1

      yellow "请确保域名 $DOMAIN 的 A 记录已解析到 $IP"
      read -rp "确认已解析？[y/N]: " CONFIRM
      [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && red "请先完成 DNS 解析后再运行" && exit 1

      install_hysteria
      set_port
      gen_config_acme
      ;;
    2)
      install_hysteria
      set_port
      gen_config_selfsign
      ;;
    *)
      red "无效选项" && exit 1
      ;;
  esac

  optimize
  start_service

  echo ""
  green "========================================"
  green "           安装完成！"
  green "========================================"
  echo ""

  if [[ "$CERT_MODE" == "1" ]]; then
    echo "域名  : $DOMAIN"
  else
    echo "IP    : $IP"
  fi
  echo "端口  : $PORT"
  echo "密码  : $PASS"
  echo ""
  yellow "连接链接 (直接导入客户端):"
  cat /root/hy2/link.txt
  echo ""
  echo "客户端配置: /root/hy2/client.yaml"
  echo "服务管理  : systemctl restart hysteria-server"
  echo ""
  if [[ "$CERT_MODE" == "2" ]]; then
    yellow "提示: 使用 pinSHA256 指纹锁定，兼容新版 V2rayNG / Shadowrocket / NekoBox"
  fi
}

main
