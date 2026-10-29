"""Local cooperative cache protocol. No process injection, GC or arbitrary code.

Embed CacheAgent in an application that owns a DiscardableCache implementation.
Only its explicit release callback may discard data. Transport is loopback TCP,
bounded, versioned and authenticated; there is no remote listening address.
"""
from __future__ import annotations
import ctypes
import hmac
import math
import os
import secrets
import socket
import threading
import time
from collections import deque
from pathlib import Path
from typing import Protocol

MIB = 1024 * 1024
MAX_BUDGET = 64 * MIB


class DiscardableCache(Protocol):
    def size_bytes(self) -> int: ...
    def release(self, budget_bytes: int) -> int: ...


def private_session(directory: Path) -> str:
    """Create a new current-user-only directory and token. Never reuse a session."""
    token = secrets.token_hex(32)
    directory.parent.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        directory.mkdir(mode=0o700)
        fd = os.open(directory / "token.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as f:
            f.write(token + "\n")
        return token
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
    advapi.OpenProcessToken.restype = w.BOOL
    advapi.GetTokenInformation.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)]
    advapi.GetTokenInformation.restype = w.BOOL
    advapi.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(w.LPWSTR)]
    advapi.ConvertSidToStringSidW.restype = w.BOOL
    advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [w.LPCWSTR, w.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(w.DWORD)]
    advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = w.BOOL
    kernel.GetCurrentProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.CloseHandle.restype = w.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    handle = w.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 0x0008, ctypes.byref(handle)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        size = w.DWORD()
        advapi.GetTokenInformation(handle, 1, None, 0, ctypes.byref(size))
        buf = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(handle, 1, buf, size, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        sid_pointer = ctypes.cast(buf, ctypes.POINTER(ctypes.c_void_p))[0]
        sid_string = w.LPWSTR()
        if not advapi.ConvertSidToStringSidW(sid_pointer, ctypes.byref(sid_string)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            sid = sid_string.value
        finally:
            kernel.LocalFree(ctypes.cast(sid_string, ctypes.c_void_p))
    finally:
        kernel.CloseHandle(handle)
    descriptor = ctypes.c_void_p()
    # Protected DACL, current user only; inherited by files and directories.
    sddl = f"D:P(A;OICI;FA;;;{sid})"
    if not advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, ctypes.byref(descriptor), None):
        raise ctypes.WinError(ctypes.get_last_error())

    class SecurityAttributes(ctypes.Structure):
        _fields_ = [("length", w.DWORD), ("descriptor", ctypes.c_void_p), ("inherit", w.BOOL)]

    attrs = SecurityAttributes(ctypes.sizeof(SecurityAttributes), descriptor, False)
    kernel.CreateDirectoryW.argtypes = [w.LPCWSTR, ctypes.POINTER(SecurityAttributes)]
    kernel.CreateDirectoryW.restype = w.BOOL
    try:
        if not kernel.CreateDirectoryW(str(directory.resolve()), ctypes.byref(attrs)):
            raise ctypes.WinError(ctypes.get_last_error())
        with (directory / "token.txt").open("x", encoding="ascii") as f:
            f.write(token + "\n")
    finally:
        kernel.LocalFree(descriptor)
    return token


class CacheAgent:
    """Single-client server: application cache callbacks must be thread-safe.

    latency_probe must return an application-defined recent latency in ms.
    The demo uses scheduling drift; real integrations should use useful-work
    latency (e.g. p95 request latency), not infer it from CPU or RAM.
    """
    def __init__(self, cache: DiscardableCache, token: str, latency_probe, cooldown_seconds: float = 60):
        if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
            raise ValueError("Invalid token")
        if not math.isfinite(cooldown_seconds) or cooldown_seconds < 0:
            raise ValueError("Invalid cooldown")
        self.cache, self.token, self.latency_probe = cache, token, latency_probe
        self.cooldown = cooldown_seconds
        self.last_release = -math.inf
        self._stop = threading.Event()
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # No SO_REUSEADDR: fail rather than share a port on Windows.
        self._listener.bind(("127.0.0.1", 0))
        self.port = self._listener.getsockname()[1]
        self._listener.listen(4)
        self._listener.settimeout(0.2)
        self._thread = threading.Thread(target=self._serve, name="AME-cache-agent", daemon=True)

    def start(self):
        self._thread.start()
        return self

    def close(self):
        self._stop.set()
        self._thread.join(timeout=3)
        self._listener.close()
        if self._thread.is_alive():
            raise RuntimeError("Agent callback did not finish; callbacks must be bounded")

    def _serve(self):
        while not self._stop.is_set():
            try:
                client, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with client:
                try:
                    client.settimeout(1)
                    data = bytearray()
                    deadline = time.monotonic() + 1.5
                    while b"\n" not in data and len(data) < 256:
                        part = client.recv(min(256 - len(data), 256))
                        if not part or time.monotonic() > deadline:
                            break
                        data.extend(part)
                    if not data.endswith(b"\n") or data.count(b"\n") != 1 or len(data) >= 256:
                        reply = "AME1 ERR frame\n"
                    else:
                        reply = self._handle(data.decode("ascii", errors="strict").strip())
                    client.sendall(reply.encode("ascii"))
                except (OSError, UnicodeError, ValueError):
                    pass

    def _handle(self, message: str) -> str:
        parts = message.split()
        if len(parts) != 4 or parts[0] != "AME1":
            return "AME1 ERR protocol\n"
        if not hmac.compare_digest(parts[1], self.token):
            return "AME1 ERR auth\n"
        command, raw_budget = parts[2:]
        if not raw_budget.isascii() or not raw_budget.isdigit() or len(raw_budget) > 10:
            return "AME1 ERR budget\n"
        budget = int(raw_budget)
        if command not in ("STATUS", "RECLAIM") or (command == "STATUS" and budget != 0) or (command == "RECLAIM" and not 0 < budget <= MAX_BUDGET):
            return "AME1 ERR request\n"
        try:
            latency = float(self.latency_probe())
            if not math.isfinite(latency) or latency < 0:
                return "AME1 ERR latency\n"
            released = 0
            if command == "RECLAIM":
                now = time.monotonic()
                if latency > 20:
                    return "AME1 ERR busy\n"
                if now - self.last_release < self.cooldown:
                    return "AME1 ERR cooldown\n"
                # Mark before callback so failures cannot cause immediate retries.
                self.last_release = now
                released = self.cache.release(budget)
                if not isinstance(released, int) or not 0 <= released <= budget:
                    return "AME1 ERR callback\n"
            remaining = self.cache.size_bytes()
            if not isinstance(remaining, int) or not 0 <= remaining <= 1024 * 1024 * MIB:
                return "AME1 ERR cache\n"
            return f"AME1 OK {os.getpid()} {remaining} {released} {latency:.3f}\n"
        except Exception:
            # Never send internal exception strings or token contents to clients.
            return "AME1 ERR callback\n"


class SchedulingProbe:
    """Demo heartbeat drift; not a global Windows responsiveness measurement."""
    def __init__(self):
        self._values = deque(maxlen=200)
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        target = time.monotonic() + 0.05
        while not self._stop.wait(max(0, target - time.monotonic())):
            now = time.monotonic()
            with self._lock:
                self._values.append(max(0, now - target) * 1000)
            target = now + 0.05

    def latency(self):
        with self._lock:
            values = sorted(self._values)
        return values[max(0, math.ceil(len(values) * 0.95) - 1)] if values else 0.0

    def close(self):
        self._stop.set()
        self._thread.join(timeout=1)


def request(port: int, token: str, command: str = "STATUS", budget: int = 0) -> tuple[int, int, int, float]:
    with socket.create_connection(("127.0.0.1", port), timeout=2) as conn:
        conn.sendall(f"AME1 {token} {command} {budget}\n".encode("ascii"))
        data = bytearray()
        while b"\n" not in data and len(data) < 512:
            chunk = conn.recv(512 - len(data))
            if not chunk:
                break
            data.extend(chunk)
    text = data.decode("ascii").split()
    if len(text) != 6 or text[:2] != ["AME1", "OK"]:
        raise RuntimeError("Agent refused request: " + " ".join(text[:3]))
    return int(text[2]), int(text[3]), int(text[4]), float(text[5])
