#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/var/lib/appcoreos/config.yaml"
DEFAULT_AUTO_REBOOT="true"
DEFAULT_WINDOW_START="03:00"
DEFAULT_WINDOW_END="05:00"

log() {
  echo "$(date -Iseconds) [update-reboot] $*"
}

cfg_or_default() {
  local yq_expr="$1"
  local default_value="$2"
  local value=""

  if [[ -f "${CONFIG_FILE}" ]]; then
    value="$(yq -r "${yq_expr} // \"${default_value}\"" "${CONFIG_FILE}" 2>/dev/null || true)"
  fi

  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "${default_value}"
  else
    echo "${value}"
  fi
}

to_minutes() {
  local hhmm="$1"
  local hh="${hhmm%%:*}"
  local mm="${hhmm##*:}"
  echo $((10#${hh} * 60 + 10#${mm}))
}

is_in_window() {
  local current_min="$1"
  local start_min="$2"
  local end_min="$3"

  if (( start_min == end_min )); then
    return 0
  fi

  if (( start_min < end_min )); then
    (( current_min >= start_min && current_min < end_min ))
    return
  fi

  # Window crossing midnight, e.g. 23:00 -> 02:00.
  (( current_min >= start_min || current_min < end_min ))
}

has_pending_deployment() {
  if ! command -v rpm-ostree >/dev/null 2>&1; then
    return 1
  fi

  local status_json=""
  status_json="$(rpm-ostree status --json 2>/dev/null || true)"
  if [[ -z "${status_json}" ]]; then
    return 1
  fi

  if python3 - <<'PY' <<<"${status_json}"
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for deployment in data.get("deployments", []):
    if deployment.get("booted") is not True:
        sys.exit(0)

sys.exit(1)
PY
  then
    return 0
  fi

  return 1
}

auto_reboot="$(cfg_or_default '.updates.auto_reboot' "${DEFAULT_AUTO_REBOOT}" | tr '[:upper:]' '[:lower:]')"
window_start="$(cfg_or_default '.updates.maintenance_window_utc.start' "${DEFAULT_WINDOW_START}")"
window_end="$(cfg_or_default '.updates.maintenance_window_utc.end' "${DEFAULT_WINDOW_END}")"

if [[ "${auto_reboot}" != "true" ]]; then
  log "auto reboot disabled; skipping"
  exit 0
fi

if [[ ! "${window_start}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  log "invalid window start '${window_start}'; skipping"
  exit 0
fi

if [[ ! "${window_end}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  log "invalid window end '${window_end}'; skipping"
  exit 0
fi

if ! has_pending_deployment; then
  log "no staged deployment pending reboot"
  exit 0
fi

current_hhmm="$(date -u +%H:%M)"
current_min="$(to_minutes "${current_hhmm}")"
start_min="$(to_minutes "${window_start}")"
end_min="$(to_minutes "${window_end}")"

if ! is_in_window "${current_min}" "${start_min}" "${end_min}"; then
  log "pending deployment found, but outside maintenance window ${window_start}-${window_end} UTC"
  exit 0
fi

log "pending deployment found within maintenance window; rebooting"
exec systemctl reboot
