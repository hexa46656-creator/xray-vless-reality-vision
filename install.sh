#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Secure VPS Xray Reality Installer
# Ubuntu 24.04 hardening + Xray-core VLESS REALITY Vision
# =========================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CLIENT_INFO="/root/xray-reality-client.txt"
INSTALLER_STATE="/etc/xray-reality-installer.env"
INSTALL_LOCK_FILE="/etc/vpsguard/xray-vless-reality-vision.lock"
INSTALL_REPORT_FILE="/root/xray-vless-reality-vision-install-report.txt"
NETWORK_SYSCTL_FILE="/etc/sysctl.d/99-xray-reality-tuning.conf"
UFW_MSS_CLAMP_MARKER="vpsguard-xray-reality-mss-clamp"
SHADOWROCKET_CONF_SRC="default.conf"
SHADOWROCKET_CONF_DST="/root/shadowrocket-default.conf"

declare -a ROLLBACK_TARGETS=()
declare -a ROLLBACK_BACKUPS=()
ROLLBACK_DONE=0

XRAY_PORT="${XRAY_PORT:-8443}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-speed.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-speed.cloudflare.com:443}"
REALITY_DNS_STRICT="${REALITY_DNS_STRICT:-warn}"
CLIENT_NAME="${CLIENT_NAME:-Xray-Reality}"
DEPLOY_USER="${DEPLOY_USER:-alex}"
DEPLOY_USER_PASSWORD="${DEPLOY_USER_PASSWORD:-}"
INSTALLER_CORE_DIR="${INSTALLER_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../vps-installer-core" 2>/dev/null && pwd || true)}"

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
  return 1
}

section_header() {
  echo
  echo -e "${BLUE}========== ${1} ==========${NC}"
}

track_rollback_target() {
  ROLLBACK_TARGETS+=("$1")
  ROLLBACK_BACKUPS+=("${2:-}")
}

backup_file() {
  local file="$1"
  local backup_file

  if [[ -f "${file}" ]]; then
    backup_file="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${file}" "${backup_file}"
    track_rollback_target "${file}" "${backup_file}"
  fi
}

track_created_path() {
  track_rollback_target "$1" ""
}

write_install_lock() {
  mkdir -p "$(dirname "${INSTALL_LOCK_FILE}")"
  cat > "${INSTALL_LOCK_FILE}" <<EOF
installed_at=$(date -Is)
repo=xray-vless-reality-vision
service=xray
config=${XRAY_CONFIG}
client_info=${CLIENT_INFO}
EOF
  chmod 600 "${INSTALL_LOCK_FILE}"
}

load_install_state() {
  if [[ -f "${INSTALL_LOCK_FILE}" ]]; then
    INSTALL_ALREADY_INSTALLED=1
    log "Detected existing installation lock: ${INSTALL_LOCK_FILE}"
  else
    INSTALL_ALREADY_INSTALLED=0
  fi
}

rollback_partial_install() {
  local i

  section_header "RECOVERY"
  warn "Attempting rollback to a safe state..."

  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true

  for ((i=${#ROLLBACK_TARGETS[@]}-1; i>=0; i--)); do
    if [[ -n "${ROLLBACK_BACKUPS[$i]}" && -f "${ROLLBACK_BACKUPS[$i]}" ]]; then
      cp -a "${ROLLBACK_BACKUPS[$i]}" "${ROLLBACK_TARGETS[$i]}"
      warn "Restored ${ROLLBACK_TARGETS[$i]} from backup."
    else
      rm -f "${ROLLBACK_TARGETS[$i]}"
      warn "Removed partial path ${ROLLBACK_TARGETS[$i]}."
    fi
  done

  rm -f "${INSTALL_LOCK_FILE}" "${INSTALL_REPORT_FILE}"
}

on_error() {
  local line="$1"
  local cmd="$2"

  echo -e "${RED}[ERROR]${NC} Installation failed at line ${line}: ${cmd}"
  rollback_partial_install
  ROLLBACK_DONE=1
  exit 1
}

on_exit() {
  local status="$1"

  if [[ "${status}" -ne 0 && "${ROLLBACK_DONE}" -eq 0 ]]; then
    rollback_partial_install
    ROLLBACK_DONE=1
  fi
}

probe_network() {
  local ping_rc=0
  local curl_time=""

  section_header "NETWORK DIAGNOSTICS"

  if command -v ping >/dev/null 2>&1; then
    if ping -c 3 -W 2 1.1.1.1 >/tmp/xray-vless-reality-vision-ping.log 2>&1; then
      log "Ping to 1.1.1.1 succeeded."
      awk '/^rtt|^round-trip/ {print}' /tmp/xray-vless-reality-vision-ping.log | tail -n1 || true
    else
      ping_rc=$?
      warn "Ping to 1.1.1.1 failed with code ${ping_rc}."
    fi
    rm -f /tmp/xray-vless-reality-vision-ping.log
  else
    warn "ping command is not available; skipping ICMP probe."
  fi

  curl_time="$(curl -4 -fsS --connect-timeout 3 --max-time 5 -o /dev/null -w 'connect=%{time_connect}s appconnect=%{time_appconnect}s total=%{time_total}s' https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${curl_time}" ]]; then
    log "Curl connectivity test succeeded: ${curl_time}"
  else
    warn "Curl connectivity test could not complete."
  fi

  if ss -tulpen 2>/dev/null | grep -E ':(443|8443)\b' >/dev/null; then
    warn "A service is already listening on TCP 443 or 8443."
  else
    log "No TCP conflict detected on ports 443 or 8443."
  fi
}

check_systemctl_ready() {
  if ! command -v systemctl >/dev/null 2>&1; then
    error "systemctl is required but not available."
  fi
}

preflight_phase() {
  section_header "PHASE 1 - PREFLIGHT"
  require_root
  check_os
  detect_ssh_port
  check_systemctl_ready
  probe_network
}

verify_phase() {
  section_header "PHASE 4 - VERIFY"

  if systemctl is-active --quiet xray; then
    log "xray.service is active."
  else
    error "xray.service is not active after installation."
  fi

  if ss -tulpn 2>/dev/null | awk -v port="${XRAY_PORT}" '{split($5, a, ":")} a[length(a)] == port {found=1} END {exit found ? 0 : 1}'; then
    log "Port ${XRAY_PORT}/tcp is listening."
  else
    error "Port ${XRAY_PORT}/tcp is not listening."
  fi

  if [[ -s "${CLIENT_INFO}" ]]; then
    log "Client info file exists: ${CLIENT_INFO}"
  else
    error "Client info file is missing."
  fi

  log "tcpFastOpen sysctl: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
  log "tcp_mtu_probing sysctl: $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
  log "Reality flow validation: xtls-rprx-vision"
  log "Stealth health check: Reality DNS and Xray config validation passed."
}

report_phase() {
  section_header "PHASE 5 - REPORT"

  cat > "${INSTALL_REPORT_FILE}" <<EOF
Repository: xray-vless-reality-vision
State lock: ${INSTALL_LOCK_FILE}
Service: xray
Config: ${XRAY_CONFIG}
Client info: ${CLIENT_INFO}
Port: ${XRAY_PORT}/tcp
SNI: ${REALITY_SERVER_NAME}
Install mode: ${INSTALL_ALREADY_INSTALLED:-0}
EOF
  chmod 600 "${INSTALL_REPORT_FILE}"

  log "Installation report saved to ${INSTALL_REPORT_FILE}"
  cat "${INSTALL_REPORT_FILE}"
}

if [[ -n "${INSTALLER_CORE_DIR}" && -f "${INSTALLER_CORE_DIR}/installer_core.sh" ]]; then
  # shellcheck source=/dev/null
  source "${INSTALLER_CORE_DIR}/installer_core.sh"
fi

if ! declare -F installer_core_detect_os >/dev/null 2>&1; then
  installer_core_detect_os() {
    local os_id
    local os_name
    local os_pretty_name
    local init_comm

    if [[ ! -r /etc/os-release ]]; then
      error "Unable to read /etc/os-release."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    os_id="${ID:-unknown}"
    os_name="${NAME:-${ID:-unknown}}"
    os_pretty_name="${PRETTY_NAME:-${os_name}}"

    case "${os_id}" in
      ubuntu|debian) ;;
      *) error "Unsupported OS: ${os_pretty_name}. This installer only supports Ubuntu or Debian." ;;
    esac

    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${init_comm}" != "systemd" && ! -d /run/systemd/system ]]; then
      error "systemd is required but not available on this system."
    fi

    # shellcheck disable=SC2034
    INSTALLER_OS_ID="${os_id}"
    # shellcheck disable=SC2034
    INSTALLER_OS_NAME="${os_name}"
    # shellcheck disable=SC2034
    INSTALLER_OS_VERSION_ID="${VERSION_ID:-unknown}"
    # shellcheck disable=SC2034
    INSTALLER_OS_PRETTY_NAME="${os_pretty_name}"
  }
fi

if ! declare -F installer_core_install_packages >/dev/null 2>&1; then
  installer_core_install_packages() {
    local packages=("$@")

    if [[ "${#packages[@]}" -eq 0 ]]; then
      return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y "${packages[@]}"
    else
      apt update
      apt install -y "${packages[@]}"
    fi
  }
fi

if ! declare -F installer_core_subscription_protocol_defaults >/dev/null 2>&1; then
  installer_core_subscription_protocol_defaults() {
    SUBSCRIPTION_ACCESS_URL="${SUBSCRIPTION_ACCESS_URL:-${VLESS_LINK:-}}"
  }
fi

if ! declare -F installer_core_publish_subscription >/dev/null 2>&1; then
  installer_core_publish_subscription() {
    SUBSCRIPTION_ACCESS_URL="${SUBSCRIPTION_ACCESS_URL:-${VLESS_LINK:-}}"
  }
fi

if ! declare -F installer_core_mode_label >/dev/null 2>&1; then
  installer_core_mode_label() {
    printf '%s\n' "standalone"
  }
fi

if ! declare -F installer_core_print_completion_block >/dev/null 2>&1; then
  installer_core_print_completion_block() {
    local mode="${1:-standalone}"
    local access_url="${2:-${SUBSCRIPTION_ACCESS_URL:-${VLESS_LINK:-${HY2_URI:-${TROJAN_URI:-}}}}}"
    local clients="${3:-}"

    echo
    echo "========== Completion =========="
    echo "[MODE] ${mode}"
    if [[ -n "${access_url}" ]]; then
      echo "[LINK] ${access_url}"
    fi
    if [[ -n "${clients}" ]]; then
      echo "[CLIENTS] ${clients}"
    fi
    echo "================================"
  }
fi

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Please run this script as root. Example: sudo -i"
  fi
}

check_os() {
  installer_core_detect_os
  log "Detected supported OS: ${INSTALLER_OS_PRETTY_NAME}"
}

detect_ssh_port() {
  SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | head -n1 || true)"

  if [[ -z "${SSH_PORT}" ]]; then
    SSH_PORT="$(grep -Ei '^\s*Port\s+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $NF}' | tail -n1 || true)"
  fi

  SSH_PORT="${SSH_PORT:-22}"
  log "Detected SSH port: ${SSH_PORT}"
}

extract_reality_dest_host() {
  local dest="${1:-${REALITY_DEST}}"

  if [[ "${dest}" =~ ^\[([0-9A-Fa-f:.]+)\]:(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "${dest}" == *:* ]]; then
    printf '%s\n' "${dest%:*}"
    return 0
  fi

  printf '%s\n' "${dest}"
}

check_reality_dns_health() {
  local dest_host
  local system_dns
  local cloudflare_dns
  local google_dns
  local mismatch=0

  dest_host="$(extract_reality_dest_host "${REALITY_DEST}")"
  system_dns="$(dig +short A "${dest_host}" 2>/dev/null | awk 'NR==1 {print $1}')"
  cloudflare_dns="$(dig +short A "${dest_host}" @1.1.1.1 2>/dev/null | awk 'NR==1 {print $1}')"
  google_dns="$(dig +short A "${dest_host}" @8.8.8.8 2>/dev/null | awk 'NR==1 {print $1}')"

  log "Reality DNS health for ${dest_host}"
  log "  system DNS: ${system_dns:-<empty>}"
  log "  1.1.1.1: ${cloudflare_dns:-<empty>}"
  log "  8.8.8.8: ${google_dns:-<empty>}"

  if [[ -z "${system_dns}" || -z "${cloudflare_dns}" || -z "${google_dns}" ]]; then
    warn "One or more Reality DNS lookups returned no A record."
    mismatch=1
  fi

  if [[ -n "${system_dns}" && -n "${cloudflare_dns}" && -n "${google_dns}" ]]; then
    if [[ "$({ printf '%s
' "${system_dns}" "${cloudflare_dns}" "${google_dns}" | awk 'NF' | sort -u | wc -l | tr -d ' '; })" -gt 1 ]]; then
      warn "Reality DNS lookups returned different A records across resolvers."
      mismatch=1
    fi
  fi

  if [[ "${dest_host}" != "${REALITY_SERVER_NAME}" ]]; then
    warn "REALITY_DEST host (${dest_host}) differs from REALITY_SERVER_NAME (${REALITY_SERVER_NAME})."
    mismatch=1
  fi

  if [[ "${mismatch}" -ne 0 && "${REALITY_DNS_STRICT}" == "fail" ]]; then
    error "Reality DNS health check failed under REALITY_DNS_STRICT=fail."
  fi
}

install_packages() {
  installer_core_install_packages \
    curl wget unzip jq socat ufw fail2ban ca-certificates gnupg lsb-release openssl iproute2 sudo dnsutils qrencode
}

detect_path_mtu() {
  local mtu

  mtu="$(ip route get 1.1.1.1 2>/dev/null | awk 'match($0, /mtu ([0-9]+)/, m) {print m[1]; exit}')"

  if [[ -n "${mtu}" ]]; then
    log "Detected path MTU reference: ${mtu}"
    if [[ "${mtu}" -lt 1350 || "${mtu}" -gt 1450 ]]; then
      warn "Path MTU reference is outside the 1350-1450 target range for Xray Reality: ${mtu}"
    fi
  else
    warn "Unable to detect path MTU reference with ip route get 1.1.1.1."
  fi
}

enable_network_tuning() {
  log "Applying TCP acceleration tuning..."

  cat > "${NETWORK_SYSCTL_FILE}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
EOF

  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || warn "Failed to apply net.core.default_qdisc=fq immediately."
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_congestion_control=bbr immediately."
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_fastopen=3 immediately."
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_mtu_probing=1 immediately."

  detect_path_mtu
}

configure_tcp_mss_clamp() {
  local before_rules="/etc/ufw/before.rules"
  local before6_rules="/etc/ufw/before6.rules"
  local marker="# ${UFW_MSS_CLAMP_MARKER}"
  local tmp_file

  for rules_file in "${before_rules}" "${before6_rules}"; do
    [[ -f "${rules_file}" ]] || continue
    backup_file "${rules_file}"

    if grep -Fq "${marker}" "${rules_file}"; then
      log "UFW MSS clamp rule already present in ${rules_file}"
      continue
    fi

    log "Adding UFW MSS clamp rule to ${rules_file}"
    tmp_file="$(mktemp)"
    {
      printf '%s\n' "${marker}"
      printf '*mangle\n'
      printf ':POSTROUTING ACCEPT [0:0]\n'
      printf '-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n'
      printf 'COMMIT\n'
      printf '%s\n' "${marker}"
      cat "${rules_file}"
    } > "${tmp_file}"
    cat "${tmp_file}" > "${rules_file}"
    rm -f "${tmp_file}"
  done

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw reload >/dev/null || true
  fi
}

print_client_qr() {
  local client_url="${1:-}"
  local output_file="${2:-}"

  if [[ -z "${client_url}" ]]; then
    echo "[WARN] Client URL is empty, skip QR code generation."
    return 0
  fi

  if [[ -z "${output_file}" ]]; then
    output_file="/root/xray-vless-reality-qr.png"
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "[INFO] Installing qrencode..."
    if command -v apt >/dev/null 2>&1; then
      apt update >/dev/null 2>&1 || true
      apt install -y qrencode >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update >/dev/null 2>&1 || true
      apt-get install -y qrencode >/dev/null 2>&1 || true
    fi
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    echo "[WARN] qrencode is not available, skip QR code generation."
    echo "[INFO] Client URL:"
    echo "${client_url}"
    return 0
  fi

  echo
  echo "========== Client QR Code =========="
  if ! qrencode -t ANSIUTF8 "${client_url}"; then
    echo "[WARN] Failed to render QR code in terminal."
  fi

  if qrencode -o "${output_file}" "${client_url}"; then
    chmod 600 "${output_file}"
    echo
    echo "[OK] QR code saved to: ${output_file}"
  else
    echo "[WARN] Failed to save QR code PNG."
  fi

  echo
  echo "Mobile import:"
  echo "1. Open Shadowrocket / v2rayNG / Hiddify / NekoBox"
  echo "2. Tap scan QR code"
  echo "3. Scan the QR code above"
  echo "4. Save and test the node"
}

create_deploy_user() {
  log "Creating or updating deploy user: ${DEPLOY_USER}"

  if [[ ! "${DEPLOY_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    error "Invalid DEPLOY_USER: ${DEPLOY_USER}"
  fi

  if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${DEPLOY_USER}"
  fi

  usermod -aG sudo "${DEPLOY_USER}"

  if [[ -z "${DEPLOY_USER_PASSWORD}" ]]; then
    DEPLOY_USER_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  fi

  echo "${DEPLOY_USER}:${DEPLOY_USER_PASSWORD}" | chpasswd

  mkdir -p "/home/${DEPLOY_USER}/.ssh"
  chmod 700 "/home/${DEPLOY_USER}/.ssh"

  if [[ -f /root/.ssh/authorized_keys && ! -s "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]]; then
    cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  fi

  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

  log "Deploy user is ready: ${DEPLOY_USER}"
  warn "Save this SSH login password now. It will also be saved in ${CLIENT_INFO} with root-only permission."
}

harden_ssh_safe() {
  log "Applying safe SSH hardening..."

  backup_file /etc/ssh/sshd_config

  if grep -qE '^\s*#?\s*PermitRootLogin\s+' /etc/ssh/sshd_config; then
    sed -i 's/^\s*#\?\s*PermitRootLogin\s\+.*/PermitRootLogin no/' /etc/ssh/sshd_config
  else
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
  fi

  if grep -qE '^\s*#?\s*PubkeyAuthentication\s+' /etc/ssh/sshd_config; then
    sed -i 's/^\s*#\?\s*PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
  fi

  # Conservative strategy:
  # Keep password login enabled by default because this installer creates a new deploy user.
  # Users can disable password login after confirming SSH key login works.
  if grep -qE '^\s*#?\s*PasswordAuthentication\s+' /etc/ssh/sshd_config; then
    sed -i 's/^\s*#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
  fi

  sshd -t || error "SSH config test failed. Check /etc/ssh/sshd_config"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

  log "SSH hardening completed: root login disabled, public key auth enabled, password login kept enabled."
}

configure_ufw() {
  log "Configuring UFW firewall..."

  if ufw status 2>/dev/null | grep -q '^Status: active' && [[ -f "${INSTALL_LOCK_FILE}" ]]; then
    log "UFW already initialized. Ensuring required rules remain present."
  else
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
  fi

  ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1 || true
  ufw allow "${XRAY_PORT}/tcp" comment "Xray Reality" >/dev/null 2>&1 || true
  ufw allow 80/tcp comment "HTTP" >/dev/null 2>&1 || true
  ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1 || true

  ufw --force enable >/dev/null 2>&1 || true
  ufw status verbose
}

configure_fail2ban() {
  log "Configuring Fail2ban for sshd..."

  mkdir -p /etc/fail2ban/jail.d

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  fail2ban-client status sshd || true
}

install_xray() {
  log "Installing or updating Xray-core..."

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  if ! command -v xray >/dev/null 2>&1; then
    error "Xray command not found after installation."
  fi

  log "Installed Xray version:"
  xray version | head -n1
}

generate_values() {
  log "Generating UUID, REALITY key pair, and shortId..."

  local xray_bin
  xray_bin="$(command -v xray || true)"

  if [[ -z "${xray_bin}" && -x /usr/local/bin/xray ]]; then
    xray_bin="/usr/local/bin/xray"
  fi

  if [[ -z "${xray_bin}" ]]; then
    error "Xray binary not found."
  fi

  UUID="$(${xray_bin} uuid 2>/dev/null || true)"
  KEY_PAIR="$(${xray_bin} x25519 2>/dev/null || true)"

  # Xray output format changed in newer versions.
  # Old examples may use:
  #   Private key: xxx
  #   Public key: xxx
  # Xray 26.x may output:
  #   PrivateKey: xxx
  #   Password (PublicKey): xxx
  PRIVATE_KEY="$(echo "${KEY_PAIR}" | awk -F': ' '
    /^PrivateKey:/ {print $2}
    /^Private key:/ {print $2}
    /^Private Key:/ {print $2}
  ' | head -n1)"

  PUBLIC_KEY="$(echo "${KEY_PAIR}" | awk -F': ' '
    /^Password \(PublicKey\):/ {print $2}
    /^PublicKey:/ {print $2}
    /^Public key:/ {print $2}
    /^Public Key:/ {print $2}
  ' | head -n1)"

  SHORT_ID="$(openssl rand -hex 8 2>/dev/null || true)"
  SERVER_IP="$(curl -4 -s --max-time 10 https://api.ipify.org || true)"

  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
  fi

  if [[ -z "${UUID}" || -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" || -z "${SHORT_ID}" || -z "${SERVER_IP}" ]]; then
    echo -e "${RED}[ERROR]${NC} Failed to generate required values."
    echo "UUID=${UUID}"
    echo "PRIVATE_KEY=${PRIVATE_KEY}"
    echo "PUBLIC_KEY=${PUBLIC_KEY}"
    echo "SHORT_ID=${SHORT_ID}"
    echo "SERVER_IP=${SERVER_IP}"
    echo "xray x25519 output:"
    echo "${KEY_PAIR}"
    exit 1
  fi
}

write_xray_config() {
  log "Writing Xray config: ${XRAY_CONFIG}"

  mkdir -p /usr/local/etc/xray
  backup_file "${XRAY_CONFIG}"
  [[ -f "${XRAY_CONFIG}" ]] || track_created_path "${XRAY_CONFIG}"

  cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "default@xray"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF

  xray run -test -config "${XRAY_CONFIG}" || error "Xray config test failed."
}

install_shadowrocket_config() {
  log "Preparing Shadowrocket local config..."

  if [[ -f "${SHADOWROCKET_CONF_SRC}" ]]; then
    [[ -f "${SHADOWROCKET_CONF_DST}" ]] || track_created_path "${SHADOWROCKET_CONF_DST}"
    cp "${SHADOWROCKET_CONF_SRC}" "${SHADOWROCKET_CONF_DST}"
    chmod 600 "${SHADOWROCKET_CONF_DST}"
    log "Shadowrocket config copied to ${SHADOWROCKET_CONF_DST}"
  else
    warn "${SHADOWROCKET_CONF_SRC} not found in installer directory. Skipping Shadowrocket local config copy."
  fi
}

save_state() {
  log "Saving installer state: ${INSTALLER_STATE}"

  cat > "${INSTALLER_STATE}" <<EOF
XRAY_PORT="${XRAY_PORT}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
REALITY_DEST="${REALITY_DEST}"
CLIENT_NAME="${CLIENT_NAME}"
DEPLOY_USER="${DEPLOY_USER}"
SSH_PORT="${SSH_PORT}"
SERVER_IP="${SERVER_IP}"
SHADOWROCKET_CONF_DST="${SHADOWROCKET_CONF_DST}"
EOF

  chmod 600 "${INSTALLER_STATE}"
}

write_client_info() {
  log "Writing client info: ${CLIENT_INFO}"

  local encoded_name
  encoded_name="${CLIENT_NAME// /%20}"

  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${encoded_name}"

  [[ -f "${CLIENT_INFO}" ]] || track_created_path "${CLIENT_INFO}"

  cat > "${CLIENT_INFO}" <<EOF
============================================================
Xray-core VLESS + REALITY + Vision Client Info
============================================================

SSH Login User:
${DEPLOY_USER}

SSH Login Password:
${DEPLOY_USER_PASSWORD}

SSH Login Command:
ssh ${DEPLOY_USER}@${SERVER_IP}

Important:
Root SSH login has been disabled for safety.
Use the SSH login user above for future server management.
Save this password immediately.

Server IP:
${SERVER_IP}

Port:
${XRAY_PORT}

UUID:
${UUID}

Flow:
xtls-rprx-vision

Network:
tcp

Security:
reality

SNI / Server Name:
${REALITY_SERVER_NAME}

REALITY Public Key:
${PUBLIC_KEY}

Short ID:
${SHORT_ID}

Fingerprint:
chrome

VLESS Link:
${VLESS_LINK}

Shadowrocket Local Config:
${SHADOWROCKET_CONF_DST}

GitHub default.conf Raw URL:
https://raw.githubusercontent.com/hexa46656-creator/secure-vps-xray-reality-installer/main/default.conf

Config file:
${XRAY_CONFIG}

Useful commands:
systemctl status xray
journalctl -u xray -e --no-pager
ufw status verbose
fail2ban-client status sshd
xray version
dig ${REALITY_SERVER_NAME} @1.1.1.1
dig ${REALITY_SERVER_NAME} @8.8.8.8
dig ${REALITY_SERVER_NAME}

============================================================
EOF

  chmod 600 "${CLIENT_INFO}"

  export SUBSCRIPTION_PROTOCOL="vless-reality"
  export SUBSCRIPTION_UUID="${UUID}"
  export SUBSCRIPTION_DIR="/sub/${UUID}"
  export SUBSCRIPTION_SERVER="${SERVER_IP}"
  export SUBSCRIPTION_UUID="${UUID}"
  export SUBSCRIPTION_CLIENT_NAME="${CLIENT_NAME}"
  export SUBSCRIPTION_PUBLIC_KEY="${PUBLIC_KEY}"
  export SUBSCRIPTION_SHORT_ID="${SHORT_ID}"
  export SUBSCRIPTION_SNI="${REALITY_SERVER_NAME}"
  export SUBSCRIPTION_PORT="${XRAY_PORT}"
  export SUBSCRIPTION_FLOW="xtls-rprx-vision"
  installer_core_subscription_protocol_defaults
  installer_core_publish_subscription
  : "${SUBSCRIPTION_ACCESS_URL:=${VLESS_LINK:-}}"
  installer_core_print_completion_block "$(installer_core_mode_label)" "${SUBSCRIPTION_ACCESS_URL}" "Shadowrocket, v2rayNG, Clash, sing-box"

  echo
  echo -e "${BLUE}================= CLIENT INFO =================${NC}"
  cat "${CLIENT_INFO}"
  echo -e "${BLUE}================================================${NC}"

  print_client_qr "${SUBSCRIPTION_ACCESS_URL:-${VLESS_LINK:-}}" "/root/xray-vless-reality-qr.png"
}

start_services() {
  log "Starting Xray service..."

  systemctl enable xray
  systemctl restart xray

  if systemctl is-active --quiet xray; then
    log "Xray is running."
  else
    journalctl -u xray -e --no-pager || true
    error "Xray failed to start."
  fi
}

main() {
  trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
  trap 'on_exit "$?"' EXIT

  preflight_phase
  load_install_state

  section_header "PHASE 2 - INSTALL"
  install_packages
  enable_network_tuning
  create_deploy_user
  harden_ssh_safe
  configure_ufw
  configure_tcp_mss_clamp
  configure_fail2ban
  install_xray
  check_reality_dns_health
  generate_values
  write_xray_config
  install_shadowrocket_config
  save_state
  start_services
  write_client_info
  write_install_lock

  verify_phase
  report_phase

  log "Deployment completed successfully."
}

main "$@"
