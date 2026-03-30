#!/usr/bin/env python3
"""AppCoreOS full-screen TUI dashboard using curses."""

import curses
import datetime as dt
import json
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import List, Tuple

APP_NAME = "appcoreos"
FRAME_DELAY_SECONDS = 0.5
STATE_FILE = Path("/var/lib/appcoreos/state.json")
LAST_UPDATE_FILE = Path("/var/lib/appcoreos/last-update")
MACHINE_ID_FILE = Path("/var/lib/appcoreos/machine-id")
REMOTE_CONFIG_BASE_URL = "http://10.0.2.2:8081/config"


def run_command(command: List[str]) -> str:
    """Run a command and return stdout as text, or empty string on failure."""
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode != 0:
            return ""
        return result.stdout.strip()
    except Exception:
        return ""


def get_hostname() -> str:
    name = run_command(["hostnamectl", "--static"])
    if not name:
        name = socket.gethostname()
    return name or "unknown"


def get_primary_ip() -> str:
    route_info = run_command(["ip", "-4", "route", "get", "1.1.1.1"])
    if route_info:
        match = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", route_info)
        if match:
            return match.group(1)

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 80))
            return sock.getsockname()[0]
    except Exception:
        return "unknown"


def get_machine_id() -> str:
    try:
        return MACHINE_ID_FILE.read_text(encoding="utf-8").strip() or "unknown"
    except Exception:
        return "unknown"


def get_last_update() -> str:
    try:
        if LAST_UPDATE_FILE.exists():
            last_update_epoch = LAST_UPDATE_FILE.stat().st_mtime
            return dt.datetime.fromtimestamp(last_update_epoch, tz=dt.timezone.utc).astimezone().strftime(
                "%Y-%m-%d %H:%M:%S %Z"
            )
    except Exception:
        pass
    return "never"


def get_state_timestamp() -> str:
    try:
        if not STATE_FILE.exists():
            return "unknown"
        content = STATE_FILE.read_text(encoding="utf-8")
        data = json.loads(content)
        value = str(data.get("timestamp", "")).strip()
        return value or "unknown"
    except Exception:
        return "unknown"


def get_containers() -> List[Tuple[str, str, str]]:
    if shutil.which("podman") is None:
        return [("podman", "unavailable", "")]

    output = run_command(["podman", "ps", "--format", "{{.Names}}|{{.Image}}|{{.Status}}"])
    if not output:
        return []

    containers: List[Tuple[str, str, str]] = []
    for line in output.splitlines():
        parts = line.split("|", 2)
        while len(parts) < 3:
            parts.append("")
        name, image, status = [p.strip() or "unknown" for p in parts]
        containers.append((name, image, status))
    return containers


def draw_box(stdscr: curses.window, top: int, left: int, height: int, width: int) -> None:
    if height < 2 or width < 2:
        return
    safe_addstr(stdscr, top, left, "+" + "-" * (width - 2) + "+")
    for row in range(top + 1, top + height - 1):
        safe_addstr(stdscr, row, left, "|")
        safe_addstr(stdscr, row, left + width - 1, "|")
    safe_addstr(stdscr, top + height - 1, left, "+" + "-" * (width - 2) + "+")


def add_center(stdscr: curses.window, y: int, text: str, attr: int = 0) -> None:
    _, width = stdscr.getmaxyx()
    x = max((width - len(text)) // 2, 0)
    safe_addstr(stdscr, y, x, text, attr)


def safe_addstr(stdscr: curses.window, y: int, x: int, text: str, attr: int = 0) -> None:
    """Write text safely inside screen bounds."""
    height, width = stdscr.getmaxyx()
    if y < 0 or y >= height or x >= width:
        return
    max_len = max(width - x - 1, 0)
    if max_len == 0:
        return
    stdscr.addnstr(y, x, text, max_len, attr)


def draw_dashboard(stdscr: curses.window) -> None:
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(1)

    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        curses.init_pair(2, curses.COLOR_GREEN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        title_attr = curses.A_BOLD | curses.color_pair(1)
        ok_attr = curses.A_BOLD | curses.color_pair(2)
        warn_attr = curses.A_BOLD | curses.color_pair(3)
    else:
        title_attr = curses.A_BOLD
        ok_attr = curses.A_BOLD
        warn_attr = curses.A_BOLD

    while True:
        stdscr.erase()
        height, width = stdscr.getmaxyx()

        if height < 18 or width < 72:
            add_center(stdscr, max(height // 2 - 1, 0), APP_NAME, title_attr)
            add_center(stdscr, height // 2 + 1, "Terminal too small - resize to at least 72x18")
            stdscr.refresh()
            time.sleep(FRAME_DELAY_SECONDS)
            continue

        hostname = get_hostname()
        primary_ip = get_primary_ip()
        machine_id = get_machine_id()
        machine_id_short = machine_id[:12] if machine_id != "unknown" else machine_id
        machine_id_remote = machine_id if len(machine_id) <= 20 else f"{machine_id[:20]}..."
        last_update = get_last_update()
        state_timestamp = get_state_timestamp()
        now = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        containers = get_containers()

        panel_width = min(108, width - 4)
        panel_height = min(28, height - 2)
        panel_left = (width - panel_width) // 2
        panel_top = (height - panel_height) // 2
        draw_box(stdscr, panel_top, panel_left, panel_height, panel_width)

        add_center(stdscr, panel_top + 1, APP_NAME, title_attr)
        add_center(stdscr, panel_top + 2, "Immutable Appliance Console", warn_attr)

        x = panel_left + 2
        y = panel_top + 4
        safe_addstr(stdscr, y, x, f"Hostname      : {hostname}")
        safe_addstr(stdscr, y + 1, x, f"Primary IP    : {primary_ip}")
        safe_addstr(stdscr, y + 2, x, f"Machine ID    : {machine_id_short}")
        safe_addstr(stdscr, y + 3, x, f"Current Time  : {now}")
        safe_addstr(stdscr, y + 4, x, f"State Updated : {state_timestamp}")
        safe_addstr(stdscr, y + 5, x, f"Last OS Update: {last_update}")

        safe_addstr(stdscr, y + 7, x, "Connection Help", curses.A_BOLD)
        safe_addstr(stdscr, y + 8, x, f"Config source     : {REMOTE_CONFIG_BASE_URL}/{machine_id_remote} (guest -> host)")
        safe_addstr(stdscr, y + 9, x, "Debug API (host)  : http://127.0.0.1:9090")
        safe_addstr(stdscr, y + 10, x, "Guest IP note     : 10.0.2.x is NAT-only in QEMU user-net")
        safe_addstr(stdscr, y + 11, x, "Network mode      : DHCP (QEMU user networking)")

        table_top = y + 13
        safe_addstr(stdscr, table_top, x, "Containers", curses.A_BOLD)
        safe_addstr(stdscr, table_top + 1, x, "NAME                IMAGE                                  STATUS")
        safe_addstr(stdscr, table_top + 2, x, "-" * min(panel_width - 4, 80))

        row = table_top + 3
        if containers:
            for name, image, status in containers:
                if row >= panel_top + panel_height - 2:
                    break
                line = f"{name:<18} {image:<38} {status}"
                attr = ok_attr if "up" in status.lower() or "running" in status.lower() else 0
                safe_addstr(stdscr, row, x, line, attr)
                row += 1
        else:
            safe_addstr(stdscr, row, x, "No running containers")

        stdscr.refresh()

        key = stdscr.getch()
        if key == curses.KEY_RESIZE:
            continue

        time.sleep(FRAME_DELAY_SECONDS)


def main() -> None:
    while True:
        try:
            curses.wrapper(draw_dashboard)
        except Exception:
            time.sleep(1)


if __name__ == "__main__":
    main()
