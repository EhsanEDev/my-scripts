#!/usr/bin/env bash
# Debian standalone Xray VLESS + REALITY installer.
# Uses the official XTLS/Xray-install script. Review before running as root.
set -Eeuo pipefail
umask 077

readonly OFFICIAL_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/var/lib/xray-reality-setup"
readonly BACKUP_ROOT="/var/backups/xray-reality-setup"
readonly LOG_FILE="/var/log/xray-reality-setup.log"

TMP_DIR=""
INSTALL_STARTED=0
CONFIG_COMMITTED=0
SERVICE_WAS_ACTIVE=0
OLD_CONFIG=""
NEW_CONFIG=""

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARNING: $*"; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        # If the official installer completed but our config was not committed,
        # try to bring its existing/default config back online.
        if (( INSTALL_STARTED == 1 && CONFIG_COMMITTED == 0 )) &&
           systemctl cat xray.service >/dev/null 2>&1 &&
           [[ -s "$CONFIG_FILE" ]]; then
            systemctl start xray.service >/dev/null 2>&1 || true
        fi
        echo
        echo "Setup did not finish successfully (exit $rc)."
        echo "Log: $LOG_FILE"
        if (( INSTALL_STARTED == 1 && CONFIG_COMMITTED == 0 )); then
            echo "Xray may have been installed but setup did not finish. Inspect: systemctl status xray"
        fi
    fi
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "This script supports Debian only (detected: ${PRETTY_NAME:-unknown})."
[[ -d /run/systemd/system ]] || die "systemd is required."
[[ "$(dpkg --print-architecture 2>/dev/null || true)" =~ ^(amd64|arm64|armhf|i386|ppc64el|s390x|riscv64)$ ]] ||
    die "Unsupported Debian architecture: $(dpkg --print-architecture 2>/dev/null || echo unknown)"

mkdir -p "$(dirname "$LOG_FILE")"
chmod 600 "$LOG_FILE"
log "Starting Debian Xray VLESS + REALITY setup."

# Strict no-clobber checks: do not touch a server already running Xray/3x-ui or existing configs.
for unit in xray.service x-ui.service; do
    if systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{print $1}' | grep -Fxq "$unit"; then
        die "$unit already exists. No changes made; use a clean server or migrate manually."
    fi
done
for path in "$CONFIG_FILE" /etc/x-ui /usr/local/x-ui; do
    [[ ! -e "$path" ]] || die "Existing path detected: $path. No changes made."
done
if pgrep -af '(^|/)(xray|x-ui)( |$)' >/dev/null 2>&1; then
    die "An Xray/3x-ui process appears to be running. No changes made."
fi

# Check common web/proxy services and port conflicts before installing.
for unit in nginx.service apache2.service caddy.service haproxy.service; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        warn "$unit is active; choose a port it does not use."
    fi
done

echo
echo "Preflight: this script will install standalone Xray, not 3x-ui."
echo "It will abort rather than overwrite existing Xray/3x-ui installations."
echo "It cannot change your VPS provider firewall or guarantee network reachability."
echo
read -r -p "Inbound port [443]: " PORT
PORT="${PORT:-443}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "Port must be a number."
(( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535."
[[ "$PORT" != "22" ]] || warn "Port 22 is commonly used by SSH; make sure this is intentional."

if have ss && ss -H -ltn "sport = :$PORT" | grep -q .; then
    die "TCP port $PORT is already listening. No changes made."
fi
if have ss && ss -H -lun "sport = :$PORT" | grep -q .; then
    warn "UDP port $PORT is occupied (Xray inbound here uses TCP)."
fi

read -r -p "REALITY target/SNI hostname [www.microsoft.com]: " SNI
SNI="${SNI:-www.microsoft.com}"
[[ "$SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
    die "Invalid hostname. Enter a hostname only, without scheme or port."
[[ "$SNI" != *".."* ]] || die "Invalid hostname."

read -r -p "Public IPv4 (leave blank to auto-detect): " PUBLIC_IP
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]; then
    warn "Public IPv4 auto-detection failed."
    read -r -p "Enter the public IPv4 address clients should use: " PUBLIC_IP
fi
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]] || die "A valid public IPv4 is required before installation."
IFS='.' read -r pre1 pre2 pre3 pre4 <<< "$PUBLIC_IP"
for octet in "$pre1" "$pre2" "$pre3" "$pre4"; do (( 10#$octet <= 255 )) || die "Invalid public IPv4 address."; done
read -r -p "Confirm you have console/provider access if SSH/network rules are external [y/N]: " ACK
[[ "$ACK" =~ ^[Yy]$ ]] || die "Cancelled. No changes made."

# Minimal dependencies; do not perform a full system upgrade.
export DEBIAN_FRONTEND=noninteractive
log "Installing prerequisite packages."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl iproute2 procps

# Recheck after apt activity, before installation.
for unit in xray.service x-ui.service; do
    if systemctl list-unit-files --type=service --no-legend 2>/dev/null |
        awk '{print $1}' | grep -Fxq "$unit"; then
        die "$unit appeared during preflight. Aborting."
    fi
done
if ss -H -ltn "sport = :$PORT" | grep -q .; then
    die "TCP port $PORT became occupied during preflight. Aborting."
fi

TMP_DIR="$(mktemp -d /tmp/xray-reality.XXXXXXXX)"
chmod 700 "$TMP_DIR"
INSTALLER="$TMP_DIR/install-release.sh"
log "Downloading official installer from $OFFICIAL_INSTALLER_URL"
curl --fail --location --silent --show-error --retry 3 \
    --connect-timeout 10 --max-time 180 "$OFFICIAL_INSTALLER_URL" -o "$INSTALLER"
[[ -s "$INSTALLER" ]] || die "Official installer download is empty."
head -n 1 "$INSTALLER" | grep -qE '^#!.*(bash|sh)' || die "Installer does not look like a shell script."
grep -q 'XTLS/Xray-core' "$INSTALLER" || warn "Could not find expected repository marker; review official installer if concerned."
echo
echo "Installer downloaded. It will now be executed from the official XTLS/Xray-install repository."
read -r -p "Continue installation? [y/N]: " CONTINUE
[[ "$CONTINUE" =~ ^[Yy]$ ]] || die "Cancelled before Xray installation."

INSTALL_STARTED=1
bash "$INSTALLER" install
XRAY_BIN="/usr/local/bin/xray"
[[ -x "$XRAY_BIN" ]] || XRAY_BIN="$(command -v xray || true)"
[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die "Xray binary not found after official installation."
"$XRAY_BIN" version | head -n 2 | tee -a "$LOG_FILE"

# Stop the just-installed service while validating/writing the new config.
if systemctl is-active --quiet xray.service; then SERVICE_WAS_ACTIVE=1; fi
systemctl stop xray.service 2>/dev/null || true

# Parse current and future key output formats without assuming a single label.
UUID="$("$XRAY_BIN" uuid | tr -d '\r\n')"
[[ "$UUID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] || die "Xray generated an invalid UUID."
KEY_OUTPUT="$("$XRAY_BIN" x25519 2>&1)" || die "xray x25519 failed: $KEY_OUTPUT"
PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*(Private[[:space:]_-]*key|PrivateKey)[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\2/ip' | head -n 1)"
PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*(Password|Public[[:space:]_-]*key|PublicKey)[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\2/ip' | head -n 1)"
[[ -n "$PRIVATE_KEY" ]] || die "Could not parse private key from xray x25519 output. Output was logged only in memory; no config was written."
[[ -n "$PUBLIC_KEY" ]] || die "Could not parse public key from xray x25519 output. Output was logged only in memory; no config was written."
SHORT_ID="$(openssl rand -hex 8)"
[[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "Short ID generation failed."

# Target reachability is a warning, not an unconditional blocker (some hosts block ICMP/HTTPS).
if ! timeout 8 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$SNI" 2>/dev/null; then
    warn "Could not confirm TCP connectivity to ${SNI}:443. REALITY may fail if the target is unreachable from this VPS."
else
    log "TCP connection to ${SNI}:443 succeeded."
fi

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_ROOT"
chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -e "$CONFIG_FILE" ]]; then
    # A default config created by the official installer is expected, but preserve it.
    cp -a "$CONFIG_FILE" "$BACKUP_ROOT/config-before-${STAMP}.json"
    log "Backed up installer-created config to $BACKUP_ROOT/config-before-${STAMP}.json"
fi

NEW_CONFIG="$TMP_DIR/config.json"
cat > "$NEW_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "encryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
chmod 600 "$NEW_CONFIG"

log "Validating generated config."
"$XRAY_BIN" run -test -config "$NEW_CONFIG" || die "Xray config validation failed. The current config has not been replaced."

# Atomic replacement; retain an independent copy for rollback.
if [[ -e "$CONFIG_FILE" ]]; then cp -a "$CONFIG_FILE" "$BACKUP_ROOT/config-before-commit-${STAMP}.json"; fi
install -m 600 "$NEW_CONFIG" "${CONFIG_FILE}.new"
mv -f "${CONFIG_FILE}.new" "$CONFIG_FILE"
CONFIG_COMMITTED=1

if ! systemctl enable xray.service; then
    warn "Could not enable xray.service at boot."
fi
if ! systemctl restart xray.service; then
    warn "Service failed with the new config; attempting rollback."
    if [[ -f "$BACKUP_ROOT/config-before-commit-${STAMP}.json" ]]; then
        cp -a "$BACKUP_ROOT/config-before-commit-${STAMP}.json" "$CONFIG_FILE"
    elif [[ -f "$BACKUP_ROOT/config-before-${STAMP}.json" ]]; then
        cp -a "$BACKUP_ROOT/config-before-${STAMP}.json" "$CONFIG_FILE"
    fi
    systemctl restart xray.service || true
    CONFIG_COMMITTED=0
    die "Xray failed to start. Previous config was restored if available. Check: journalctl -u xray -n 100 --no-pager"
fi
systemctl is-active --quiet xray.service || die "Xray service is not active after restart."

# UFW is changed only when already installed and active. Other firewall tools are never rewritten.
if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ufw allow "${PORT}/tcp"; then
        log "Added UFW allow rule for TCP ${PORT}."
    else
        warn "Could not add UFW rule; configure firewall manually."
    fi
else
    warn "UFW is not active; no firewall rules were changed."
fi
if have nft; then
    warn "nftables is present. No nftables rules were changed; check your existing firewall policy."
fi

if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    warn "Could not auto-detect a public IPv4 address."
    read -r -p "Enter the public IPv4 address clients should use: " PUBLIC_IP
fi
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "No valid public IPv4 provided."
# Validate each octet range.
IFS='.' read -r o1 o2 o3 o4 <<< "$PUBLIC_IP"
for octet in "$o1" "$o2" "$o3" "$o4"; do (( 10#$octet <= 255 )) || die "Invalid IPv4 address."; done

LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Debian-REALITY"
install -m 600 /dev/null "$STATE_DIR/client-link.txt"
printf '%s\n' "$LINK" > "$STATE_DIR/client-link.txt"
install -m 600 /dev/null "$STATE_DIR/server-details.txt"
cat > "$STATE_DIR/server-details.txt" <<EOF
Created (UTC): ${STAMP}
Server public IPv4: ${PUBLIC_IP}
Port: ${PORT}/tcp
Protocol: VLESS + REALITY
SNI/target: ${SNI}
UUID: ${UUID}
REALITY public key: ${PUBLIC_KEY}
REALITY short ID: ${SHORT_ID}
Config: ${CONFIG_FILE}
Service: xray.service
EOF
chmod 600 "$STATE_DIR/server-details.txt"

echo
echo "============================================================"
echo "Xray setup completed and service is active."
echo "============================================================"
echo "Debian: ${PRETTY_NAME:-unknown}"
echo "Xray: $("$XRAY_BIN" version | head -n 1)"
echo "Service: $(systemctl is-active xray.service)"
echo "Port: ${PORT}/tcp"
echo "Config: ${CONFIG_FILE} (permissions 600)"
echo "Private details: ${STATE_DIR}/server-details.txt (permissions 600)"
echo "Client link: ${STATE_DIR}/client-link.txt (permissions 600)"
echo
echo "VLESS client URI (keep private):"
printf '%s\n' "$LINK"
echo
echo "IMPORTANT:"
echo "- Ensure TCP ${PORT} is allowed in the VPS provider firewall/security group."
echo "- UFW was changed only if it was already active; nftables/iptables were not modified."
echo "- A valid REALITY target/SNI is essential; this script cannot guarantee that a network path permits it."
echo "- Keep the server private key secret. Share only the VLESS URI with trusted clients."
echo "- Diagnostics: systemctl status xray --no-pager; journalctl -u xray -n 100 --no-pager"
