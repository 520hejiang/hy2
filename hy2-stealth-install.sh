#!/usr/bin/env bash
set -euo pipefail

# ========== 用户需要准备的参数 ==========
# 使用方法: bash hy2-stealth-install.sh <域名>
# 示例: bash hy2-stealth-install.sh my.example.com

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    echo "错误: 请提供域名作为参数，例如: bash $0 my.example.com"
    exit 1
fi

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本 (sudo)"
    exit 1
fi

# 基础依赖
echo ">>> 安装基础依赖..."
apt-get update -qq
apt-get install -y -qq curl socat cron jq dnsutils >/dev/null

# 确保 dig 可用（dnsutils 可能在不同源中）
if ! command -v dig >/dev/null; then
    echo "dig 未安装，尝试安装 bind-host 或 dnsutils..."
    apt-get install -y -qq bind9-host >/dev/null || true
fi

# 安装 acme.sh（如果尚未安装）
ACME_HOME="$HOME/.acme.sh"
if [ ! -f "$ACME_HOME/acme.sh" ]; then
    echo ">>> 安装 acme.sh..."
    curl -sS https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null
    # 重新加载环境变量
    . "$HOME/.bashrc" 2>/dev/null || true
    export PATH="$HOME/.acme.sh:$PATH"
fi

# 设置 CA 为 Let's Encrypt（避免 ZeroSSL 注册失败）
$HOME/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null

# 注册账户（静默）
$HOME/.acme.sh/acme.sh --register-account -m admin@${DOMAIN} >/dev/null

echo ">>> 检查域名解析..."
# 获取本机公网 IP
MY_IP=$(curl -sS -4 https://api.ipify.org 2>/dev/null || curl -sS -4 http://ip.sb 2>/dev/null || curl -sS -4 http://ifconfig.me 2>/dev/null)
if [ -z "$MY_IP" ]; then
    echo "无法获取本机公网 IP，请确认网络连通性"
    exit 1
fi

# 解析域名（使用 dig 或 host 备用）
if command -v dig >/dev/null; then
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -1 || true)
else
    DOMAIN_IP=$(host "$DOMAIN" | grep "has address" | tail -1 | awk '{print $NF}' || true)
fi

# 域名无法解析的情况
if [ -z "$DOMAIN_IP" ]; then
    echo "错误: 域名 $DOMAIN 无法解析到任何 IP，请确认 DNS 记录已添加。"
    exit 1
fi

# IP 不匹配处理
if [ "$DOMAIN_IP" != "$MY_IP" ]; then
    echo "警告: 域名 $DOMAIN 解析到的 IP ($DOMAIN_IP) 和本机公网 IP ($MY_IP) 不一致。"
    echo "请确认 DNS 记录已指向本机，否则 HTTP 验证会失败。"
    read -rp "是否继续尝试？(y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 检查 80 端口是否被占用（本地监听）
echo ">>> 检查 80 端口占用..."
PORT80_OCCUPIED=0
if command -v ss >/dev/null; then
  if ss -tlnp | grep -E ':80\b' >/dev/null 2>&1; then
    PORT80_OCCUPIED=1
    echo "⚠️  80 端口已被本地程序占用，这可能导致 standalone 验证失败。"
    echo "请先停止占用该端口的服务（如 nginx、apache2 等）或者修改验证方式。"
  else
    echo "80 端口本地空闲。"
  fi
else
  echo "无法检测端口占用（ss 命令不存在），跳过本地端口检查。"
fi

# 外部可达性检查（仅当本地端口空闲时进行，因为本地占用时外部也可能可达但 acme 绑定会失败）
if [ "$PORT80_OCCUPIED" -eq 0 ]; then
    echo ">>> 检查 80 端口外部可达性..."
    # 使用本机公网 IP 进行连通性测试，避免域名解析不一致的影响
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 "http://${MY_IP}" 2>/dev/null || true)
    if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
        echo "错误: 无法从外部连接到本机的 80 端口。"
        echo "可能的原因："
        echo "  1) 主机上的防火墙阻止了 80 端口入站流量"
        echo "  2) 云服务商的安全组/防火墙规则未开放 80 端口"
        echo "  3) 路由/NAT 设置不正确"
        echo "请确保 80 端口可从公网访问，然后重试。"
        exit 1
    else
        echo "80 端口外部可达，返回 HTTP 状态码 ${HTTP_CODE}。"
        if [ "$HTTP_CODE" != "404" ] && [ "$HTTP_CODE" != "403" ] && [ "$HTTP_CODE" != "200" ]; then
            echo "注意：80 端口响应了状态码 ${HTTP_CODE}，可能已有其他 Web 服务运行。"
            echo "standalone 模式会临时绑定 80 端口，如果存在其他服务可能导致冲突。"
        fi
    fi
else
    echo "跳过外部可达性检查（本地已有程序占用 80 端口）。"
    read -rp "是否仍要继续尝试申请证书？(y/N): " CONTINUE_AFTER80
    if [[ ! "$CONTINUE_AFTER80" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 申请证书（standalone 模式，需要 80 端口空闲）
echo ">>> 开始申请证书..."
if ! $HOME/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force; then
    echo "证书申请失败！"
    echo "常见原因："
    echo "  - 域名解析不指向本机，或 DNS 记录尚未生效"
    echo "  - 80 端口被防火墙或 NAT 阻挡"
    echo "  - 其他进程占用了 80 端口，导致 acme 无法绑定"
    echo "  - Let's Encrypt 验证服务器暂时无法访问"
    echo "请修正后重试，或手动运行调试命令查看详细错误："
    echo "  ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 --debug"
    exit 1
fi

echo ">>> 安装证书到 /etc/hysteria/"
mkdir -p /etc/hysteria
$HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/hysteria/server.key \
    --fullchain-file /etc/hysteria/server.crt \
    --reloadcmd "systemctl reload hysteria-server 2>/dev/null || true"

# 设置权限
chmod 640 /etc/hysteria/server.key
chown root:root /etc/hysteria/server.key /etc/hysteria/server.crt

echo ">>> 证书申请并安装完成！"
echo "certificate: /etc/hysteria/server.crt"
echo "private key:  /etc/hysteria/server.key"
