"""Bridge saved runtime settings to the already running Gateway generation."""
import ctypes
from ctypes import wintypes
from pathlib import Path


def physical_state_directory(directory):
    # Packaged Windows applications can redirect the main database while old
    # sidecars fall through to another directory. Resolve the actual file handle
    # before SQLite chooses its WAL/SHM filenames. Never create empty state here.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.GetFinalPathNameByHandleW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD]
    kernel.GetFinalPathNameByHandleW.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateFileW(str(Path(directory) / 'gateway.db'), 0, 7, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        raise OSError('Existing Gateway database unavailable')
    try:
        buffer = ctypes.create_unicode_buffer(32768)
        size = kernel.GetFinalPathNameByHandleW(handle, buffer, len(buffer), 0)
        if not size or size >= len(buffer):
            raise OSError('Gateway database location unavailable')
        path = buffer.value
        if path.startswith('\\\\?\\UNC\\'):
            path = '\\\\' + path[8:]
        elif path.startswith('\\\\?\\'):
            path = path[4:]
        return str(Path(path).parent)
    finally:
        kernel.CloseHandle(handle)


def bootstrap_configuration(saved):
    # Only the values needed by local transport belong in protected bootstrap.
    return {key: saved[key] for key in ('listen_addr', 'setup_listen', 'dashboard') if key in saved}


def active_configuration(material, saved):
    active = dict(saved)
    active.update(material.get('runtime_configuration', {}))
    return active


def dashboard_configuration(material, original):
    active = dict(original)
    generation = material.get('runtime_configuration', {})
    active.update(generation.get('dashboard', {}))
    if generation.get('setup_listen'):
        active['upstream_addr'] = generation['setup_listen']
    return active


def service_arguments(saved, binary, runtime_path, dashboard_path):
    args = [str(binary), 'serve', '--listen', saved['listen_addr'], '--setup-listen', saved['setup_listen'],
            '--state-dir', physical_state_directory(saved['state_dir']), '--silo-origin', saved['silo_origin'],
            '--ffmpeg', saved['ffmpeg_path'], '--ffprobe', saved['ffprobe_path'],
            '--max-sessions', str(saved.get('max_sessions', 1)),
            '--runtime-config', str(runtime_path), '--dashboard-config', str(dashboard_path)]
    for origin in saved.get('external_media_origins', []):
        args += ['--external-media-origin', origin]
    if saved.get('trusted_lan_dashboard'):
        args.append('--trusted-lan-dashboard')
    return args
