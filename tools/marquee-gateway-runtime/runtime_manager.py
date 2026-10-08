"""Local Gateway runner. Private bootstrap material is DPAPI protected, never logged."""
import base64
import csv
import runtime_configuration
import ctypes
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
from ctypes import wintypes
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parent
BINARY = ROOT / "marquee-gateway.exe"
PRIVATE = ROOT / "management.dpapi"
RUSTDESK_PRIVATE_DIR = ROOT / ".rustdesk-management"
RUSTDESK_PRIVATE = RUSTDESK_PRIVATE_DIR / "rustdesk-management.dpapi"
LEGACY_RUSTDESK_PRIVATE = ROOT / "rustdesk-management.dpapi"
CONFIG = ROOT / "configuration.dpapi"
RESTART_EXIT_CODE = 75

class Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]

def crypt(data, protect=False, machine=False):
    buf = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source, result = Blob(len(data), buf), Blob()
    library = ctypes.WinDLL("crypt32", use_last_error=True)
    operation = library.CryptProtectData if protect else library.CryptUnprotectData
    operation.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                          ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    operation.restype = wintypes.BOOL
    flags = 1 | (4 if machine else 0)
    if not operation(ctypes.byref(source), None, None, None, None, flags, ctypes.byref(result)):
        raise RuntimeError("Protected local material unavailable")
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        kernel = ctypes.WinDLL("kernel32")
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree(result.pbData)

def save_private(path, value):
    temp = path.with_suffix(".pending")
    temp.write_bytes(crypt(json.dumps(value).encode(), True))
    os.replace(temp, path)

def load_private(path=PRIVATE):
    return json.loads(crypt(path.read_bytes()))

def current_process_sid():
    system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    whoami = system_root / "System32" / "whoami.exe"
    result = subprocess.run(
        [str(whoami), "/user", "/fo", "csv", "/nh"],
        capture_output=True, text=True, timeout=5, check=True,
        creationflags=subprocess.CREATE_NO_WINDOW)
    row = next(csv.reader([result.stdout.strip()]))
    sid = row[-1].strip() if row else ""
    if not re.fullmatch(r"S-1-(?:\d+-)+\d+", sid, re.IGNORECASE):
        raise RuntimeError("Current Windows security identity unavailable")
    return sid

def set_private_directory_acl(path):
    sid = current_process_sid()
    descriptor_text = (
        "D:P"
        "(A;OICI;FA;;;SY)"
        "(A;OICI;FA;;;BA)"
        f"(A;OICI;FA;;;{sid})"
    )
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    convert = advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW
    convert.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
    convert.restype = wintypes.BOOL
    set_security = advapi.SetFileSecurityW
    set_security.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p]
    set_security.restype = wintypes.BOOL
    descriptor = ctypes.c_void_p()
    if not convert(descriptor_text, 1, ctypes.byref(descriptor), None):
        raise RuntimeError("Private Gateway ACL could not be created")
    try:
        security_information = 0x00000004 | 0x80000000
        if not set_security(str(path), security_information, descriptor):
            raise RuntimeError("Private Gateway ACL could not be applied")
    finally:
        kernel = ctypes.WinDLL("kernel32")
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree(descriptor)

def ensure_rustdesk_private_directory():
    RUSTDESK_PRIVATE_DIR.mkdir(exist_ok=True)
    set_private_directory_acl(RUSTDESK_PRIVATE_DIR)

def save_rustdesk_private(value):
    ensure_rustdesk_private_directory()
    temp = RUSTDESK_PRIVATE.with_suffix(".pending")
    temp.write_bytes(crypt(json.dumps(value).encode(), True, True))
    os.replace(temp, RUSTDESK_PRIVATE)

def load_rustdesk_private():
    return json.loads(crypt(RUSTDESK_PRIVATE.read_bytes(), False, True))

def prepare():
    candidates = []
    for path in (Path(os.environ["LOCALAPPDATA"]) / "MarqueeGatewayAcceptanceInput").glob("*.json"):
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        if value.get("silo_origin"):
            candidates.append((path.stat().st_mtime, value))
    cfg = max(candidates, key=lambda item: item[0])[1]
    dbpath = Path(cfg["state_dir"]) / "gateway.db"
    if not dbpath.is_file() or not BINARY.is_file():
        raise RuntimeError("Existing state or built executable unavailable")
    backup = ROOT / ("state-backup-" + time.strftime("%Y%m%d-%H%M%S") + ".db")
    if backup.exists():
        raise RuntimeError("Backup destination already exists")
    with sqlite3.connect(dbpath.as_uri() + "?mode=ro", uri=True) as source:
        with sqlite3.connect(backup) as destination:
            source.backup(destination)
    full = Path.home() / ".codex/tmp/ffmpeg-full-eval/extract-v1/ffmpeg-9.0.2-full_build/bin"
    cfg.update(listen_addr="127.0.0.1:9798", setup_listen="127.0.0.1:9799",
               ffmpeg_path=str(full / "ffmpeg.exe"), ffprobe_path=str(full / "ffprobe.exe"))
    save_private(CONFIG, cfg)
    print(json.dumps({"protected_state_backup_created": True, "runtime_configuration_prepared": True}))

def service_arguments(cfg):
    return runtime_configuration.service_arguments(cfg, BINARY, CONFIG, ROOT / 'lan-dashboard-configuration.dpapi')

def stop_owned_child(process):
    if process.poll() is None:
        try:
            process.send_signal(signal.CTRL_BREAK_EVENT)
        except OSError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)

def serve():
    ensure_rustdesk_private_directory()
    if LEGACY_RUSTDESK_PRIVATE.exists():
        LEGACY_RUSTDESK_PRIVATE.unlink()
    cfg = load_private(CONFIG)
    while True:
        cfg = load_private(CONFIG)
        if RUSTDESK_PRIVATE.exists():
            RUSTDESK_PRIVATE.unlink()
        child_environment = dict(os.environ)
        child_environment["MARQUEE_RUSTDESK_MANAGEMENT"] = "1"
        process = subprocess.Popen(service_arguments(cfg), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
                                   env=child_environment)
        try:
            (ROOT / "process.json").write_text(json.dumps({"runner_pid": os.getpid(), "gateway_pid": process.pid}))
            private = {'runtime_configuration': runtime_configuration.bootstrap_configuration(cfg)}
            labels = {"Gateway ID": "gateway_id", "SPKI pin": "pin", "Pairing code": "pairing_code",
                      "Setup certificate SHA-256 leaf fingerprint": "setup_fingerprint", "Setup code": "setup_code",
                      "LAN dashboard access token": "lan_dashboard_token",
                      "RustDesk management token": "rustdesk_management_token"}
            required = ("pin", "setup_fingerprint", "setup_code") + (("lan_dashboard_token",) if cfg.get("trusted_lan_dashboard") else ())
            for line in process.stdout:
                label, separator, value = line.strip().partition(": ")
                if separator and label in labels:
                    private[labels[label]] = value
                    if label == "RustDesk management token" and private.get("setup_fingerprint"):
                        save_rustdesk_private({
                            "management_token": value,
                            "setup_fingerprint": private["setup_fingerprint"],
                            "setup_listen": cfg["setup_listen"],
                        })
                if all(key in private for key in required):
                    save_private(PRIVATE, private)
            code = process.wait()
            (ROOT / "exit.json").write_text(json.dumps({"exit_code": code, "restart_requested": code == RESTART_EXIT_CODE}))
        finally:
            stop_owned_child(process)
            process.stdout.close()
        if code != RESTART_EXIT_CODE:
            return

class PinnedConnection(http.client.HTTPSConnection):
    def __init__(self, setup=False):
        self.setup = setup
        self.material = load_private()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        cfg = runtime_configuration.active_configuration(self.material, load_private(CONFIG))
        host, port = cfg['setup_listen' if setup else 'listen_addr'].rsplit(':', 1)
        super().__init__(host, int(port), timeout=20, context=context)

    def connect(self):
        super().connect()
        der = self.sock.getpeercert(binary_form=True)
        if self.setup:
            valid = hashlib.sha256(der).hexdigest() == self.material["setup_fingerprint"]
        else:
            public = x509.load_der_x509_certificate(der).public_key().public_bytes(
                serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
            pin = "sha256/" + base64.b64encode(hashlib.sha256(public).digest()).decode()
            valid = pin == self.material["pin"]
        if not valid:
            self.close()
            raise RuntimeError("Local Gateway certificate does not match trusted process bootstrap")

def request(path, method="GET", data=None, headers=None, setup=False):
    connection = PinnedConnection(setup)
    try:
        connection.request(method, path, data, headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()

def dashboard():
    material = load_private()
    if not material.get("setup_cookie"):
        status, headers, _ = request("/setup/claim", "POST", urlencode({"code": material["setup_code"]}),
            {"Origin": "https://127.0.0.1:9799", "Content-Type": "application/x-www-form-urlencoded"}, True)
        if status != 303 or "Set-Cookie" not in headers:
            raise RuntimeError("Local setup claim did not succeed")
        material["setup_cookie"] = headers["Set-Cookie"].split(";", 1)[0]
        save_private(PRIVATE, material)
    status, _, body = request("/setup", headers={"Cookie": material["setup_cookie"]}, setup=True)
    if status != 200:
        raise RuntimeError("Local dashboard unavailable")
    page = body.decode()
    csrf = re.search(r'name="csrf" value="([^"]+)"', page)
    if csrf:
        material["csrf"] = csrf.group(1)
        save_private(PRIVATE, material)
    print(json.dumps({"dashboard_http_status": status, "authenticated_dashboard": "Sign out" in page,
                      "silo_verified": bool(re.search(r'>Verified<', page)),
                      "silo_connected": bool(re.search(r'>Connected<', page)),
                      "profile_needs_verification": "ProfileNeedsPIN" in page or "Re-verify" in page or "requires verification" in page,
                      "revoked": bool(re.search(r'>Revoked<', page)),
                      "temporarily_unavailable": "Temporarily unavailable" in page}))

def refresh_pairing():
    cfg = load_private(CONFIG)
    result = subprocess.run([str(BINARY), "pair", "--state-dir", cfg["state_dir"]], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError("Pairing window could not be opened")
    match = re.search(r'^Pairing code: (.+)$', result.stdout, re.M)
    if not match:
        raise RuntimeError("Pairing code unavailable")
    material = load_private()
    material["pairing_code"] = match.group(1).strip()
    save_private(PRIVATE, material)
    print(json.dumps({"pairing_window_opened": True}))

def health():
    status, _, body = request("/v1/health")
    result = json.loads(body)
    print(json.dumps({"gateway_https_status": status, "gateway_health": result.get("status"),
                      "api_version": result.get("api_version"), "trusted_pin_matched": True}))

class RustDeskManagementConnection(http.client.HTTPSConnection):
    def __init__(self, material):
        self.material = material
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        host, port = material["setup_listen"].rsplit(":", 1)
        if host != "127.0.0.1":
            raise RuntimeError("RustDesk management endpoint is not loopback")
        super().__init__(host, int(port), timeout=5, context=context)

    def connect(self):
        super().connect()
        der = self.sock.getpeercert(binary_form=True)
        if hashlib.sha256(der).hexdigest() != self.material["setup_fingerprint"]:
            self.close()
            raise RuntimeError("RustDesk management certificate pin mismatch")

def rustdesk_management_request(path, method="GET", payload=None):
    material = load_rustdesk_private()
    token = material.get("management_token", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
        raise RuntimeError("RustDesk management authority unavailable")
    connection = RustDeskManagementConnection(material)
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    headers = {"Authorization": "Bearer " + token}
    if body is not None:
        headers["Content-Type"] = "application/json"
    try:
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        raw = response.read(65537)
        if len(raw) > 65536:
            raise RuntimeError("RustDesk management response too large")
        if response.status < 200 or response.status >= 300:
            raise RuntimeError("RustDesk management request rejected")
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise RuntimeError("RustDesk management response invalid")
        return result
    finally:
        connection.close()

def rustdesk_status():
    print(json.dumps(rustdesk_management_request("/v1/local-management/status"), separators=(",", ":")))

def rustdesk_imdb_enabled():
    if len(sys.argv) != 3 or sys.argv[2] not in ("true", "false"):
        raise RuntimeError("Invalid IMDb enabled value")
    result = rustdesk_management_request(
        "/v1/local-management/imdb/enabled", "POST", {"enabled": sys.argv[2] == "true"})
    print(json.dumps(result, separators=(",", ":")))

def rustdesk_imdb_refresh():
    print(json.dumps(
        rustdesk_management_request("/v1/local-management/imdb/refresh", "POST", {}),
        separators=(",", ":")))

def rustdesk_restart():
    print(json.dumps(
        rustdesk_management_request("/v1/local-management/restart", "POST", {}),
        separators=(",", ":")))

if __name__ == "__main__":
    try:
        {"prepare": prepare, "serve": serve, "health": health,
         "dashboard": dashboard, "pair": refresh_pairing,
         "rustdesk-status": rustdesk_status,
         "rustdesk-imdb-enabled": rustdesk_imdb_enabled,
         "rustdesk-imdb-refresh": rustdesk_imdb_refresh,
         "rustdesk-restart": rustdesk_restart}[sys.argv[1]]()
    except Exception as error:
        print(json.dumps({"operation_failed": True, "error_class": type(error).__name__}))
        sys.exit(1)
