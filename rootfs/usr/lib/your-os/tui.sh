#!/usr/bin/env bash
set -euo pipefail

APP_NAME="appcoreos"
INVALID_OPTION_MESSAGE="Invalid option"
MENU_PROMPT="Select option [1-5]: "
PAUSE_PROMPT="Press enter to continue..."

# Track terminal resize notifications so the menu can redraw cleanly.
RESIZED=0
trap 'RESIZED=1' WINCH

clear_screen() {
  # Full clear + move cursor to top-left keeps redraw stable.
  printf '\033[2J\033[H'
}

get_terminal_width() {
  local rows
  local cols

  if read -r rows cols < <(stty size 2>/dev/null); then
    if [[ -n "${cols}" ]] && [[ "${cols}" =~ ^[0-9]+$ ]] && (( cols > 0 )); then
      printf '%s\n' "${cols}"
      return
    fi
  fi

  if [[ -n "${COLUMNS:-}" ]] && [[ "${COLUMNS}" =~ ^[0-9]+$ ]] && (( COLUMNS > 0 )); then
    printf '%s\n' "${COLUMNS}"
    return
  fi

  printf '80\n'
}

center_text() {
  local text="$1"
  local width
  local padding

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

  if [[ -z "${value}" ]]; then
    value="unknown"
  fi

  printf '%s\n' "${value}"
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

  if [[ -z "${ip}" ]]; then
    ip="unknown"
  fi

  printf '%s\n' "${ip}"
}

draw_header() {
  clear_screen
  center_text "${APP_NAME}"
  echo
}

draw_system_info() {
  local hostname_value
  local primary_ip
  local current_time

  hostname_value="$(get_hostname_value)"
  primary_ip="$(get_primary_ip_value)"
  current_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  echo "Hostname: ${hostname_value}"
  echo "IP: ${primary_ip}"
  echo "Time: ${current_time}"
  echo
}

draw_menu() {
  draw_header
  draw_system_info

  echo "Menu:"
  echo ">> 1. Show running containers"
  echo "   2. Restart system"
  echo "   3. Shutdown system"
  echo "   4. Show failed systemd services"
  echo "   5. Exit"
  echo
}

pause_for_user() {
  echo
  read -r -p "${PAUSE_PROMPT}" _unused || true
}

show_running_containers() {
  draw_header
  echo "Running containers"
  echo

  if command -v podman >/dev/null 2>&1; then
    if ! podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'; then
      echo "Failed to read container status from podman."
    fi
  else
    echo "podman command not available."
  fi

  pause_for_user
}

show_failed_services() {
  draw_header
  echo "Failed systemd services"
  echo

  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl --failed --no-pager --plain; then
      echo "Failed to query systemd service status."
    fi
  else
    echo "systemctl command not available."
  fi

  pause_for_user
}

restart_system() {
  draw_header
  echo "Restarting system..."

  if ! systemctl reboot; then
    echo
    echo "Failed to trigger reboot."
    pause_for_user
  fi
}

shutdown_system() {
  draw_header
  echo "Shutting down system..."

  if ! systemctl poweroff; then
    echo
    echo "Failed to trigger shutdown."
    pause_for_user
  fi
}

handle_input() {
  local user_choice="$1"

  case "${user_choice}" in
    1)
      show_running_containers
      ;;
    2)
      restart_system
      ;;
    3)
      shutdown_system
      ;;
    4)
      show_failed_services
      ;;
    5)
      # Explicitly return to menu; never exits to a shell.
      return
      ;;
    *)
      draw_header
      echo "${INVALID_OPTION_MESSAGE}"
      pause_for_user
      ;;
  esac
}

main_loop() {
  local user_choice

  while true; do
    if (( RESIZED == 1 )); then
      RESIZED=0
    fi

    draw_menu

    read -r -p "${MENU_PROMPT}" user_choice || user_choice=""

    if [[ "${user_choice}" =~ ^[1-5]$ ]]; then
      handle_input "${user_choice}"
    else
      draw_header
      echo "${INVALID_OPTION_MESSAGE}"
      pause_for_user
    fi
  done
}

main_loop
