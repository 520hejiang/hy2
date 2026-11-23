#!/usr/bin/env bash
# VLESS + WebSocket + TLS + Cloudflare 管理脚本
# Ubuntu 22.04 优先；保留现有节点参数，复用已有 ACME 证书，不擅自强制重签。
# Cloudflare：DNS 橙云、WebSockets 开启、SSL/TLS Full 或 Full (strict)。
set -Eeuo pipefail
umask 077

VERSION="3.2.0"
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
for c in curl openssl python3 ss awk grep sed install chown chmod; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"
done

DOMAIN=""; PORT=""; UUID=""; WS_PATH=""; CERT_MODE="acme"
SVC_USER="root"; SVC_GROUP="root"
TX_ACTIVE=0; TX_BACKUP=""; OLD_WAS_ACTIVE=0

detect_owner(){
  local u g
  u="$(systemctl show -p User --value xray 2>/dev/null || true)"
  g="$(systemctl show -p Group --value xray 2>/dev/null || true)"
  [[ -n "$u" ]] || u="root"
  id "$u" >/dev/null 2>&1 || die "Xray 服务用户 $u 不存在。"
  [[ -n "$g" ]] || g="$(id -gn "$u")"
  getent group "$g" >/dev/null 2>&1 || die "Xray 服务组 $g 不存在。"
  SVC_USER="$u"; SVC_GROUP="$g"
}

backup_one(){
  local src="$1" name="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$TX_BACKUP/$(dirname "$name")"
    cp -a "$src" "$TX_BACKUP/$name"
    : > "$TX_BACKUP/${name}.present"
  else
    : > "$TX_BACKUP/${name}.absent"
  fi
}
make_backup(){
  mkdir -p "$BACKUP_ROOT"; chmod 700 "$BACKUP_ROOT"
  TX_BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$TX_BACKUP"
  backup_one "$XRAY_DIR" "xray"
  backup_one "$DATA_DIR" "data"
  backup_one "/var/log/xray" "logs"
  backup_one "/etc/systemd/system/xray.service" "xray.service"
  backup_one "/etc/systemd/system/xray.service.d" "xray.service.d"
  chmod -R go-rwx "$TX_BACKUP"
  ok "已备份到：$TX_BACKUP"
}
restore_one(){
  local name="$1" dest="$2"
  if [[ -e "$TX_BACKUP/$name.present" ]]; then
    rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
    cp -a "$TX_BACKUP/$name" "$dest"
  elif [[ -e "$TX_BACKUP/$name.absent" ]]; then
    rm -rf "$dest"
  fi
}
rollback_on_error(){
  local rc=$?
  trap - EXIT
  if [[ $rc -ne 0 && $TX_ACTIVE -eq 1 && -n "$TX_BACKUP" && -d "$TX_BACKUP" ]]; then
    err "操作失败，尝试恢复本次变更……"
    systemctl stop xray >/dev/null 2>&1 || true
    restore_one xray "$XRAY_DIR"
    restore_one data "$DATA_DIR"
    restore_one logs "/var/log/xray"
    restore_one xray.service "/etc/systemd/system/xray.service"
    restore_one xray.service.d "/etc/systemd/system/xray.service.d"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ $OLD_WAS_ACTIVE -eq 1 ]]; then
      if systemctl restart xray >/dev/null 2>&1 && systemctl is-active --quiet xray; then
        err "回滚完成，旧 Xray 服务已重新运行。"
      else
        err "回滚文件已恢复，但旧服务未能启动；查看 journalctl -u xray -n 80 --no-pager"
      fi
    else
      err "文件已恢复；升级前服务未运行，因此没有自动启动。"
    fi
    err "备份目录：$TX_BACKUP"
  fi
  exit "$rc"
}
trap rollback_on_error EXIT

port_busy(){
  local p="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${p}$"
}
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates openssl iproute2 socat cron python3 logrotate
  systemctl enable --now cron >/dev/null 2>&1 || true
}

# 从旧 config 和原有 vless:// 链接恢复参数；空的 {} 配置不会覆盖旧链接信息。
load_existing(){
  DOMAIN=""; PORT=""; UUID=""; WS_PATH=""; CERT_MODE="acme"
  [[ -s "$DATA_DIR/domain.txt" ]] && DOMAIN="$(tr -d '\r\n' < "$DATA_DIR/domain.txt")"
  [[ -s "$DATA_DIR/port.txt" ]] && PORT="$(tr -d '\r\n' < "$DATA_DIR/port.txt")"
  [[ -s "$DATA_DIR/mode.txt" ]] && CERT_MODE="$(tr -d '\r\n' < "$DATA_DIR/mode.txt")"

  if [[ -s "$XRAY_DIR/config.json" ]]; then
    local vals
    vals="$(python3 - "$XRAY_DIR/config.json" <<'PY' 2>/dev/null || true
import json,sys
try:
 d=json.load(open(sys.argv[1]))
 for i in d.get("inbounds",[]):
  if i.get("protocol")=="vless":
   cl=(i.get("settings",{}).get("clients") or [{}])[0]
   ss=i.get("streamSettings",{})
   print(i.get("port","")); print(cl.get("id","")); print(ss.get("wsSettings",{}).get("path",""))
   break
except Exception: pass
PY
)"
    if [[ -n "$vals" ]]; then
      mapfile -t v <<<"$vals"
      [[ -n "${v[0]:-}" ]] && PORT="${PORT:-${v[0]}}"
      [[ -n "${v[1]:-}" ]] && UUID="${v[1]}"
      [[ -n "${v[2]:-}" ]] && WS_PATH="${v[2]}"
    fi
  fi

  if [[ -s "$DATA_DIR/link.txt" ]]; then
    local linkvals
    linkvals="$(python3 - "$DATA_DIR/link.txt" <<'PY' 2>/dev/null || true
import sys,urllib.parse
try:
 s=open(sys.argv[1]).read().strip()
 u=urllib.parse.urlsplit(s)
 q=urllib.parse.parse_qs(u.query)
 print(u.hostname or "")
 print(u.port or "")
 print(u.username or "")
 print(urllib.parse.unquote(q.get("path",[""])[0]))
except Exception: pass
PY
)"
    if [[ -n "$linkvals" ]]; then
      mapfile -t l <<<"$linkvals"
      [[ -n "${l[0]:-}" ]] && DOMAIN="${DOMAIN:-${l[0]}}"
      [[ -n "${l[1]:-}" ]] && PORT="${PORT:-${l[1]}}"
      [[ -n "${l[2]:-}" ]] && UUID="${UUID:-${l[2]}}"
      [[ -n "${l[3]:-}" ]] && WS_PATH="${WS_PATH:-${l[3]}}"
    fi
  fi
}

ask_domain(){
  local d
  read -rp "请输入 Cloudflare 托管并解析到本机的域名${DOMAIN:+ [$DOMAIN]}: " d
  DOMAIN="${d:-$DOMAIN}"; DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN// /}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "域名格式不正确。"
}
choose_port(){
  local p
  if [[ -n "$PORT" && "$PORT" =~ ^[0-9]+$ && " ${CF_PORTS[*]} " == *" $PORT "* ]]; then
    if port_busy "$PORT"; then
      if systemctl is-active --quiet xray; then
        info "当前 Xray 服务已占用/使用端口 $PORT，保留此端口。"
        return
      fi
      die "保存的端口 $PORT 已被其他程序占用；请先处理占用，不自动改端口以免破坏旧链接。"
    fi
    return
  fi
  for p in "${CF_PORTS[@]}"; do
    if ! port_busy "$p"; then PORT="$p"; return; fi
  done
  die "Cloudflare 支持的 HTTPS 端口均被占用。"
}

install_xray(){
  if [[ -x "$XRAY_BIN" ]]; then
    info "检测到 Xray：$("$XRAY_BIN" version 2>/dev/null | head -n1)"
    read -rp "是否更新 Xray 内核？默认保留当前版本 [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
  fi
  local f="/tmp/xray-install-$$.sh"
  curl --connect-timeout 15 --max-time 180 -fsSL "$INSTALLER_URL" -o "$f"
  [[ -s "$f" ]] || die "Xray 安装器下载为空。"
  bash "$f" install
  rm -f "$f"
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装后未找到 $XRAY_BIN"
}

prepare_acme(){
  if [[ ! -x "$ACME_SH" ]]; then
    local f="/tmp/acme-install-$$.sh"
    curl --connect-timeout 15 --max-time 120 -fsSL https://get.acme.sh -o "$f"
    bash "$f"; rm -f "$f"
  fi
  [[ -x "$ACME_SH" ]] || die "acme.sh 不存在。"
}
find_existing_cert(){
  local d="$1"
  local base
  for base in "$ACME_HOME/${d}_ecc" "$ACME_HOME/$d"; do
    [[ -s "$base/fullchain.cer" && -s "$base/$d.key" ]] && {
      printf '%s\n%s\n' "$base/fullchain.cer" "$base/$d.key"; return 0;
    }
    [[ -s "$base/$d.cer" && -s "$base/$d.key" ]] && {
      printf '%s\n%s\n' "$base/$d.cer" "$base/$d.key"; return 0;
    }
  done
  return 1
}
install_existing_acme_cert(){
  local pair cert key
  pair="$(find_existing_cert "$DOMAIN")" || return 1
  cert="$(sed -n '1p' <<<"$pair")"; key="$(sed -n '2p' <<<"$pair")"
  openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || die "找到的证书与 $DOMAIN 不匹配。"
  openssl x509 -checkend 86400 -noout -in "$cert" >/dev/null 2>&1 || die "已有证书已过期或 24 小时内到期；不会擅自强制重签。"
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die "证书与私钥不匹配，拒绝安装。"
  install -d -m 0750 "$XRAY_DIR"
  install -m 0640 -o root -g "$SVC_GROUP" "$key" "$XRAY_DIR/server.key"
  install -m 0644 -o root -g "$SVC_GROUP" "$cert" "$XRAY_DIR/server.crt"
  CERT_MODE="acme"
  ok "已复用本机已有 ACME 证书：$cert"
}
issue_cert_interactive(){
  prepare_acme
  local method
  echo "本机未找到可复用的有效证书。"
  echo " 1) HTTP-01 standalone（TCP 80 必须空闲且公网可达）"
  echo " 2) Cloudflare DNS-01（需要最小权限 API Token）"
  read -rp "请选择 [1/2]: " method
  case "$method" in
    1)
      port_busy 80 && die "80 端口被占用。不要停掉现有 Nginx；请选择 DNS-01 或自行安排验证。"
      "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null
      "$ACME_SH" --issue -d "$DOMAIN" --standalone --httpport 80 -k ec-256 --server letsencrypt
      ;;
    2)
      local token
      read -rsp "Cloudflare API Token（DNS:Edit + Zone:Read，仅授权该 Zone）: " token; echo
      [[ -n "$token" ]] || die "Token 不能为空。"
      export CF_Token="$token"
      "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null
      "$ACME_SH" --issue -d "$DOMAIN" --dns dns_cf -k ec-256 --server letsencrypt
      unset CF_Token token
      ;;
    *) die "无效选项。" ;;
  esac
  install_existing_acme_cert || die "签发命令完成，但未找到可安装的证书文件。"
}

prepare_runtime_permissions(){
  detect_owner
  # systemd User=xray 时，目录需要可遍历；配置文件由 root:xray 提供只读访问。
  install -d -o root -g "$SVC_GROUP" -m 0750 "$XRAY_DIR"
  install -d -o "$SVC_USER" -g "$SVC_GROUP" -m 0750 /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chown "$SVC_USER:$SVC_GROUP" /var/log/xray/access.log /var/log/xray/error.log
  chmod 0640 /var/log/xray/access.log /var/log/xray/error.log
  if [[ -s "$XRAY_DIR/server.key" ]]; then
    chown root:"$SVC_GROUP" "$XRAY_DIR/server.key"; chmod 0640 "$XRAY_DIR/server.key"
  fi
  if [[ -s "$XRAY_DIR/server.crt" ]]; then
    chown root:"$SVC_GROUP" "$XRAY_DIR/server.crt"; chmod 0644 "$XRAY_DIR/server.crt"
  fi
  if [[ -s "$XRAY_DIR/server.crt" && -s "$XRAY_DIR/server.key" ]]; then
    local cert_pub key_pub
    cert_pub="$(openssl x509 -in "$XRAY_DIR/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_pub="$(openssl pkey -in "$XRAY_DIR/server.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die "Xray 证书与私钥不匹配。"
  fi
  # 确保 /usr/local/etc 可被服务用户遍历，不改其属主。
  chmod o+x /usr/local /usr/local/etc 2>/dev/null || true
}
write_logrotate(){
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
  chmod 644 /etc/logrotate.d/xray-vless-cf
}

register_acme_deploy(){
  # 若证书由 acme.sh 管理，登记部署路径；续期时更新证书文件并重启 Xray。
  [[ -x "$ACME_SH" ]] || return 0
  local args=(--install-cert -d "$DOMAIN" --key-file "$XRAY_DIR/server.key" --fullchain-file "$XRAY_DIR/server.crt")
  [[ -d "$ACME_HOME/${DOMAIN}_ecc" ]] && args+=(--ecc)
  local reload
  reload="chown root:${SVC_GROUP} ${XRAY_DIR}/server.key ${XRAY_DIR}/server.crt && chmod 640 ${XRAY_DIR}/server.key && chmod 644 ${XRAY_DIR}/server.crt && systemctl restart xray"
  "$ACME_SH" "${args[@]}" --reloadcmd "$reload" >/dev/null || warn "acme.sh 自动部署钩子登记失败；当前证书仍可使用，请留意续期部署。"
}

open_firewall_port(){
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${p}/tcp" >/dev/null || warn "UFW 放行失败，请手动放行 TCP $p。"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "脚本不自动改写未知 iptables/nftables 规则。请检查 VPS 云防火墙/系统防火墙，放行 TCP $p。"
  fi
}

write_config(){
  [[ -n "$UUID" ]] || UUID="$(cat /proc/sys/kernel/random/uuid)"
  [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 格式异常。"
  [[ -n "$WS_PATH" && "$WS_PATH" == /* ]] || WS_PATH="/$(openssl rand -hex 16)"
  python3 - "$XRAY_DIR/config.json.new.json" "$PORT" "$UUID" "$WS_PATH" "$XRAY_DIR" <<'PY'
import json,sys
out,port,uid,path,d=sys.argv[1:]
cfg={
 "log":{"loglevel":"warning","access":"/var/log/xray/access.log","error":"/var/log/xray/error.log"},
 "inbounds":[{
  "listen":"0.0.0.0","port":int(port),"protocol":"vless",
  "settings":{"clients":[{"id":uid}],"decryption":"none"},
  "streamSettings":{
   "network":"ws","security":"tls",
   "tlsSettings":{"alpn":["http/1.1"],"certificates":[{"certificateFile":d+"/server.crt","keyFile":d+"/server.key"}]},
   "wsSettings":{"path":path}
  }
 }],
 "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]
}
with open(out,"w") as f: json.dump(cfg,f,indent=2)
PY
  "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json.new.json"
  chown root:"$SVC_GROUP" "$XRAY_DIR/config.json.new.json"
  chmod 0640 "$XRAY_DIR/config.json.new.json"
  mv -f "$XRAY_DIR/config.json.new.json" "$XRAY_DIR/config.json"
  local enc_path
  enc_path="$(python3 - "$WS_PATH" <<'PY'
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1],safe=""))
PY
)"
  local link="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&type=ws&host=${DOMAIN}&path=${enc_path}#VLESS-CF-${DOMAIN}"
  install -d -m 0700 "$DATA_DIR"
  printf '%s\n' "$link" >"$DATA_DIR/link.txt"
  printf '%s\n' "$PORT" >"$DATA_DIR/port.txt"
  printf '%s\n' "$DOMAIN" >"$DATA_DIR/domain.txt"
  printf '%s\n' "$CERT_MODE" >"$DATA_DIR/mode.txt"
  chmod 0600 "$DATA_DIR"/*.txt
  ok "配置已生成并通过 Xray 配置校验。"
}

start_and_check(){
  systemctl daemon-reload
  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 2
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 60 --no-pager
    die "Xray 启动失败。"
  fi
  if ! ss -H -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${PORT}$"; then
    journalctl -u xray -n 30 --no-pager
    die "Xray 进程运行但未监听 TCP $PORT。"
  fi
  ok "Xray 已运行并监听 TCP $PORT。"
}
setup_bbr(){
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$cc" == "bbr" ]]; then ok "BBR 已启用。"; return; fi
  modprobe tcp_bbr 2>/dev/null || true
  if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 &&
     sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-vless-cf.conf
    ok "已尝试启用 BBR + FQ。"
  else
    warn "当前内核/虚拟化环境不支持 BBR，保留原设置。"
  fi
}

show_info(){
  [[ -s "$DATA_DIR/link.txt" ]] || { warn "尚无节点链接。"; return; }
  echo "域名：$(cat "$DATA_DIR/domain.txt")"
  echo "端口：$(cat "$DATA_DIR/port.txt")"
  echo "导入链接（含 UUID，请勿公开）："
  cat "$DATA_DIR/link.txt"
  echo "Cloudflare：DNS 记录橙云开启；WebSockets 开启；SSL/TLS 使用 Full 或 Full (strict)。"
  echo "云安全组和系统防火墙需允许 TCP $(cat "$DATA_DIR/port.txt")。"
}
health_check(){
  local failed=0 p
  systemctl is-active --quiet xray && ok "Xray 服务运行中" || { err "Xray 服务未运行"; failed=1; }
  if [[ -s "$XRAY_DIR/config.json" ]]; then
    "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json" && ok "配置校验通过" || failed=1
  else err "配置文件不存在"; failed=1; fi
  if [[ -s "$XRAY_DIR/server.crt" ]]; then
    openssl x509 -in "$XRAY_DIR/server.crt" -noout -subject -dates || failed=1
    openssl x509 -checkend 604800 -noout -in "$XRAY_DIR/server.crt" >/dev/null 2>&1 && ok "证书至少还有 7 天有效期" || { warn "证书将在 7 天内到期或已过期"; failed=1; }
  else err "证书文件不存在"; failed=1; fi
  if [[ -s "$DATA_DIR/port.txt" ]]; then
    p="$(cat "$DATA_DIR/port.txt")"
    ss -H -ltn | awk '{print $4}' | grep -Eq "(:|\\.)${p}$" && ok "TCP $p 正在监听" || { err "TCP $p 未监听"; failed=1; }
  fi
  return "$failed"
}
backup_now(){ make_backup; TX_ACTIVE=0; ok "备份完成。"; }

restore_backup(){
  [[ -d "$BACKUP_ROOT" ]] || die "备份目录不存在。"
  local -a items=()
  mapfile -t items < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
  ((${#items[@]})) || die "没有可用备份。"
  local i=1 b n
  for b in "${items[@]}"; do echo "$i) $(basename "$b")"; i=$((i+1)); done
  read -rp "选择备份序号: " n
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#items[@]})) || die "序号无效。"
  b="${items[$((n-1))]}"
  read -rp "确认恢复 $(basename "$b")？[y/N]: " n
  [[ "$n" =~ ^[Yy]$ ]] || return
  systemctl stop xray >/dev/null 2>&1 || true
  TX_BACKUP="$b"
  restore_one xray "$XRAY_DIR"; restore_one data "$DATA_DIR"; restore_one logs "/var/log/xray"
  restore_one xray.service "/etc/systemd/system/xray.service"
  restore_one xray.service.d "/etc/systemd/system/xray.service.d"
  systemctl daemon-reload
  systemctl restart xray
  systemctl is-active --quiet xray || die "恢复后 Xray 未能启动。"
  ok "备份恢复并启动成功。"
}

upgrade_flow(){
  install_deps
  load_existing
  systemctl is-active --quiet xray && OLD_WAS_ACTIVE=1 || true
  make_backup
  TX_ACTIVE=1
  ask_domain
  choose_port
  detect_owner

  # 优先复用 XRAY_DIR 已安装证书；其次复用 acme.sh 原始证书，不重签。
  local cert_found=0
  if [[ -s "$XRAY_DIR/server.crt" && -s "$XRAY_DIR/server.key" ]] &&
     openssl x509 -in "$XRAY_DIR/server.crt" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 &&
     openssl x509 -checkend 86400 -noout -in "$XRAY_DIR/server.crt" >/dev/null 2>&1; then
    cert_found=1
    info "复用 Xray 目录中已有的有效证书。"
  else
    if install_existing_acme_cert; then cert_found=1; fi
  fi

  if [[ ! -x "$XRAY_BIN" ]]; then
    install_xray
  else
    info "保留当前 Xray 内核，不强制覆盖。"
  fi
  if [[ $cert_found -eq 0 ]]; then
    warn "未找到可复用的有效证书。"
    issue_cert_interactive
  fi

  prepare_runtime_permissions
  write_logrotate
  write_config
  register_acme_deploy
  prepare_runtime_permissions
  open_firewall_port "$PORT"
  setup_bbr
  start_and_check
  TX_ACTIVE=0
  show_info
  ok "安装/修复完成。备份：$TX_BACKUP"
}

update_core(){
  make_backup
  OLD_WAS_ACTIVE=1
  TX_ACTIVE=1
  install_xray
  systemctl restart xray
  systemctl is-active --quiet xray || die "更新后 Xray 未能正常运行。"
  TX_ACTIVE=0
  ok "Xray 内核更新完成；备份：$TX_BACKUP"
}
uninstall(){
  echo "卸载会移除 Xray 程序、配置和节点数据；证书 ACME 账户与备份会保留。"
  read -rp "确认卸载？输入 YES: " c
  [[ "$c" == "YES" ]] || return
  make_backup
  systemctl disable --now xray >/dev/null 2>&1 || true
  local f="/tmp/xray-remove-$$.sh"
  if curl --connect-timeout 15 --max-time 120 -fsSL "$INSTALLER_URL" -o "$f"; then
    bash "$f" remove --purge || warn "官方卸载器返回非零状态。"
  fi
  rm -f "$f"; rm -rf "$XRAY_DIR" "$DATA_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "卸载完成；备份保留在 $BACKUP_ROOT。"
}

menu(){
  while true; do
    echo
    say "${GREEN}===== VLESS + WS + TLS + Cloudflare v${VERSION} =====${RESET}"
    echo "1) 安装 / 修复 / 安全升级（优先保留 UUID、WS 路径、端口和已有证书）"
    echo "2) 查看节点信息"
    echo "3) 健康检查"
    echo "4) 备份当前配置"
    echo "5) 从备份恢复"
    echo "6) 重启 Xray"
    echo "7) 停止 Xray"
    echo "8) 更新 Xray 内核"
    echo "9) 卸载 Xray"
    echo "0) 退出"
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
  done
}
menu
