#!/usr/bin/env bash
# SSH port-forward tunnel (Iran -> Kharej)
#   Kharej: dedicated sshd instance (own port / host key / unit / user), key-only, forwarding-only.
#   Iran  : ssh -N -L 0.0.0.0:PORT:127.0.0.1:PORT for each port (systemd, auto-restart).
#
# Install / menu:
#   curl -fsSL https://raw.githubusercontent.com/khodehamed/ssh-tunnel/master/install.sh | sudo bash
# Non-interactive:
#   Kharej: curl -fsSL .../install.sh | sudo NONINTERACTIVE=1 SSH_PORT=2222 PORTS="443 2083" bash -s -- install-kharej
#   Iran  : curl -fsSL .../install.sh | sudo NONINTERACTIVE=1 CODE='<code>' bash -s -- install-iran
# Management: sshtun  (status | restart | ports | logs | code | uninstall)
set -uo pipefail

REPO_RAW="${SSHTUN_RAW:-https://raw.githubusercontent.com/khodehamed/ssh-tunnel/master}"
INSTALL_DIR="/opt/ssh-tunnel"
SERVICE_NAME="ssh-tunnel"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONF_ENV="${INSTALL_DIR}/tunnel.env"
SSHD_CONF="${INSTALL_DIR}/sshd_config"
HOST_KEY="${INSTALL_DIR}/ssh_host_ed25519_key"
CLIENT_KEY="${INSTALL_DIR}/client_ed25519"
AUTH_KEYS="${INSTALL_DIR}/authorized_keys"
IRAN_KEY="${INSTALL_DIR}/id_ed25519"
KNOWN_HOSTS="${INSTALL_DIR}/known_hosts"
BIN_LINK="/usr/local/bin/sshtun"
TUN_USER_DEFAULT="sshtun"
FW_TAG="ssh-tunnel"

DEFAULT_PORTS="443 2053 2083 2087 2096 8443"
DEFAULT_SSH_PORT="2222"

# Inputs from environment (non-interactive); saved before tunnel.env is sourced.
IN_PORTS="${PORTS:-}"
IN_SSH_PORT="${SSH_PORT:-}"
IN_CODE="${CODE:-}"
IN_KHAREJ_IP="${KHAREJ_IP:-}"
unset PORTS SSH_PORT CODE KHAREJ_IP

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}Run as root:${NC} curl -fsSL ... | sudo bash"
    exit 1
  fi
}

msg()  { echo -e "${CYN}==>${NC} $*"; }
ok()   { echo -e "${GRN}OK${NC} $*"; }
warn() { echo -e "${YLW}WARN${NC} $*"; }
err()  { echo -e "${RED}ERR${NC} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Prompts read from the controlling TTY so `curl | bash` works (stdin is the pipe).
HAVE_TTY=0
if [[ "${NONINTERACTIVE:-0}" != "1" ]] && { true </dev/tty; } 2>/dev/null; then
  HAVE_TTY=1
fi

read_tty() {
  if [[ "$HAVE_TTY" == "1" ]]; then
    # shellcheck disable=SC2162
    read "$@" </dev/tty
  else
    return 1
  fi
}

# ask VAR "Prompt" [default]
ask() {
  local __v="" __p="$2" __d="${3:-}"
  [[ -n "$__d" ]] && __p+=" [${__d}]"
  read_tty -r -p "${__p}: " __v || __v=""
  printf -v "$1" '%s' "${__v:-$__d}"
}

# confirm "Question" Y|N  -> 0 when yes
confirm() {
  local a="" d="${2:-N}" hint="[y/N]"
  [[ "$d" == "Y" ]] && hint="[Y/n]"
  read_tty -r -p "$1 ${hint}: " a || a=""
  a="${a:-$d}"
  [[ "$a" =~ ^[Yy] ]]
}

validate_ip() {
  local ip="$1" IFS=.
  local -a o
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a o <<<"$ip"
  local x
  for x in "${o[@]}"; do ((x <= 255)) || return 1; done
  return 0
}

validate_host() {
  validate_ip "$1" && return 0
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

normalize_ports() {
  # "443,2083 443" -> "443 2083"
  echo "$1" | tr ',;' '  ' | xargs -n1 2>/dev/null | awk '!s[$0]++' | xargs
}

validate_ports() {
  local p
  [[ -n "$1" ]] || return 1
  for p in $1; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535)) || return 1
  done
  return 0
}

validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }

detect_public_ip() {
  local ip="" url
  for url in "https://ifconfig.me" "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
    ip="$(curl -4 -fsS --connect-timeout 2 --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if validate_ip "${ip:-}"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if validate_ip "${ip:-}"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

load_env() {
  SIDE=""; SSH_PORT=""; PORTS=""; KHAREJ_IP=""; TUN_USER="$TUN_USER_DEFAULT"
  KH_PORTS=""; CIPHERS=""; FWD=""; UFW_ADDED=""
  [[ -f "$CONF_ENV" ]] || return 1
  # shellcheck disable=SC1090
  source "$CONF_ENV"
  [[ -n "$SIDE" ]]
}

write_env() {
  mkdir -p "$INSTALL_DIR"
  {
    echo "SIDE=${SIDE}"
    echo "SSH_PORT=${SSH_PORT}"
    echo "PORTS=\"${PORTS}\""
    echo "KHAREJ_IP=${KHAREJ_IP}"
    echo "TUN_USER=${TUN_USER}"
    if [[ "$SIDE" == "iran" ]]; then
      echo "KH_PORTS=\"${KH_PORTS}\""
      echo "CIPHERS=${CIPHERS}"
      echo "FWD=\"${FWD}\""
    fi
    echo "UFW_ADDED=\"$(xargs <<<"${UFW_ADDED}")\""
  } >"$CONF_ENV"
  chmod 600 "$CONF_ENV"
}

service_pid() {
  local pid
  pid="$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || echo 0)"
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
  echo "$pid"
}

# Prints "port: listener" lines for busy ports (ignores our own service pid) and sets BUSY_PORTS.
BUSY_PORTS=""
check_busy_ports() {
  local ports="$1" own="${2:-0}" p line
  BUSY_PORTS=""
  have ss || return 0
  for p in $ports; do
    line="$(ss -lntpH "sport = :$p" 2>/dev/null | grep -v "pid=${own}," | head -n1)"
    if [[ -n "$line" ]]; then
      BUSY_PORTS+="$p "
      echo "  port ${p}: $(awk '{print $4, $6}' <<<"$line")"
    fi
  done
  BUSY_PORTS="$(xargs <<<"$BUSY_PORTS")"
}

# Iran: drop ports that another service already listens on (x-ui, WaterWall, nginx ...).
# Result in FREE_PORTS.
FREE_PORTS=""
filter_busy_ports() {
  local ports="$1" own="${2:-0}" p b keep
  FREE_PORTS="$ports"
  check_busy_ports "$ports" "$own" >/dev/null
  [[ -z "$BUSY_PORTS" ]] && return 0
  echo
  warn "These ports are already in use on this server (another service listens on them):"
  check_busy_ports "$ports" "$own"
  echo "  The tunnel cannot bind them (x-ui / xray / WaterWall / nginx ...)."
  echo "  پورت‌های اشغال‌شده رد می‌شوند (یا سرویس دیگر را متوقف کنید)."
  FREE_PORTS=""
  for p in $ports; do
    keep=1
    for b in $BUSY_PORTS; do [[ "$p" == "$b" ]] && keep=0; done
    ((keep)) && FREE_PORTS+="$p "
  done
  FREE_PORTS="$(xargs <<<"$FREE_PORTS")"
  [[ -n "$FREE_PORTS" ]] || err "All selected ports are busy. Free them or choose other ports."
  if [[ "$HAVE_TTY" == "1" ]]; then
    confirm "Skip busy ports (${BUSY_PORTS}) and continue with: ${FREE_PORTS} ?" Y || err "Aborted."
  else
    warn "Skipping busy ports: ${BUSY_PORTS}"
  fi
}

ensure_deps() {
  local side="$1" pkgs=()
  have ssh || pkgs+=(openssh-client)
  have ssh-keygen || pkgs+=(openssh-client)
  have ss || pkgs+=(iproute2)
  have curl || pkgs+=(curl)
  have base64 || pkgs+=(coreutils)
  if [[ "$side" == "kharej" ]] && ! sshd_bin >/dev/null; then
    pkgs+=(openssh-server)
  fi
  if ((${#pkgs[@]})); then
    msg "Installing: ${pkgs[*]}"
    have apt-get || err "Missing ${pkgs[*]} and apt-get not found"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || err "apt-get install failed: ${pkgs[*]}"
  fi
}

sshd_bin() {
  local b
  for b in /usr/sbin/sshd "$(command -v sshd 2>/dev/null)"; do
    [[ -n "$b" && -x "$b" ]] && { echo "$b"; return 0; }
  done
  return 1
}

save_self() {
  mkdir -p "$INSTALL_DIR"
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    if [[ "$(readlink -f "$src")" != "$(readlink -f "${INSTALL_DIR}/install.sh" 2>/dev/null)" ]]; then
      cp -f "$src" "${INSTALL_DIR}/install.sh"
    fi
  else
    if curl -fsSL "${REPO_RAW}/install.sh" -o "${INSTALL_DIR}/install.sh.tmp"; then
      mv -f "${INSTALL_DIR}/install.sh.tmp" "${INSTALL_DIR}/install.sh"
    else
      rm -f "${INSTALL_DIR}/install.sh.tmp"
      warn "Could not save installer locally (menu will download it on demand)"
    fi
  fi
  [[ -f "${INSTALL_DIR}/install.sh" ]] && chmod 755 "${INSTALL_DIR}/install.sh"
}

write_menu_wrapper() {
  cat >"$BIN_LINK" <<EOF
#!/usr/bin/env bash
if [[ -f "${INSTALL_DIR}/install.sh" ]]; then
  exec bash "${INSTALL_DIR}/install.sh" "\$@"
fi
exec bash -c "curl -fsSL ${REPO_RAW}/install.sh | sudo bash -s -- \$*"
EOF
  chmod +x "$BIN_LINK"
}

# ---------------- firewall ----------------
# Rules: "req <spec>" always added; "opt <spec>" only when INPUT policy is not ACCEPT.
fw_rules() {
  local p
  case "$SIDE" in
    kharej)
      echo "req -p tcp --dport ${SSH_PORT}"
      ;;
    iran)
      echo "req -s ${KHAREJ_IP} -p tcp --sport ${SSH_PORT}"
      for p in $PORTS; do echo "opt -p tcp --dport ${p}"; done
      ;;
  esac
}

fw_add() {
  [[ -n "${SIDE:-}" ]] || return 0
  have iptables || return 0
  local policy kind spec
  policy="$(iptables -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}')"
  while read -r kind spec; do
    [[ -n "$spec" ]] || continue
    [[ "$kind" == "opt" && "$policy" == "ACCEPT" ]] && continue
    # shellcheck disable=SC2086
    iptables -C INPUT $spec -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT $spec -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null || true
  done < <(fw_rules)
  return 0
}

fw_del() {
  [[ -n "${SIDE:-}" ]] || return 0
  have iptables || return 0
  local kind spec n
  while read -r kind spec; do
    [[ -n "$spec" ]] || continue
    n=0
    # shellcheck disable=SC2086
    while iptables -C INPUT $spec -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null && ((n++ < 20)); do
      iptables -D INPUT $spec -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null || break
    done
  done < <(fw_rules)
  return 0
}

# Remove firewall rules of the saved (old) config without touching current variables.
cleanup_old_fw() {
  (
    load_env || exit 0
    fw_del
    ufw_del
  )
}

ufw_active() { have ufw && ufw status 2>/dev/null | grep -q "Status: active"; }

# ufw_add "ports" -> appends only ports we actually added to UFW_ADDED
ufw_add() {
  ufw_active || return 0
  local p
  for p in $1; do
    if ! ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]+ALLOW"; then
      ufw allow "${p}/tcp" comment "$FW_TAG" >/dev/null 2>&1 && UFW_ADDED+=" $p"
    fi
  done
  return 0
}

ufw_del() {
  have ufw || return 0
  local p
  for p in ${UFW_ADDED:-}; do
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
  done
  UFW_ADDED=""
  return 0
}

# ---------------- kharej ----------------
ensure_tunnel_user() {
  local sh
  sh="$(command -v nologin 2>/dev/null || echo /bin/false)"
  if ! id -u "$TUN_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell "$sh" "$TUN_USER" \
      || err "Could not create user ${TUN_USER}"
  fi
  # "*" = no password but not "locked" (sshd with UsePAM=no rejects locked "!" accounts).
  usermod -p '*' "$TUN_USER" >/dev/null 2>&1 || true
}

ensure_kharej_keys() {
  mkdir -p "$INSTALL_DIR"
  chmod 755 "$INSTALL_DIR"
  [[ -f "$HOST_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "${FW_TAG}-host" -f "$HOST_KEY" || err "host key generation failed"
  [[ -f "$CLIENT_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C "${FW_TAG}-client" -f "$CLIENT_KEY" || err "client key generation failed"
  chmod 600 "$HOST_KEY" "$CLIENT_KEY"
}

write_kharej_access() {
  local p permit="" opts="restrict,port-forwarding"
  for p in $PORTS; do
    permit+=" 127.0.0.1:${p}"
    opts+=",permitopen=\"127.0.0.1:${p}\""
  done
  echo "${opts} $(cut -d' ' -f1,2 "${CLIENT_KEY}.pub") ${FW_TAG}" >"$AUTH_KEYS"
  chown "root:${TUN_USER}" "$AUTH_KEYS"
  chmod 640 "$AUTH_KEYS"

  cat >"$SSHD_CONF" <<EOF
# ssh-tunnel: dedicated sshd (forwarding only). The system sshd is not touched.
Port ${SSH_PORT}
ListenAddress 0.0.0.0
HostKey ${HOST_KEY}
PidFile /run/${SERVICE_NAME}-sshd.pid
AuthorizedKeysFile ${AUTH_KEYS}
AllowUsers ${TUN_USER}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
UseDNS no
PrintMotd no
AllowTcpForwarding local
PermitOpen${permit}
GatewayPorts no
X11Forwarding no
PermitTunnel no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTTY no
ForceCommand /bin/false
ClientAliveInterval 15
ClientAliveCountMax 4
TCPKeepAlive yes
MaxStartups 50:30:100
MaxSessions 100
LogLevel INFO
EOF
  chmod 644 "$SSHD_CONF"
  mkdir -p /run/sshd
  "$(sshd_bin)" -t -f "$SSHD_CONF" || err "sshd config test failed (${SSHD_CONF})"
}

write_kharej_service() {
  local sshd
  sshd="$(sshd_bin)" || err "sshd not found"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=SSH tunnel (kharej): dedicated sshd on port ${SSH_PORT}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStartPre=/bin/mkdir -p /run/sshd
ExecStartPre=-/bin/bash ${INSTALL_DIR}/install.sh fw-add
ExecStartPre=${sshd} -t -f ${SSHD_CONF}
ExecStart=${sshd} -D -e -f ${SSHD_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

make_code() {
  local hostkey key_b64
  hostkey="$(cut -d' ' -f1,2 "${HOST_KEY}.pub")"
  key_b64="$(base64 -w0 <"$CLIENT_KEY")"
  printf 'SSHTUN1\nHOST=%s\nPORT=%s\nUSER=%s\nPORTS=%s\nHOSTKEY=%s\nKEY=%s\n' \
    "$KHAREJ_IP" "$SSH_PORT" "$TUN_USER" "$PORTS" "$hostkey" "$key_b64" | base64 -w0
}

show_code() {
  load_env || { warn "Not installed."; return 0; }
  [[ "$SIDE" == "kharej" ]] || { warn "Connection code exists only on the Kharej server."; return 0; }
  echo
  echo -e "${CYN}Connection code${NC} (copy the whole line, then on Iran: install -> 1) Iran -> paste)"
  echo "  کد اتصال — کل خط زیر را کپی و روی سرور ایران وارد کنید:"
  echo
  echo -e "${GRN}$(make_code)${NC}"
  echo
  echo "  Kharej ${KHAREJ_IP}:${SSH_PORT} | user ${TUN_USER} | allowed ports: ${PORTS}"
  echo -e "  ${YLW}Keep it secret: it contains the tunnel private key (forwarding-only).${NC}"
}

install_kharej() {
  local this_ip old_side="" tmp own
  load_env && old_side="$SIDE"
  echo
  echo -e "${CYN}SSH Tunnel — Kharej (server)${NC}"
  echo "  Dedicated sshd (own port / host key / unit / user '${TUN_USER_DEFAULT}'), key-only, forwarding-only."
  echo "  Does NOT touch the main sshd (port 22), root keys or WaterWall/x-ui services."
  echo

  ensure_deps kharej
  if [[ -n "$old_side" && "$old_side" != "kharej" ]]; then
    warn "This server was set up as '${old_side}' — it will be converted to Kharej."
    cleanup_old_fw
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
    load_env
  fi

  this_ip="$(detect_public_ip || true)"
  tmp="${IN_KHAREJ_IP:-${KHAREJ_IP:-$this_ip}}"
  ask KHAREJ_IP "Kharej public IP (used in the connection code)" "$tmp"
  validate_host "$KHAREJ_IP" || err "Invalid Kharej IP/host"

  own="$(service_pid)"
  tmp="${IN_SSH_PORT:-${SSH_PORT:-$DEFAULT_SSH_PORT}}"
  while true; do
    ask SSH_PORT "Tunnel SSH port (NOT 22)" "$tmp"
    validate_port "$SSH_PORT" || err "Invalid port"
    [[ "$SSH_PORT" != "22" ]] || { warn "22 is the main sshd — choose another."; tmp="$DEFAULT_SSH_PORT"; [[ "$HAVE_TTY" == 1 ]] || err "Port 22 not allowed"; continue; }
    check_busy_ports "$SSH_PORT" "$own" >/dev/null
    if [[ -n "$BUSY_PORTS" ]]; then
      warn "Port ${SSH_PORT} is already in use:"
      check_busy_ports "$SSH_PORT" "$own"
      [[ "$HAVE_TTY" == 1 ]] || err "SSH port ${SSH_PORT} busy"
      tmp=""
      continue
    fi
    break
  done

  tmp="${IN_PORTS:-${PORTS:-$DEFAULT_PORTS}}"
  echo "Ports Iran may forward to this server's 127.0.0.1 (panel/xray inbound ports), space/comma separated"
  ask PORTS "Ports" "$tmp"
  PORTS="$(normalize_ports "$PORTS")"
  validate_ports "$PORTS" || err "Invalid ports"
  local p none=""
  for p in $PORTS; do
    [[ -n "$(ss -lntH "sport = :$p" 2>/dev/null)" ]] || none+="$p "
  done
  [[ -n "$none" ]] && warn "Nothing listens yet on: ${none}(tunnel will work once your panel/inbound listens there)"

  TUN_USER="$TUN_USER_DEFAULT"
  if [[ -f "$CLIENT_KEY" && "$HAVE_TTY" == 1 ]]; then
    if ! confirm "Keep existing keys (old connection code stays valid)?" Y; then
      rm -f "$CLIENT_KEY" "${CLIENT_KEY}.pub" "$HOST_KEY" "${HOST_KEY}.pub"
    fi
  fi

  [[ -n "$old_side" ]] && cleanup_old_fw
  ensure_tunnel_user
  ensure_kharej_keys
  write_kharej_access
  UFW_ADDED=""
  ufw_add "$SSH_PORT"
  write_env
  save_self
  write_menu_wrapper
  write_kharej_service
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Kharej sshd is running on port ${SSH_PORT}"
  else
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null
    err "Service failed to start"
  fi
  echo "  Cloud firewall / security group: allow TCP ${SSH_PORT} inbound."
  show_code
  echo
  echo "  menu     : sshtun"
  echo "  next     : run the same one-liner on Iran -> 1) Install Iran -> paste the code"
}

# ---------------- iran ----------------
DEC_HOST=""; DEC_PORT=""; DEC_USER=""; DEC_PORTS=""; DEC_HOSTKEY=""; DEC_KEY=""
decode_code() {
  local raw
  raw="$(printf '%s' "$1" | tr -d ' \r\n\t' | base64 -d 2>/dev/null)" || return 1
  [[ "$(head -n1 <<<"$raw")" == "SSHTUN1" ]] || return 1
  DEC_HOST="$(sed -n 's/^HOST=//p' <<<"$raw" | head -n1)"
  DEC_PORT="$(sed -n 's/^PORT=//p' <<<"$raw" | head -n1)"
  DEC_USER="$(sed -n 's/^USER=//p' <<<"$raw" | head -n1)"
  DEC_PORTS="$(sed -n 's/^PORTS=//p' <<<"$raw" | head -n1)"
  DEC_HOSTKEY="$(sed -n 's/^HOSTKEY=//p' <<<"$raw" | head -n1)"
  DEC_KEY="$(sed -n 's/^KEY=//p' <<<"$raw" | head -n1)"
  validate_host "$DEC_HOST" || return 1
  validate_port "$DEC_PORT" || return 1
  [[ "$DEC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  validate_ports "$DEC_PORTS" || return 1
  [[ "$DEC_HOSTKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+$ ]] || return 1
  [[ "$DEC_KEY" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  return 0
}

pick_ciphers() {
  if grep -qw aes /proc/cpuinfo 2>/dev/null; then
    echo "aes128-gcm@openssh.com,chacha20-poly1305@openssh.com"
  else
    echo "chacha20-poly1305@openssh.com,aes128-gcm@openssh.com"
  fi
}

build_fwd() {
  local p out=""
  for p in $1; do out+="-L 0.0.0.0:${p}:127.0.0.1:${p} "; done
  xargs <<<"$out"
}

warn_not_allowed() {
  local p k found bad=""
  [[ -n "${KH_PORTS:-}" ]] || return 0
  for p in $1; do
    found=0
    for k in $KH_PORTS; do [[ "$p" == "$k" ]] && found=1; done
    ((found)) || bad+="$p "
  done
  [[ -n "$bad" ]] && warn "Not allowed on Kharej (PermitOpen): ${bad}— add them on Kharej: sshtun -> Edit ports"
  return 0
}

write_iran_service() {
  local ssh
  ssh="$(command -v ssh)" || err "ssh not found"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=SSH tunnel (iran): port-forward to ${KHAREJ_IP}:${SSH_PORT}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
EnvironmentFile=${CONF_ENV}
ExecStartPre=-/bin/bash ${INSTALL_DIR}/install.sh fw-add
ExecStart=${ssh} -F /dev/null -N -T -p ${SSH_PORT} -i ${IRAN_KEY} \\
  -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null \\
  -o StrictHostKeyChecking=yes -o BatchMode=yes -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o ConnectTimeout=10 \\
  -o Compression=no -o Ciphers=\${CIPHERS} \\
  \$FWD ${TUN_USER}@${KHAREJ_IP}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

verify_iran() {
  local p up="" down=""
  sleep 3
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null
    warn "Tunnel is not running yet (it keeps retrying). Check: sshtun -> Status / Logs"
    return 1
  fi
  for p in $PORTS; do
    if ss -lntpH "sport = :$p" 2>/dev/null | grep -q '"ssh"'; then up+="$p "; else down+="$p "; fi
  done
  [[ -n "$up" ]] && ok "Listening on 0.0.0.0: ${up}"
  if [[ -n "$down" ]]; then
    warn "Not listening yet: ${down}"
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null
    return 1
  fi
  return 0
}

install_iran() {
  local code="" old_side="" keep=0 tmp own i
  load_env && old_side="$SIDE"
  echo
  echo -e "${CYN}SSH Tunnel — Iran (client)${NC}"
  echo "  ssh -L 0.0.0.0:PORT -> kharej 127.0.0.1:PORT for each port (systemd, auto-reconnect)."
  echo "  Busy ports (x-ui / WaterWall / nginx ...) are detected and skipped."
  echo

  ensure_deps iran
  if [[ -n "$old_side" && "$old_side" != "iran" ]]; then
    warn "This server was set up as '${old_side}' — it will be converted to Iran."
    cleanup_old_fw
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
    [[ -n "${TUN_USER:-}" ]] && id -u "$TUN_USER" >/dev/null 2>&1 && userdel "$TUN_USER" >/dev/null 2>&1
    load_env
    old_side=""
  fi

  code="$IN_CODE"
  if [[ -z "$code" && "$old_side" == "iran" && -f "$IRAN_KEY" ]]; then
    if [[ "$HAVE_TTY" != 1 ]] || confirm "Keep current connection (Kharej ${KHAREJ_IP}:${SSH_PORT})?" Y; then
      keep=1
    fi
  fi

  if ((keep == 0)); then
    for i in 1 2 3; do
      if [[ -z "$code" ]]; then
        echo "Paste the connection code from Kharej (sshtun -> Show connection code)"
        echo "  کد اتصال سرور خارج را وارد کنید:"
        read_tty -r -p "Code: " code || err "No code given (use CODE=... for non-interactive)"
      fi
      decode_code "$code" && break
      warn "Invalid connection code."
      [[ "$HAVE_TTY" == 1 ]] || err "Invalid CODE"
      code=""
      ((i == 3)) && err "Invalid connection code"
    done
    KHAREJ_IP="$DEC_HOST"; SSH_PORT="$DEC_PORT"; TUN_USER="$DEC_USER"; KH_PORTS="$DEC_PORTS"
    ok "Code OK: Kharej ${KHAREJ_IP}:${SSH_PORT}, allowed ports: ${KH_PORTS}"
  fi

  tmp="${IN_PORTS:-${PORTS:-${KH_PORTS:-$DEFAULT_PORTS}}}"
  echo "PUBLIC ports to forward from Iran 0.0.0.0 (space/comma separated)"
  local sel
  ask sel "Ports" "$tmp"
  sel="$(normalize_ports "$sel")"
  validate_ports "$sel" || err "Invalid ports"
  warn_not_allowed "$sel"

  own="$(service_pid)"
  filter_busy_ports "$sel" "$own"

  if ! timeout 6 bash -c "exec 3<>/dev/tcp/${KHAREJ_IP}/${SSH_PORT}" 2>/dev/null; then
    warn "Cannot reach ${KHAREJ_IP}:${SSH_PORT} right now (firewall/filter?). The service will keep retrying."
  fi

  [[ -n "$old_side" ]] && cleanup_old_fw
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR"
  if ((keep == 0)); then
    base64 -d <<<"$DEC_KEY" >"$IRAN_KEY" 2>/dev/null || err "Bad key in code"
    chmod 600 "$IRAN_KEY"
    ssh-keygen -y -f "$IRAN_KEY" >"${IRAN_KEY}.pub" 2>/dev/null || err "Bad key in code"
    if [[ "$SSH_PORT" == "22" ]]; then
      echo "${KHAREJ_IP} ${DEC_HOSTKEY}" >"$KNOWN_HOSTS"
    else
      echo "[${KHAREJ_IP}]:${SSH_PORT} ${DEC_HOSTKEY}" >"$KNOWN_HOSTS"
    fi
    chmod 644 "$KNOWN_HOSTS"
  fi

  SIDE="iran"
  PORTS="$FREE_PORTS"
  CIPHERS="$(pick_ciphers)"
  FWD="$(build_fwd "$PORTS")"
  UFW_ADDED=""
  ufw_add "$PORTS"
  write_env
  save_self
  write_menu_wrapper
  write_iran_service
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  verify_iran
  echo
  echo "  menu     : sshtun"
  echo "  kharej   : ${KHAREJ_IP}:${SSH_PORT}"
  echo "  ports    : ${PORTS}"
  echo "  clients connect to THIS (Iran) server IP on these ports."
}

# ---------------- management ----------------
show_status() {
  load_env || { warn "Not installed. Run: 1) Install Iran  or  2) Install Kharej"; return 0; }
  local state p line n
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
  echo
  echo -e "${CYN}SSH Tunnel status${NC}"
  echo "  side     : ${SIDE}"
  if [[ "$state" == "active" ]]; then
    echo -e "  service  : ${GRN}${state}${NC} (${SERVICE_NAME})"
  else
    echo -e "  service  : ${RED}${state:-unknown}${NC} (${SERVICE_NAME})"
  fi
  if [[ "$SIDE" == "kharej" ]]; then
    n="$(ss -tnH state established "sport = :${SSH_PORT}" 2>/dev/null | wc -l)"
    echo "  listen   : 0.0.0.0:${SSH_PORT}  (connected clients: ${n})"
    echo "  user     : ${TUN_USER}"
    echo "  allowed  : ${PORTS}"
    for p in $PORTS; do
      line="$(ss -lntpH "sport = :$p" 2>/dev/null | head -n1 | awk '{print $4, $6}')"
      echo "    ${p} -> ${line:-(nothing listening on kharej)}"
    done
  else
    echo "  kharej   : ${KHAREJ_IP}:${SSH_PORT} (user ${TUN_USER})"
    echo "  cipher   : ${CIPHERS}"
    for p in $PORTS; do
      if ss -lntpH "sport = :$p" 2>/dev/null | grep -q '"ssh"'; then
        echo -e "    0.0.0.0:${p}  ${GRN}listening${NC}"
      else
        echo -e "    0.0.0.0:${p}  ${RED}down${NC}"
      fi
    done
    n="$(ss -tnH state established "dport = :${SSH_PORT}" 2>/dev/null | grep -c "${KHAREJ_IP}")"
    echo "  ssh link : ${n} established"
  fi
  echo
  echo "Recent logs:"
  journalctl -u "$SERVICE_NAME" -n 6 --no-pager -o short-iso 2>/dev/null | sed 's/^/  /'
}

show_logs() {
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager -o short-iso 2>/dev/null || warn "No logs"
}

restart_tunnel() {
  load_env || { warn "Not installed."; return 0; }
  systemctl restart "$SERVICE_NAME"
  sleep 2
  show_status
}

change_ports() {
  load_env || { warn "Not installed."; return 0; }
  local sel own
  echo "Current ports: ${PORTS}"
  if [[ "$SIDE" == "kharej" ]]; then
    echo "Ports Iran may forward (PermitOpen), space/comma separated"
    ask sel "Ports" "${IN_PORTS:-$PORTS}"
    sel="$(normalize_ports "$sel")"
    validate_ports "$sel" || err "Invalid ports"
    PORTS="$sel"
    write_kharej_access
    write_env
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      ok "Allowed ports: ${PORTS}"
    else
      warn "Service not active — check logs"
    fi
    echo "  Then on Iran: sshtun -> Edit ports (the old code still works; new code below includes new ports)."
    show_code
  else
    [[ -n "$KH_PORTS" ]] && echo "Allowed by Kharej: ${KH_PORTS}"
    echo "PUBLIC ports to forward from Iran 0.0.0.0 (space/comma separated)"
    ask sel "Ports" "${IN_PORTS:-$PORTS}"
    sel="$(normalize_ports "$sel")"
    validate_ports "$sel" || err "Invalid ports"
    warn_not_allowed "$sel"
    own="$(service_pid)"
    filter_busy_ports "$sel" "$own"
    cleanup_old_fw
    UFW_ADDED=""
    PORTS="$FREE_PORTS"
    FWD="$(build_fwd "$PORTS")"
    ufw_add "$PORTS"
    write_env
    systemctl restart "$SERVICE_NAME"
    verify_iran
  fi
}

uninstall_all() {
  if [[ ! -f "$CONF_ENV" && ! -f "$UNIT_FILE" && ! -d "$INSTALL_DIR" && ! -f "$BIN_LINK" ]]; then
    warn "Nothing to uninstall."
    return 0
  fi
  if [[ "$HAVE_TTY" == 1 ]]; then
    confirm "Remove SSH tunnel completely (service, dedicated sshd, keys, firewall rules, sshtun, ${INSTALL_DIR})?" N || { echo "Cancelled."; return 0; }
  fi
  load_env
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  fw_del
  ufw_del
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  if [[ "$SIDE" == "kharej" ]] && id -u "${TUN_USER:-$TUN_USER_DEFAULT}" >/dev/null 2>&1; then
    userdel "${TUN_USER:-$TUN_USER_DEFAULT}" >/dev/null 2>&1 || true
  fi
  rm -rf "$INSTALL_DIR"
  rm -f "$BIN_LINK"
  ok "SSH tunnel removed (main sshd, WaterWall and other services untouched)."
}

menu() {
  local this_ip="" c role
  while true; do
    clear 2>/dev/null || true
    this_ip="$(detect_public_ip || true)"
    role="not installed"
    load_env && role="${SIDE} ($(systemctl is-active "$SERVICE_NAME" 2>/dev/null))"
    echo -e "${CYN}SSH Tunnel (port-forward over SSH)${NC}"
    echo "========================="
    if [[ -n "${this_ip:-}" ]]; then
      echo -e "This server IP: ${GRN}${this_ip}${NC}"
    else
      echo "This server IP: (auto-detect failed)"
    fi
    echo "Installed as : ${role}"
    echo
    echo "1) Install Iran   (client)   — run AFTER Kharej, needs the code"
    echo "2) Install Kharej (server)   — run FIRST, prints the code"
    echo "3) Status"
    echo "4) Restart"
    echo "5) Edit ports"
    echo "6) Show tunnel logs"
    echo "7) Show connection code (Kharej)"
    echo "8) Uninstall"
    echo "0) Exit"
    echo
    read_tty -r -p "Select: " c || exit 0
    case "$c" in
      1) (install_iran) ;;
      2) (install_kharej) ;;
      3) show_status ;;
      4) restart_tunnel ;;
      5) (change_ports) ;;
      6) show_logs ;;
      7) show_code ;;
      8) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo
    read_tty -r -p "Press Enter to continue..." _ || true
  done
}

main() {
  need_root
  case "${1:-}" in
    install-iran|iran) install_iran ;;
    install-kharej|kharej) install_kharej ;;
    status) show_status ;;
    restart) restart_tunnel ;;
    ports|edit) change_ports ;;
    logs) show_logs ;;
    code) show_code ;;
    uninstall|remove) uninstall_all ;;
    fw-add) load_env && fw_add ;;
    fw-del) load_env && fw_del ;;
    *)
      if [[ "$HAVE_TTY" == 1 ]]; then
        menu
      else
        err "No TTY. Use: bash -s -- install-kharej | install-iran | status | uninstall"
      fi
      ;;
  esac
}

main "$@"
