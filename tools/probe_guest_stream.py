"""Opt-in live probe of the pinned guest helper; never touches shared ADB state."""

import argparse
import hashlib
import json
import secrets
import socket
import struct
import subprocess
import time
from pathlib import Path

HELPER_SHA256 = "84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a"


def read_exact(stream, size):
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.recv(size - len(chunks))
        if not chunk:
            raise EOFError("Guest video socket closed")
        chunks.extend(chunk)
    return bytes(chunks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--helper", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--test-navigation", action="store_true")
    parser.add_argument("--navigation-key", type=int, default=187)
    parser.add_argument("--capture-navigation", action="store_true")
    parser.add_argument("--tap", type=int, nargs=2, metavar=("X", "Y"))
    args = parser.parse_args()
    helper = Path(args.helper)
    if hashlib.sha256(helper.read_bytes()).hexdigest() != HELPER_SHA256:
        raise ValueError("Pinned helper checksum mismatch")
    prefix = [args.adb, "-s", args.serial]

    def adb(*arguments):
        return subprocess.check_output(prefix + list(arguments), timeout=20, text=True).strip()

    scid = secrets.randbits(31)
    jar = f"/data/local/tmp/mirpg-scrcpy-{scid:08x}.jar"
    socket_name = f"localabstract:scrcpy_{scid:08x}"
    port = None
    process = None
    streams = []
    log = Path(args.output).with_suffix(".log")
    try:
        adb("push", str(helper), jar)
        port = int(adb("forward", "tcp:0", socket_name))
        with log.open("wb") as log_file:
            process = subprocess.Popen(prefix + [
                "shell", f"CLASSPATH={jar}", "app_process", "/",
                "com.genymobile.scrcpy.Server", "4.0", f"scid={scid:08x}",
                "tunnel_forward=true", "audio=false", "video_codec=h264",
                "send_device_meta=false", "send_dummy_byte=false",
                "clipboard_autosync=false", "power_on=false", "cleanup=false",
                "max_size=1280", "max_fps=30", "video_bit_rate=4000000",
            ], stdout=log_file, stderr=subprocess.STDOUT)
            # Forward sockets may accept before the guest has bound its socket.
            # Retry only before receiving codec metadata, never mid-stream.
            deadline = time.monotonic() + 15
            while True:
                video = socket.create_connection(("127.0.0.1", port), timeout=3)
                control = socket.create_connection(("127.0.0.1", port), timeout=3)
                try:
                    codec = read_exact(video, 4)
                    streams = [video, control]
                    break
                except (EOFError, OSError):
                    video.close()
                    control.close()
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError(f"Guest startup failed; see {log}")
                    time.sleep(0.15)
            if codec != b"h264":
                raise ValueError(f"Unexpected codec {codec!r}")
            sessions = []
            frames = []
            navigation_sent = False
            navigation_focus = []
            touch_sent = False
            touch_focus = None
            with Path(args.output).open("wb") as output:
                for _ in range(90):
                    try:
                        header = read_exact(video, 12)
                    except TimeoutError:
                        if any(frame["key"] for frame in frames):
                            break  # Static Android displays need not produce more frames.
                        raise
                    flags, length = struct.unpack(">QI", header)
                    if flags & (1 << 63):
                        _, width, height = struct.unpack(">III", header)
                        sessions.append({"width": width, "height": height})
                        continue
                    if length == 0 or length > 8 * 1024 * 1024:
                        raise ValueError(f"Invalid frame length {length}")
                    payload = read_exact(video, length)
                    output.write(payload)
                    frames.append({"config": bool(flags & (1 << 62)),
                                   "key": bool(flags & (1 << 61)),
                                   "pts_us": flags & ((1 << 61) - 1), "bytes": length})
                    if args.test_navigation and not navigation_sent and any(frame["key"] for frame in frames):
                        # Open/close Recents to prove persistent control without launching apps.
                        for key in (args.navigation_key, 4):
                            for action in (0, 1):
                                control.sendall(struct.pack(">BBIII", 0, action, key, 0, 0))
                            time.sleep(0.5)
                            focus = adb("shell", "dumpsys", "activity", "activities")
                            navigation_focus.append(next((line.strip() for line in focus.splitlines() if "topResumedActivity=" in line), "unavailable"))
                            if args.capture_navigation:
                                capture = subprocess.check_output(prefix + ["exec-out", "screencap", "-p"], timeout=15)
                                Path(args.output).with_suffix(f".key-{key}.png").write_bytes(capture)
                        navigation_sent = True
                    if args.tap and not touch_sent and any(frame["key"] for frame in frames):
                        x, y = args.tap
                        width, height = sessions[-1]["width"], sessions[-1]["height"]
                        if not (0 <= x < width and 0 <= y < height):
                            raise ValueError("Tap must be inside the streamed guest dimensions")
                        for action in (0, 1):
                            control.sendall(struct.pack(">BBQIIHHHII", 2, action, 0, x, y, width, height,
                                                        65535 if action == 0 else 0,
                                                        1 if action == 0 else 0,
                                                        1 if action == 0 else 0))
                            time.sleep(0.1)
                        time.sleep(1)
                        focus = adb("shell", "dumpsys", "activity", "activities")
                        touch_focus = next((line.strip() for line in focus.splitlines() if "topResumedActivity=" in line), "unavailable")
                        capture = subprocess.check_output(prefix + ["exec-out", "screencap", "-p"], timeout=15)
                        Path(args.output).with_suffix(".tap.png").write_bytes(capture)
                        touch_sent = True
            print(json.dumps({"codec": codec.decode(), "sessions": sessions,
                              "frames": len(frames), "keys": sum(f["key"] for f in frames),
                              "configuration_packets": sum(f["config"] for f in frames),
                              "first_pts_us": frames[1]["pts_us"] if len(frames) > 1 else None,
                              "navigation_sent": navigation_sent,
                              "navigation_focus": navigation_focus, "touch_sent": touch_sent,
                              "touch_focus": touch_focus, "output": args.output}))
    finally:
        for stream in streams:
            stream.close()
        if process is not None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Match this invocation's unique SCID; never kill shared ADB or other helpers.
                pids = adb("shell", "pidof", "app_process")
                for pid in pids.split():
                    if pid.isdecimal():
                        command = adb("shell", "cat", f"/proc/{pid}/cmdline")
                        if f"scid={scid:08x}" in command:
                            adb("shell", "kill", pid)
                process.terminate()
                process.wait(timeout=5)
        if port is not None:
            adb("forward", "--remove", f"tcp:{port}")
        adb("shell", "rm", "-f", jar)


if __name__ == "__main__":
    main()
