#!/usr/bin/env python3
"""Launch forge-ide under Xvfb and verify it runs.

This script:
1. Starts Xvfb on a free display
2. Launches forge-ide with that display
3. Waits for the IDE to initialize
4. Verifies the process is running
5. Captures a screenshot if xwd is available
6. Kills the IDE and Xvfb

Usage: python3 scripts/launch_test_ide.py [--workspace PATH] [--time SECONDS]
"""

import os
import sys
import time
import signal
import subprocess
import argparse
from pathlib import Path


def find_free_display() -> int:
    """Find a free X11 display number."""
    for num in range(99, 200):
        socket_path = f"/tmp/.X11-unix/X{num}"
        if not os.path.exists(socket_path):
            return num
    return 99


def start_xvfb(display: int) -> subprocess.Popen:
    """Start Xvfb on the given display."""
    env = os.environ.copy()
    socket_dir = "/tmp/.X11-unix"
    os.makedirs(socket_dir, exist_ok=True)
    try:
        os.chmod(socket_dir, 0o777)
    except PermissionError:
        pass

    cmd = [
        "Xvfb",
        f":{display}",
        "-screen", "0", "1280x800x24",
        "-nolisten", "tcp",
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    # Wait for Xvfb to start
    time.sleep(2)
    return proc


def launch_ide(display: int, workspace: str, ide_path: str) -> subprocess.Popen:
    """Launch forge-ide on the given display."""
    env = os.environ.copy()
    env["DISPLAY"] = f":{display}"

    cmd = [ide_path, workspace]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    return proc


def capture_screenshot(display: int, output_path: str) -> bool:
    """Try to capture screenshot using available tools."""
    env = os.environ.copy()
    env["DISPLAY"] = f":{display}"

    # Try xwd + convert (ImageMagick)
    try:
        result = subprocess.run(
            ["xwd", "-root", "-silent"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout:
            # Convert xwd to png
            convert_result = subprocess.run(
                ["convert", "xwd:-", output_path],
                input=result.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if convert_result.returncode == 0:
                return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Try import (ImageMagick)
    try:
        result = subprocess.run(
            ["import", "-window", "root", output_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=5,
        )
        if result.returncode == 0:
            return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return False


def main():
    parser = argparse.ArgumentParser(description="Launch forge-ide under Xvfb")
    parser.add_argument("--workspace", default=".", help="Workspace path")
    parser.add_argument("--time", type=int, default=4, help="Seconds to run IDE")
    parser.add_argument("--screenshot", default=None, help="Screenshot output path")
    parser.add_argument("--ide-path", default=None, help="Path to forge-ide binary")
    args = parser.parse_args()

    # Find forge-ide binary
    if args.ide_path:
        ide_path = args.ide_path
    else:
        repo_root = Path(__file__).parent.parent
        ide_path = str(repo_root / "zig-out" / "bin" / "forge-ide")

    if not os.path.exists(ide_path):
        print(f"error: forge-ide not found at {ide_path}", file=sys.stderr)
        print("Run 'zig build' first.", file=sys.stderr)
        sys.exit(1)

    print(f"Starting Xvfb...")
    display = find_free_display()
    xvfb_proc = start_xvfb(display)
    print(f"Xvfb started on :{display} (PID {xvfb_proc.pid})")

    try:
        print(f"Launching forge-ide (workspace={args.workspace})...")
        ide_proc = launch_ide(display, args.workspace, ide_path)
        print(f"forge-ide started (PID {ide_proc.pid})")

        # Wait for IDE to initialize
        time.sleep(2)

        # Read available output
        import select
        readable, _, _ = select.select([ide_proc.stdout], [], [], 2.0)
        output = b""
        if readable:
            output = ide_proc.stdout.read1(4096) if hasattr(ide_proc.stdout, 'read1') else b""

        output_text = output.decode('utf-8', errors='replace')
        print("IDE output:")
        print(output_text[:2000] if output_text else "(no output)")

        # Check if IDE is still running
        if ide_proc.poll() is None:
            print(f"\n[OK] forge-ide is running after 2s")

            # Capture screenshot if requested
            if args.screenshot:
                print(f"Capturing screenshot to {args.screenshot}...")
                if capture_screenshot(display, args.screenshot):
                    print(f"[OK] Screenshot saved: {args.screenshot}")
                else:
                    print("[WARN] Screenshot capture failed (xwd/convert not available)")
                    print("       Install: sudo apt-get install x11-apps imagemagick")

            # Let it run for the specified time
            print(f"Letting IDE run for {args.time}s...")
            time.sleep(max(0, args.time - 2))
        else:
            print(f"[FAIL] forge-ide exited with code {ide_proc.returncode}")
            stderr = ide_proc.stderr.read().decode('utf-8', errors='replace')
            print(f"stderr: {stderr[:2000]}")

    finally:
        # Cleanup
        print("\nCleaning up...")
        if 'ide_proc' in locals():
            ide_proc.terminate()
            try:
                ide_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                ide_proc.kill()

        xvfb_proc.terminate()
        try:
            xvfb_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            xvfb_proc.kill()

    print("Done.")


if __name__ == "__main__":
    main()
