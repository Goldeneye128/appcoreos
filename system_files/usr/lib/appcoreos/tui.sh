#!/usr/bin/env python3
"""AppCoreOS full-screen TUI dashboard using curses."""

import curses
import datetime as dt
import re
import shutil
import socket
import subprocess
import time
from typing import List, Tuple

APP_NAME = "appcoreos"
FRAME_DELAY_SECONDS = 0.5


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
        title_attr = curses.A_BOLD | curses.color_pair(1)
    else:
        title_attr = curses.A_BOLD

    while True:
        stdscr.erase()
        height, width = stdscr.getmaxyx()

        hostname = get_hostname()
        primary_ip = get_primary_ip()
        now = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        containers = get_containers()

        title_x = max((width - len(APP_NAME)) // 2, 0)
        safe_addstr(stdscr, 0, title_x, APP_NAME, title_attr)

        safe_addstr(stdscr, 2, 2, f"Hostname: {hostname}")
        safe_addstr(stdscr, 3, 2, f"Primary IP: {primary_ip}")
        safe_addstr(stdscr, 4, 2, f"Time: {now}")

        safe_addstr(stdscr, 6, 2, "Containers", curses.A_BOLD)
        safe_addstr(stdscr, 7, 2, "NAME                IMAGE                                STATUS")
        safe_addstr(stdscr, 8, 2, "----------------------------------------------------------------")

        row = 9
        if containers:
            for name, image, status in containers:
                if row >= height - 1:
                    break
                line = f"{name:<18} {image:<36} {status}"
                safe_addstr(stdscr, row, 2, line)
                row += 1
        else:
            safe_addstr(stdscr, row, 2, "No running containers")

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
