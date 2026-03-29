#!/usr/bin/env bash
set -u

REFRESH_SECONDS=2
APP_NAME="AppCoreOS"

# Ignore common termination signals so the dashboard does not exit unexpectedly.
trap '' HUP INT TERM

clear_screen() {
  printf '\033[2J\033[H'
}

get_terminal_width() {
  local rows cols

  if read -r rows cols < <(stty size 2>/dev/null); then
    if [[ -n "${cols}" ]] && [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols > 0 )); then
      printf '%s\n' "${cols}"
      return
    fi
  fi

  printf '80\n'
}

center_text() {
  local text="$1"
  local width padding

  width="$(get_terminal_width)"
  padding=$(( (width - ${#text}) / 2 ))
  if (( padding < 0 )); then
    padding=0
  fi

  printf '%*s%s\n' "${padding}" "" "${text}"
}

get_hostname_value() {
  local value=""

  if command -v hostnamectl >/dev/null 2>&1; then
    value="$(hostnamectl --static 2>/dev/null || true)"
  fi

  if [[ -z "${value}" ]] && command -v hostname >/dev/null 2>&1; then
    value="$(hostname 2>/dev/null || true)"
  fi

  [[ -n "${value}" ]] && printf '%s\n' "${value}" || printf 'unknown\n'
}

get_primary_ip_value() {
  local ip=""

  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    if [[ -z "${ip}" ]]; then
      ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]; exit}')"
    fi
  fi

  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  [[ -n "${ip}" ]] && printf '%s\n' "${ip}" || printf 'unknown\n'
}

print_containers() {
  local container_lines
  local line_count

  if ! command -v podman >/dev/null 2>&1; then
    echo "podman unavailable"
    return
  fi

  container_lines="$(podman ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)"
  if [[ -z "${container_lines}" ]]; then
    echo "none"
    return
  fi

  line_count=0
  while IFS='|' read -r name image status; do
    [[ -z "${name}${image}${status}" ]] && continue
    printf -- "- %s | %s | %s\n" "${name:-unknown}" "${image:-unknown}" "${status:-unknown}"
    line_count=$((line_count + 1))
  done <<< "${container_lines}"

  if (( line_count == 0 )); then
    echo "none"
  fi
}

draw_dashboard() {
  local hostname_value ip_value current_time

  hostname_value="$(get_hostname_value)"
  ip_value="$(get_primary_ip_value)"
  current_time="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)"

  clear_screen
  center_text "${APP_NAME}"
  echo
  echo "Hostname: ${hostname_value}"
  echo "Primary IP: ${ip_value}"
  echo "Current time: ${current_time}"
  echo
  echo "Containers:"
  print_containers
  echo
  echo "Refreshing every ${REFRESH_SECONDS}s"
}

main() {
  while true; do
    draw_dashboard || true
    sleep "${REFRESH_SECONDS}" || true
  done
}

main
