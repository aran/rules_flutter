#!/usr/bin/env python3
"""Summarize a Bazel JSON execution log for the iOS perf bench.

Reads the log written by ``bazel build --execution_log_json_file`` (one JSON
object per executed spawn, concatenated; a ``{"spawns": [...]}`` wrapper is
also accepted) and reports, per scenario run: the executed action count by
mnemonic, and the total action CPU time (user+sys from each spawn's metrics)
plus wall time.

CPU note: the Linux sandbox runner does not populate ``userTime``/
``systemTime``; the macOS runner is expected to. ``cpu_time_available``
reports whether any spawn carried them, so a summary never mistakes missing
data for zero CPU. Wall time is always reported.
"""

import argparse
import json
import sys

def parse_duration(value):
    """Parses a JSON-proto duration to seconds.

    Accepts "1.234s" strings, plain numbers (seconds), and
    {"seconds": .., "nanos": ..} objects.
    """
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        return float(value.get("seconds", 0)) + float(value.get("nanos", 0)) / 1e9
    if isinstance(value, str):
        text = value.strip()
        if text.endswith("s"):
            text = text[:-1]
        if not text:
            return 0.0
        return float(text)
    raise ValueError("unparseable duration %r" % (value,))


def parse_int(value):
    if value is None:
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.strip():
        return int(value.strip())
    return 0


def load_spawns(path):
    """Loads every spawn object from an execution log file."""
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    decoder = json.JSONDecoder()
    spawns = []
    idx = 0
    while idx < len(raw):
        while idx < len(raw) and raw[idx].isspace():
            idx += 1
        if idx >= len(raw):
            break
        obj, idx = decoder.raw_decode(raw, idx)
        if isinstance(obj, dict) and isinstance(obj.get("spawns"), list):
            spawns.extend(o for o in obj["spawns"] if isinstance(o, dict))
        elif isinstance(obj, dict):
            spawns.append(obj)
        elif isinstance(obj, list):
            spawns.extend(o for o in obj if isinstance(o, dict))
        else:
            raise ValueError("unexpected execution log entry %r" % (obj,))
    return spawns


def summarize_spawns(spawns):
    """Aggregates spawns by mnemonic with CPU and wall totals."""
    by_mnemonic = {}
    total_wall = 0.0
    total_user = 0.0
    total_sys = 0.0
    cpu_time_available = False
    for spawn in spawns:
        mnemonic = spawn.get("mnemonic", "")
        metrics = spawn.get("metrics") or {}
        wall = parse_duration(metrics.get("executionWallTime"))
        user = parse_duration(metrics.get("userTime"))
        sys_ = parse_duration(metrics.get("systemTime"))
        if metrics.get("userTime") is not None or metrics.get("systemTime") is not None:
            cpu_time_available = True
        entry = by_mnemonic.setdefault(
            mnemonic, {"count": 0, "wall_s": 0.0, "cpu_user_s": 0.0, "cpu_sys_s": 0.0})
        entry["count"] += 1
        entry["wall_s"] += wall
        entry["cpu_user_s"] += user
        entry["cpu_sys_s"] += sys_
        total_wall += wall
        total_user += user
        total_sys += sys_
    return {
        "n_spawns": len(spawns),
        "by_mnemonic": by_mnemonic,
        "total_wall_s": total_wall,
        "total_cpu_user_s": total_user,
        "total_cpu_sys_s": total_sys,
        "cpu_time_available": cpu_time_available,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Summarize a Bazel JSON execution log.")
    parser.add_argument("--log", required=True, help="execution log path")
    parser.add_argument("--out", required=True, help="summary JSON path")
    args = parser.parse_args(argv)
    summary = summarize_spawns(load_spawns(args.log))
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print("spawns=%d cpu_time_available=%s"
          % (summary["n_spawns"], summary["cpu_time_available"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
