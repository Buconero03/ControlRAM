"""Demo cache uses explicitly disposable anonymous maps, not arbitrary app RAM."""
import argparse
import json
import mmap
import os
import sys
import threading
import time
from pathlib import Path
from cooperative import CacheAgent, MIB, SchedulingProbe, private_session


class MapCache:
    def __init__(self, megabytes: int):
        self._lock = threading.Lock()
        self._maps = []
        try:
            # Touch all pages so the demo does not report untouched reservations.
            for _ in range(megabytes):
                item = mmap.mmap(-1, MIB)
                try:
                    item[:] = b"X" * MIB
                except BaseException:
                    item.close()
                    raise
                self._maps.append(item)
        except BaseException:
            self.close()
            raise

    def size_bytes(self):
        with self._lock:
            return len(self._maps) * MIB

    def release(self, budget_bytes):
        released = 0
        with self._lock:
            while self._maps and released + MIB <= budget_bytes:
                self._maps[-1].close()
                self._maps.pop()
                released += MIB
        return released

    def close(self):
        with self._lock:
            for item in self._maps:
                item.close()
            self._maps.clear()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--session", required=True, type=Path)
    p.add_argument("--cache-mb", type=int, default=128)
    args = p.parse_args()
    if not 1 <= args.cache_mb <= 512:
        p.error("--cache-mb must be between 1 and 512")
    token = private_session(args.session)
    cache = MapCache(args.cache_mb)
    probe = SchedulingProbe()
    agent = CacheAgent(cache, token, probe.latency).start()
    try:
        description = {"version": 1, "pid": os.getpid(), "port": agent.port, "cache_bytes": cache.size_bytes()}
        (args.session / "agent.json").write_text(json.dumps(description), encoding="utf-8")
        print(f"Demo PID={os.getpid()} | disposable cache={args.cache_mb} MB | loopback port={agent.port}", flush=True)
        print("Only this demo cache can be released. Ctrl+C stops the demo you started.", flush=True)
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        agent.close()
        probe.close()
        cache.close()
        (args.session / "agent.json").unlink(missing_ok=True)
        (args.session / "token.txt").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
