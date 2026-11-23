#!/usr/bin/env bash
# VLESS + WebSocket + TLS + Cloudflare 管理脚本
# Ubuntu 22.04 优先；保留现有节点参数，支持安全升级、备份、回滚和健康检查。
# 注意：Cloudflare 橙云必须开启 WebSockets，SSL/TLS 模式使用 Full 或 Full (strict)。
set -Eeuo pipefail
umask 077

VERSION="2.0.0"
XRAY_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
DATA_DIR="/root/vless-cf"
BACKUP_ROOT="/root/vless-cf-backups"
ACME_HOME="/root/.acme.sh"
ACME_SH="${ACME_HOME}/acme.sh"
INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
CF_PORTS=(443 8443 2053 2083 2087 2096)
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
say(){ printf "%b\n" "$*"; }
info(){ say "${CYAN}[信息]${RESET} $*"; }
ok(){ say "${GREEN}[完成]${RESET} $*"; }
warn(){ say "${YELLOW}[注意]${RESET} $*"; }
err(){ say "${RED}[错误]${RESET} $*" >&2; }
die(){ err "$*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行。"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd。"

TX_ACTIVE=0
TX_BACKUP=""
OLD_WAS_ACTIVE=0
rollback_on_error(){
  local rc=$?
  if [[ $TX_ACTIVE -eq 1 && -n "$TX_BACKUP" && -d "$TX_BACKUP" ]]; then
    err "操作失败，正在尝试恢复升级前配置..."
    systemctl stop xray >/dev/null 2>&1 || true
    [[ -d "$TX_BACKUP/xray" ]] && { rm -rf "$XRAY_DIR"; cp -a "$TX_BACKUP/xray" "$XRAY_DIR"; }
    [[ -d "$TX_BACKUP/data" ]] && { rm -rf "$DATA_DIR"; cp -a "$TX_BACKUP/data" "$DATA_DIR"; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ $OLD_WAS_ACTIVE -eq 1 ]]; then
      systemctl restart xray >/dev/null 2>&1 || true
    fi
    err "回滚尝试已执行。请检查：journalctl -u xray -n 80 --no-pager"
  fi
  exit "$rc"
}
trap rollback_on_error ERR

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
port_busy(){
  local p="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${p}$"
}
make_backup(){
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  TX_BACKUP="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$TX_BACKUP"
  [[ -d "$XRAY_DIR" ]] && cp -a "$XRAY_DIR" "$TX_BACKUP/xray"
  [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR" "$TX_BACKUP/data"
  chmod -R go-rwx "$TX_BACKUP"
  ok "升级前备份：$TX_BACKUP"
}
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates openssl unzip iproute2 socat cron python3 logrotate
  systemctl enable --now cron >/dev/null 2>&1 || true
}
detect_owner(){
  SVC_USER="$(systemctl show -p User --value xray 2>/dev/null || true)"
  [[ -n "$SVC_USER" ]] || SVC_USER="nobody"
  id "$SVC_USER" >/dev/null 2>&1 || SVC_USER="root"
  SVC_GROUP="$(id -gn "$SVC_USER" 2>/dev/null || echo root)"
}
fix_cert_perms(){
  detect_owner
  chown "$SVC_USER:$SVC_GROUP" "$XRAY_DIR/server.key" "$XRAY_DIR/server.crt"
  chmod 640 "$XRAY_DIR/server.key"
  chmod 644 "$XRAY_DIR/server.crt"
}
load_existing(){
  DOMAIN=""; PORT=""; UUID=""; WS_PATH=""; CERT_MODE="acme"
  [[ -s "$DATA_DIR/domain.txt" ]] && DOMAIN="$(<"$DATA_DIR/domain.txt")"
  [[ -s "$DATA_DIR/port.txt" ]] && PORT="$(<"$DATA_DIR/port.txt")"
  [[ -s "$DATA_DIR/mode.txt" ]] && CERT_MODE="$(<"$DATA_DIR/mode.txt")"
  if [[ -s "$XRAY_DIR/config.json" ]] && command -v python3 >/dev/null 2>&1; then
    local vals
    vals="$(python3 - "$XRAY_DIR/config.json" <<'PY' 2>/dev/null || true
import json,sys
try:
 d=json.load(open(sys.argv[1]))
 i=d["inbounds"][0]
 print(i.get("port",""))
 print(i.get("settings",{}).get("clients",[{}])[0].get("id",""))
 print(i.get("streamSettings",{}).get("wsSettings",{}).get("path",""))
except Exception: pass
PY
)"
    if [[ -n "$vals" ]]; then
      mapfile -t _v <<<"$vals"
      [[ -n "${_v[0]:-}" ]] && PORT="${PORT:-${_v[0]}}"
      UUID="${_v[1]:-}"
      WS_PATH="${_v[2]:-}"
    fi
  fi
  if [[ -z "$DOMAIN" && -s "$DATA_DIR/link.txt" ]]; then
    DOMAIN="$(sed -n 's#^vless://[^@]*@\([^:?#]*\).*#\1#p' "$DATA_DIR/link.txt" | head -n1)"
  fi
}
ask_domain(){
  local d
  read -rp "请输入 Cloudflare 托管并解析到本机的域名${DOMAIN:+ [$DOMAIN]}: " d
  DOMAIN="${d:-$DOMAIN}"
  DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN// /}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "域名格式不正确。"
}
choose_port(){
  local p
  if [[ -n "$PORT" && "$PORT" =~ ^[0-9]+$ ]] && [[ " ${CF_PORTS[*]} " == *" $PORT "* ]]; then
    if port_busy "$PORT"; then
      # 如果监听者是旧 Xray，安装流程会先停止它；先保留端口。
      if systemctl is-active --quiet xray; then
        info "现有 Xray 正在使用端口 $PORT，升级时将保留该端口。"
        return
      fi
      warn "保存的端口 $PORT 已被其他进程占用，将重新选择。"
    else
      return
    fi
  fi
  for p in "${CF_PORTS[@]}"; do
    if ! port_busy "$p"; then PORT="$p"; return; fi
  done
  die "Cloudflare 支持的 HTTPS 端口均被占用。"
}
install_xray(){
  if [[ -x "$XRAY_BIN" ]]; then
    info "检测到 Xray：$("$XRAY_BIN" version 2>/dev/null | head -n1)"
    read -rp "是否更新到安装器当前提供的版本？[y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
  fi
  local f="/tmp/xray-install-${RANDOM}.sh"
  curl --connect-timeout 15 --max-time 180 -fsSL "$INSTALLER_URL" -o "$f"
  [[ -s "$f" ]] || die "Xray 安装器下载为空。"
  bash "$f" install
  rm -f "$f"
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装后未找到 $XRAY_BIN"
}
install_acme(){
  if [[ ! -x "$ACME_SH" ]]; then
    local f="/tmp/acme-install-${RANDOM}.sh"
    curl --connect-timeout 15 --max-time 120 -fsSL https://get.acme.sh -o "$f"
    bash "$f"
    rm -f "$f"
  fi
  [[ -x "$ACME_SH" ]] || die "acme.sh 安装失败。"
  "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null
}
issue_cert(){
  mkdir -p "$XRAY_DIR"
  install_acme
  info "使用 HTTP-01 standalone 申请/续期证书。要求 TCP 80 从公网可达且未被其他程序占用。"
  if port_busy 80; then
    die "80 端口已被占用。请先释放 80 端口；本版本不会擅自停止其他服务。"
  fi
  local issue_rc=0
  "$ACME_SH" --issue -d "$DOMAIN" --standalone --httpport 80 -k ec-256 --server letsencrypt || issue_rc=$?
  # acme.sh 某些版本用退出码 2 表示证书仍有效、无需重新签发。
  [[ $issue_rc -eq 0 || $issue_rc -eq 2 ]] || die "证书签发失败，acme.sh 退出码：$issue_rc"
  detect_owner
  local reload_cmd
  reload_cmd="chown ${SVC_USER}:${SVC_GROUP} ${XRAY_DIR}/server.key ${XRAY_DIR}/server.crt; chmod 640 ${XRAY_DIR}/server.key; chmod 644 ${XRAY_DIR}/server.crt; systemctl restart xray >/dev/null 2>&1 || true"
  "$ACME_SH" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$XRAY_DIR/server.key" \
    --fullchain-file "$XRAY_DIR/server.crt" \
    --reloadcmd "$reload_cmd"
  [[ -s "$XRAY_DIR/server.key" && -s "$XRAY_DIR/server.crt" ]] || die "证书文件缺失。"
  fix_cert_perms
  CERT_MODE="acme"
}
setup_bbr(){
  local cc qdisc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR 已启用。"
  else
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
      cat > /etc/sysctl.d/99-vless-cf.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
      sysctl --system >/dev/null 2>&1 || true
      ok "已设置 BBR + FQ。"
    else
      warn "当前内核/虚拟化环境不支持启用 BBR，保留系统默认值。"
    fi
  fi
  [[ "$qdisc" == "fq" ]] || info "队列规则已按系统能力检测并尝试设置；实际效果取决于内核和 VPS 网络。"
}
write_logrotate(){
  mkdir -p /var/log/xray
  detect_owner
  chown "$SVC_USER:$SVC_GROUP" /var/log/xray
  chmod 750 /var/log/xray
  cat >/etc/logrotate.d/xray-vless-cf <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}
open_firewall_port(){
  local p="$1"
  # 只添加放行规则，不清理或重排用户已有规则，避免升级时误删规则。
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${p}/tcp" >/dev/null || warn "UFW 规则添加失败，请手动放行 TCP $p。"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    warn "iptables 临时放行已添加；持久化方式取决于系统现有规则管理工具。"
  else
    warn "未检测到活动防火墙。请同时检查 VPS 云安全组，放行 TCP $p。"
  fi
}
write_config(){
  [[ -n "$UUID" ]] || UUID="$(cat /proc/sys/kernel/random/uuid)"
  [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 格式异常。"
  [[ -n "$WS_PATH" && "$WS_PATH" == /* && "$WS_PATH" != *'"'* ]] || WS_PATH="/$(openssl rand -hex 16)"
  mkdir -p "$XRAY_DIR" "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  local tmp="${XRAY_DIR}/config.json.new"
  cat >"$tmp" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "alpn": ["http/1.1"],
        "certificates": [{
          "certificateFile": "${XRAY_DIR}/server.crt",
          "keyFile": "${XRAY_DIR}/server.key"
        }]
      },
      "wsSettings": {"path": "${WS_PATH}"}
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
  "$XRAY_BIN" run -test -config "$tmp"
  chmod 640 "$tmp"
  mv -f "$tmp" "$XRAY_DIR/config.json"
  chown root:root "$XRAY_DIR/config.json"
  local enc_path
  enc_path="$(python3 - "$WS_PATH" <<'PY'
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1],safe=""))
PY
)"
  local link="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&type=ws&host=${DOMAIN}&path=${enc_path}#VLESS-CF-${DOMAIN}"
  printf '%s\n' "$link" >"$DATA_DIR/link.txt"
  printf '%s\n' "$PORT" >"$DATA_DIR/port.txt"
  printf '%s\n' "$DOMAIN" >"$DATA_DIR/domain.txt"
  printf '%s\n' "$CERT_MODE" >"$DATA_DIR/mode.txt"
  chmod 600 "$DATA_DIR"/*.txt
  ok "新配置已通过 Xray 配置校验。"
}
start_and_check(){
  systemctl daemon-reload
  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 50 --no-pager
    die "Xray 未能正常启动。"
  }
  ss -H -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${PORT}$" || die "Xray 服务运行但未监听 TCP ${PORT}。"
  ok "Xray 正常运行并监听 TCP ${PORT}。"
}
show_info(){
  if [[ ! -s "$DATA_DIR/link.txt" ]]; then warn "尚未找到节点信息。"; return; fi
  local d p mode
  d="$(cat "$DATA_DIR/domain.txt")"; p="$(cat "$DATA_DIR/port.txt")"; mode="$(cat "$DATA_DIR/mode.txt")"
  say ""
  say "${GREEN}========== VLESS + WS + TLS 节点信息 ==========${RESET}"
  say "域名：$d"
  say "端口：$p"
  say "证书：$mode"
  say "导入链接："
  cat "$DATA_DIR/link.txt"
  say ""
  say "Cloudflare 设置："
  say "  DNS A/AAAA 记录开启橙色云朵（代理）"
  say "  SSL/TLS 模式使用 Full 或 Full (strict)"
  say "  Network -> WebSockets 保持开启"
  say "  云安全组放行 TCP $p"
  say "注意：不要把真实 VPS IP 当作客户端地址；客户端地址使用域名，SNI/Host 保持域名。"
}
health_check(){
  local failed=0
  systemctl is-active --quiet xray && ok "Xray 服务运行中" || { err "Xray 服务未运行"; failed=1; }
  if [[ -s "$XRAY_DIR/config.json" ]]; then
    "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json" >/dev/null 2>&1 && ok "配置校验通过" || { err "配置校验失败"; failed=1; }
  else err "配置文件不存在"; failed=1; fi
  if [[ -s "$XRAY_DIR/server.crt" ]]; then
    openssl x509 -in "$XRAY_DIR/server.crt" -noout -enddate
    openssl x509 -checkend 604800 -noout -in "$XRAY_DIR/server.crt" >/dev/null 2>&1 && ok "证书至少还有 7 天有效期" || { warn "证书将在 7 天内到期或已过期"; failed=1; }
  else err "证书不存在"; failed=1; fi
  if [[ -s "$DATA_DIR/port.txt" ]]; then
    local p; p="$(cat "$DATA_DIR/port.txt")"
    ss -H -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${p}$" && ok "TCP $p 正在监听" || { err "TCP $p 未监听"; failed=1; }
  fi
  return "$failed"
}
backup_now(){
  make_backup
  TX_ACTIVE=0
  ok "备份完成。"
}
restore_backup(){
  [[ -d "$BACKUP_ROOT" ]] || die "备份目录不存在。"
  local -a items=()
  mapfile -t items < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
  ((${#items[@]})) || die "没有可用备份。"
  echo "可用备份："
  local i=1
  for b in "${items[@]}"; do echo " $i) $(basename "$b")"; i=$((i+1)); done
  local n; read -rp "输入要恢复的序号: " n
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#items[@]})) || die "序号无效。"
  local b="${items[$((n-1))]}"
  read -rp "确认恢复 $(basename "$b")？这会覆盖当前配置 [y/N]: " c
  [[ "$c" =~ ^[Yy]$ ]] || return
  systemctl stop xray >/dev/null 2>&1 || true
  [[ -d "$b/xray" ]] && { rm -rf "$XRAY_DIR"; cp -a "$b/xray" "$XRAY_DIR"; }
  [[ -d "$b/data" ]] && { rm -rf "$DATA_DIR"; cp -a "$b/data" "$DATA_DIR"; }
  systemctl restart xray
  ok "恢复命令已执行。"
}
upgrade_flow(){
  install_deps
  load_existing
  if systemctl is-active --quiet xray; then OLD_WAS_ACTIVE=1; fi
  make_backup
  TX_ACTIVE=1
  ask_domain
  choose_port
  # 若现有证书仍有效且域名匹配，保留；否则重新申请。
  local cert_ok=0
  if [[ -s "$XRAY_DIR/server.crt" && -s "$XRAY_DIR/server.key" ]]; then
    openssl x509 -in "$XRAY_DIR/server.crt" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 &&
    openssl x509 -checkend 86400 -noout -in "$XRAY_DIR/server.crt" >/dev/null 2>&1 && cert_ok=1
  fi
  install_xray
  if [[ $cert_ok -eq 1 ]]; then
    info "现有证书域名匹配且未过期，保留证书。"
    fix_cert_perms
    CERT_MODE="${CERT_MODE:-acme}"
  else
    issue_cert
  fi
  setup_bbr
  write_logrotate
  write_config
  open_firewall_port "$PORT"
  start_and_check
  TX_ACTIVE=0
  show_info
  ok "升级完成。旧配置备份保存在：$TX_BACKUP"
}
update_core(){
  make_backup
  install_xray
  systemctl restart xray
  systemctl is-active --quiet xray || die "更新后 Xray 未能正常运行。"
  ok "Xray 更新完成；配置备份：$TX_BACKUP"
}
uninstall(){
  echo "卸载会停止并移除 Xray 程序及 /usr/local/etc/xray、/root/vless-cf。"
  echo "不会删除系统防火墙规则、BBR 设置、acme.sh 或备份。"
  read -rp "确认卸载？输入 YES: " c
  [[ "$c" == "YES" ]] || return
  make_backup
  systemctl disable --now xray >/dev/null 2>&1 || true
  local f="/tmp/xray-remove-${RANDOM}.sh"
  if curl --connect-timeout 15 --max-time 120 -fsSL "$INSTALLER_URL" -o "$f"; then
    bash "$f" remove --purge || warn "官方卸载器返回非零状态。"
  fi
  rm -f "$f"
  rm -rf "$XRAY_DIR" "$DATA_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "卸载完成。备份保留在 $BACKUP_ROOT；防火墙规则未自动删除。"
}
menu(){
  while true; do
    clear 2>/dev/null || true
    say "${GREEN}==============================================${RESET}"
    say " VLESS + WS + TLS + Cloudflare 管理脚本 v${VERSION}"
    say "${GREEN}==============================================${RESET}"
    echo " 1) 安装 / 安全升级（保留现有 UUID、WS 路径和端口）"
    echo " 2) 查看节点信息"
    echo " 3) 健康检查"
    echo " 4) 备份当前配置"
    echo " 5) 从备份恢复"
    echo " 6) 重启 Xray"
    echo " 7) 停止 Xray"
    echo " 8) 更新 Xray 内核"
    echo " 9) 卸载 Xray"
    echo " 0) 退出"
    read -rp "请选择 [0-9]: " c
    case "$c" in
      1) upgrade_flow ;;
      2) show_info ;;
      3) health_check || true ;;
      4) backup_now ;;
      5) restore_backup ;;
      6) systemctl restart xray && ok "已重启" ;;
      7) systemctl stop xray && ok "已停止" ;;
      8) update_core ;;
      9) uninstall ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
    echo
    read -rp "按回车返回菜单..." _
  done
}
menu
