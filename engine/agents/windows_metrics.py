"""Read-only counters for the demo; returns None on non-Windows platforms."""
import ctypes
import os


def measure(pid: int):
    if os.name != "nt":
        return None
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    size_t = ctypes.c_size_t

    class Counters(ctypes.Structure):
        _fields_ = [("cb", w.DWORD), ("faults", w.DWORD),
                    ("peak_ws", size_t), ("ws", size_t),
                    ("peak_paged", size_t), ("paged", size_t),
                    ("peak_nonpaged", size_t), ("nonpaged", size_t),
                    ("pagefile", size_t), ("peak_pagefile", size_t),
                    ("private_commit", size_t)]

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("length", w.DWORD), ("load", w.DWORD),
                    ("total_physical", ctypes.c_ulonglong), ("available_physical", ctypes.c_ulonglong),
                    ("total_pagefile", ctypes.c_ulonglong), ("available_pagefile", ctypes.c_ulonglong),
                    ("total_virtual", ctypes.c_ulonglong), ("available_virtual", ctypes.c_ulonglong),
                    ("available_extended", ctypes.c_ulonglong)]

    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.CloseHandle.restype = w.BOOL
    psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.POINTER(Counters), w.DWORD]
    psapi.GetProcessMemoryInfo.restype = w.BOOL
    kernel.GlobalMemoryStatusEx.argtypes = [ctypes.POINTER(MemoryStatus)]
    kernel.GlobalMemoryStatusEx.restype = w.BOOL
    process = kernel.OpenProcess(0x1000, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        m = Counters(); m.cb = ctypes.sizeof(m)
        if not psapi.GetProcessMemoryInfo(process, ctypes.byref(m), m.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        s = MemoryStatus(); s.length = ctypes.sizeof(s)
        if not kernel.GlobalMemoryStatusEx(ctypes.byref(s)):
            raise ctypes.WinError(ctypes.get_last_error())
        return {"working_set_bytes": m.ws, "private_commit_bytes": m.private_commit,
                "system_available_bytes": s.available_physical}
    finally:
        kernel.CloseHandle(process)
