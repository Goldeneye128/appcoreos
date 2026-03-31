#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/appcoreos/state.json"
CONFIG_FILE="/var/lib/appcoreos/config.yaml"
CONFIG_NEW_FILE="/var/lib/appcoreos/config.new.yaml"
CONFIG_DOWNLOAD_FILE="/var/lib/appcoreos/config.new.yaml.download"
LAST_REBOOT_TRIGGER_FILE="/var/lib/appcoreos/last-reboot-trigger"
MACHINE_ID_FILE="/var/lib/appcoreos/machine-id"
REMOTE_CONFIG_BASE_URL_DEFAULT="http://10.0.2.2:8081/config"
DEBUG_SERVER_SCRIPT="/usr/lib/appcoreos/agent-debug-server.py"
API_AUTH_KEY_FILE="/var/lib/appcoreos/api-auth.key"
API_TLS_CERT_FILE="/var/lib/appcoreos/api-cert.pem"
API_TLS_KEY_FILE="/var/lib/appcoreos/api-key.pem"
BOOTSTRAP_TOKEN_FILE="/var/lib/appcoreos/bootstrap/token"
BOOTSTRAP_CLAIMED_FILE="/var/lib/appcoreos/bootstrap/claimed"
CLIENT_CA_FILE="/var/lib/appcoreos/pki/client-ca.crt"
API_PORT="9090"
MAX_CONFIG_BYTES=1048576
MIN_REBOOT_INTERVAL_SECONDS=60
SLEEP_SECONDS=30

log() {
  echo "$(date -Iseconds) [agent] $*"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required binary: $1"
    exit 1
  }
}

require_bin yq
require_bin curl
require_bin systemctl
require_bin cmp
require_bin mktemp
require_bin python3
require_bin ip
require_bin openssl

get_gateway_ip() {
  ip -4 route show default 2>/dev/null | awk '
    /^default/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "via") {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

if [[ ! -s "${MACHINE_ID_FILE}" ]]; then
  log "machine-id missing at ${MACHINE_ID_FILE}"
  exit 1
fi

machine_id="$(tr -d '\n' < "${MACHINE_ID_FILE}")"
gateway_ip="$(get_gateway_ip || true)"
remote_config_base_url="${REMOTE_CONFIG_BASE_URL_DEFAULT}"
if [[ "${gateway_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  remote_config_base_url="http://${gateway_ip}:8081/config"
fi
remote_config_url="${remote_config_base_url}/${machine_id}"
log "machine-id=${machine_id}"
log "config-endpoint=${remote_config_url}"

if [[ ! -f "${DEBUG_SERVER_SCRIPT}" ]]; then
  log "debug server missing at ${DEBUG_SERVER_SCRIPT}"
  exit 1
fi

if [[ ! -s "${API_AUTH_KEY_FILE}" ]]; then
  log "initializing API auth key"
  umask 077
  openssl rand -hex 16 > "${API_AUTH_KEY_FILE}"
fi
chmod 0600 "${API_AUTH_KEY_FILE}" || true
api_auth_key="$(tr -d '\n' < "${API_AUTH_KEY_FILE}")"

regen_tls_cert="0"
if [[ ! -s "${API_TLS_CERT_FILE}" || ! -s "${API_TLS_KEY_FILE}" ]]; then
  regen_tls_cert="1"
elif ! openssl x509 -in "${API_TLS_CERT_FILE}" -noout -checkend 86400 >/dev/null 2>&1; then
  # Regenerate if certificate expires within 24h.
  regen_tls_cert="1"
elif ! openssl x509 -in "${API_TLS_CERT_FILE}" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:127.0.0.1"; then
  # Regenerate legacy certs that do not include loopback SAN.
  regen_tls_cert="1"
fi

if [[ "${regen_tls_cert}" == "1" ]]; then
  log "initializing API TLS certificate"
  rm -f "${API_TLS_CERT_FILE}" "${API_TLS_KEY_FILE}"
  primary_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  san_list="DNS:localhost,DNS:appcoreos-api,IP:127.0.0.1"
  if [[ -n "${primary_ip}" ]]; then
    san_list="${san_list},IP:${primary_ip}"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "${API_TLS_KEY_FILE}" \
    -out "${API_TLS_CERT_FILE}" \
    -days 397 \
    -subj "/CN=appcoreos-api" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=${san_list}" >/dev/null 2>&1
fi
chmod 0600 "${API_TLS_KEY_FILE}" || true
chmod 0644 "${API_TLS_CERT_FILE}" || true

export APPCOREOS_API_HOST="0.0.0.0"
export APPCOREOS_API_PORT="${API_PORT}"
export APPCOREOS_API_KEY="${api_auth_key}"
export APPCOREOS_TLS_CERT="${API_TLS_CERT_FILE}"
export APPCOREOS_TLS_KEY="${API_TLS_KEY_FILE}"
export APPCOREOS_BOOTSTRAP_TOKEN_FILE="${BOOTSTRAP_TOKEN_FILE}"
export APPCOREOS_BOOTSTRAP_CLAIMED_FILE="${BOOTSTRAP_CLAIMED_FILE}"
export APPCOREOS_CLIENT_CA="${CLIENT_CA_FILE}"
export APPCOREOS_REQUIRE_MTLS="0"

if [[ -f "${BOOTSTRAP_CLAIMED_FILE}" ]]; then
  if [[ -s "${CLIENT_CA_FILE}" ]]; then
    export APPCOREOS_REQUIRE_MTLS="1"
    log "bootstrap claim detected; enforcing mTLS"
  else
    log "bootstrap claim marker found but client CA missing; starting without mTLS"
  fi
else
  log "node unclaimed; bootstrap token flow enabled"
fi

log "starting local API server on https://127.0.0.1:${API_PORT}"
python3 "${DEBUG_SERVER_SCRIPT}" &
debug_server_pid="$!"

cleanup() {
  if [[ -n "${debug_server_pid:-}" ]]; then
    kill "${debug_server_pid}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

while true; do
  if [[ ! -f "${STATE_FILE}" ]]; then
    log "state file missing at ${STATE_FILE}"
  else
    hostname_value="$(yq -r '.hostname // "unknown"' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
    container_count="$(yq -r '.containers // [] | length' "${STATE_FILE}" 2>/dev/null || echo "0")"
    log "hostname=${hostname_value} containers=${container_count}"
  fi

  log "fetching remote config from ${remote_config_url}"
  rm -f "${CONFIG_NEW_FILE}" "${CONFIG_DOWNLOAD_FILE}"
  http_code="$(
    curl -sS --max-time 10 --output "${CONFIG_DOWNLOAD_FILE}" --write-out "%{http_code}" \
      "${remote_config_url}" 2>/dev/null || true
  )"

  if [[ "${http_code}" == "200" ]]; then
    log "remote config fetch succeeded (HTTP 200)"
    config_size_bytes="$(wc -c < "${CONFIG_DOWNLOAD_FILE}" | tr -d '[:space:]')"
    if (( config_size_bytes >= MAX_CONFIG_BYTES )); then
      log "config rejected (too large: ${config_size_bytes} bytes, max ${MAX_CONFIG_BYTES})"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    if ! yq -e '.' "${CONFIG_DOWNLOAD_FILE}" >/dev/null 2>&1; then
      log "config rejected (invalid YAML)"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    if ! yq -e '(.hostname | type) == "!!str" and (.hostname | length) > 0 and (.containers | type) == "!!seq"' \
      "${CONFIG_DOWNLOAD_FILE}" >/dev/null 2>&1; then
      log "config rejected (missing/invalid required fields: hostname:string, containers:array)"
      rm -f "${CONFIG_DOWNLOAD_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    mv -f "${CONFIG_DOWNLOAD_FILE}" "${CONFIG_NEW_FILE}"

    if [[ -f "${CONFIG_FILE}" ]] && cmp -s "${CONFIG_NEW_FILE}" "${CONFIG_FILE}"; then
      log "remote config unchanged"
      rm -f "${CONFIG_NEW_FILE}"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    config_apply_tmp="$(mktemp "/var/lib/appcoreos/config.yaml.tmp.XXXXXX")"
    cat "${CONFIG_NEW_FILE}" > "${config_apply_tmp}"
    mv -f "${config_apply_tmp}" "${CONFIG_FILE}"
    log "config accepted and applied from remote"

    now_epoch="$(date +%s)"
    last_reboot_epoch=""
    if [[ -s "${LAST_REBOOT_TRIGGER_FILE}" ]]; then
      last_reboot_epoch="$(tr -d '[:space:]' < "${LAST_REBOOT_TRIGGER_FILE}")"
    fi

    if [[ "${last_reboot_epoch}" =~ ^[0-9]+$ ]] && (( now_epoch - last_reboot_epoch < MIN_REBOOT_INTERVAL_SECONDS )); then
      log "reboot suppressed (too frequent)"
      sleep "${SLEEP_SECONDS}"
      continue
    fi

    printf '%s\n' "${now_epoch}" > "${LAST_REBOOT_TRIGGER_FILE}"
    log "triggering reboot due to config change"
    exec systemctl reboot
  else
    log "remote config fetch skipped (HTTP ${http_code:-error})"
  fi

  sleep "${SLEEP_SECONDS}"
done
