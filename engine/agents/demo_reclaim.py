"""One manual cache release test. Never tries to make system RAM hit 95%."""
import argparse
import json
import time
from pathlib import Path
from cooperative import MIB, request
from windows_metrics import measure


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    descriptor = json.loads((args.session / "agent.json").read_text(encoding="utf-8"))
    token = (args.session / "token.txt").read_text(encoding="ascii").strip()
    before = request(descriptor["port"], token)
    if before[0] != descriptor["pid"]:
        raise RuntimeError("Agent PID changed")
    before_metrics = measure(before[0])
    after = request(descriptor["port"], token, "RECLAIM", 64 * MIB)
    if after[0] != before[0] or after[2] > 64 * MIB or before[1] - after[1] != after[2]:
        raise RuntimeError("Inconsistent release result")
    time.sleep(0.2)
    alive = request(descriptor["port"], token)
    after_metrics = measure(alive[0])
    print(f"PID {before[0]} remains running: {alive[0] == before[0]}")
    print(f"Demo cache: {before[1] // MIB} -> {after[1] // MIB} MB")
    print(f"Explicitly closed cache maps: {after[2] // MIB} MB")
    if before_metrics is not None and after_metrics is not None:
        print(f"Windows process working set: {before_metrics['working_set_bytes'] / MIB:.1f} -> {after_metrics['working_set_bytes'] / MIB:.1f} MB")
        print(f"Windows private commit: {before_metrics['private_commit_bytes'] / MIB:.1f} -> {after_metrics['private_commit_bytes'] / MIB:.1f} MB")
        print(f"System available delta: {(after_metrics['system_available_bytes'] - before_metrics['system_available_bytes']) / MIB:.1f} MB (other apps also affect this)")
    evidence = {"pid": alive[0], "cache_before_bytes": before[1], "cache_after_bytes": after[1],
                "released_cache_bytes": after[2], "process_still_running": alive[0] == before[0],
                "windows_before": before_metrics, "windows_after": after_metrics}
    (args.session / "demo-result.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print("This is not a measured claim about system-wide RAM savings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
