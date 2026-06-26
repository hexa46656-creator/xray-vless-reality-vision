#!/usr/bin/env bash
set -euo pipefail

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
SHADOWROCKET_CONF_SRC="default.conf"
SHADOWROCKET_CONF_DST="/root/shadowrocket-default.conf"

XRAY_PORT="${XRAY_PORT:-8443}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
REALITY_DNS_STRICT="${REALITY_DNS_STRICT:-warn}"
CLIENT_NAME="${CLIENT_NAME:-Xray-Reality}"
DEPLOY_USER="${DEPLOY_USER:-alex}"
DEPLOY_USER_PASSWORD="${DEPLOY_USER_PASSWORD:-}"

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Please run this script as root. Example: sudo -i"
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect operating system."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    error "This installer only supports Ubuntu. Detected: ${ID:-unknown}"
  fi

  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "This script is designed for Ubuntu 24.04. Detected: ${VERSION_ID:-unknown}"
    read -rp "Continue anyway? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
      exit 0
    fi
  fi
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
  log "Updating system and installing dependencies..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y \
    curl wget unzip jq socat ufw fail2ban ca-certificates gnupg lsb-release openssl iproute2 sudo dnsutils
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  fi
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

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${SSH_PORT}/tcp" comment "SSH"
  ufw allow "${XRAY_PORT}/tcp" comment "Xray Reality"

  # Useful for future web deployment / certificate issuance.
  ufw allow 80/tcp comment "HTTP"
  ufw allow 443/tcp comment "HTTPS"

  ufw --force enable
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

  echo
  echo -e "${BLUE}================= CLIENT INFO =================${NC}"
  cat "${CLIENT_INFO}"
  echo -e "${BLUE}================================================${NC}"
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
  require_root
  check_os
  detect_ssh_port
  install_packages
  create_deploy_user
  harden_ssh_safe
  configure_ufw
  configure_fail2ban
  install_xray
  check_reality_dns_health
  generate_values
  write_xray_config
  install_shadowrocket_config
  save_state
  start_services
  write_client_info

  log "Deployment completed successfully."
}

main "$@"
