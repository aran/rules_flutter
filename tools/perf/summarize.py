#!/usr/bin/env python3
"""Summarize iOS bench repeats into one JSON + Markdown report.

Reads a results tree laid out by the perf-ios workflow::

    <results>/<ref>/<config>/<scenario>/rep<k>/{execlog.json,replay.json}

where ``execlog.json`` is :mod:`execlog` output and ``replay.json`` is
:mod:`replay` output. For every config, scenario and metric it reports the
median and spread (min/max) over repeats, per ref, plus the head-vs-base
delta.
"""

import argparse
import datetime
import json
import os
import sys


def median(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[len(ordered) // 2]


def summarize_values(values):
    if not values:
        return {"n": 0, "median": None, "min": None, "max": None}
    return {
        "n": len(values),
        "median": median(values),
        "min": min(values),
        "max": max(values),
    }


def delta_pct(head, base):
    if head is None or base is None or base == 0:
        return None
    return (head - base) / abs(base) * 100.0


def scenario_metrics(exe_summaries, replay_reports):
    """Per-repeat metric vectors for one scenario of one ref."""
    n_actions = [s["n_spawns"] for s in exe_summaries]
    wall = [s["total_wall_s"] for s in exe_summaries]
    cpu = [s["total_cpu_user_s"] + s["total_cpu_sys_s"] for s in exe_summaries]
    instr = []
    n_replayed = [report.get("n_replayed", 0) for report in replay_reports]
    for report in replay_reports:
        total = 0
        complete = True
        for action in report.get("actions", []):
            if action.get("instructions") is None:
                complete = False
            else:
                total += action["instructions"]
        instr.append(total if complete else None)
    instructions_available = any(
        action.get("instructions") is not None
        for report in replay_reports
        for action in report.get("actions", []))
    by_mnemonic = {}
    for s in exe_summaries:
        for mnemonic, entry in s.get("by_mnemonic", {}).items():
            by_mnemonic.setdefault(mnemonic, []).append(entry["count"])
    skipped = {}
    for report in replay_reports:
        for key, count in report.get("skipped_by_mnemonic", {}).items():
            skipped.setdefault(key, []).append(count)
    replay_failures = {}
    replay_cpu_s = {}
    failure_samples = {}
    truncated = []
    for report in replay_reports:
        truncated.append(bool(report.get("truncated")))
        for mnemonic, entry in report.get("by_mnemonic", {}).items():
            replay_failures.setdefault(mnemonic, []).append(
                entry.get("failures", 0))
            replay_cpu_s.setdefault(mnemonic, []).append(
                entry.get("user_s_total", 0.0)
                + entry.get("sys_s_total", 0.0))
            sample = entry.get("sample_failure")
            if sample is not None and mnemonic not in failure_samples:
                failure_samples[mnemonic] = sample
    return {
        "n_actions": n_actions,
        "wall_s": wall,
        "cpu_s": cpu,
        "instructions": [v for v in instr if v is not None],
        "instructions_complete": len(instr) > 0 and all(
            v is not None for v in instr),
        "instructions_available": instructions_available,
        "n_replayed": n_replayed,
        "by_mnemonic_counts": by_mnemonic,
        "skipped": skipped,
        "replay_failures": replay_failures,
        "replay_cpu_s": replay_cpu_s,
        "failure_samples": failure_samples,
        "truncated": truncated,
    }


def compare_metrics(base_m, head_m):
    """Median/spread per metric per ref plus head-vs-base deltas."""
    out = {}
    for key in ["n_actions", "wall_s", "cpu_s", "instructions"]:
        base = summarize_values(base_m[key])
        head = summarize_values(head_m[key])
        out[key] = {
            "base": base,
            "head": head,
            "delta_pct": delta_pct(head["median"], base["median"]),
        }
    mnemonics = sorted(
        set(base_m["by_mnemonic_counts"]) | set(head_m["by_mnemonic_counts"]))
    by_mnemonic = {}
    for mnemonic in mnemonics:
        base = summarize_values(base_m["by_mnemonic_counts"].get(mnemonic, []))
        head = summarize_values(head_m["by_mnemonic_counts"].get(mnemonic, []))
        by_mnemonic[mnemonic] = {
            "base": base,
            "head": head,
            "delta_pct": delta_pct(head["median"], base["median"]),
        }
    out["by_mnemonic"] = by_mnemonic
    skipped = {}
    for key in sorted(set(base_m.get("skipped", {}))
                      | set(head_m.get("skipped", {}))):
        skipped[key] = {
            "base": summarize_values(base_m["skipped"].get(key, [])),
            "head": summarize_values(head_m["skipped"].get(key, [])),
        }
    out["skipped"] = skipped
    out["instructions_complete"] = {
        "base": base_m["instructions_complete"],
        "head": head_m["instructions_complete"],
    }
    failures = {}
    for mnemonic in sorted(
            set(base_m["replay_failures"]) | set(head_m["replay_failures"])):
        failures[mnemonic] = {
            "base": summarize_values(
                base_m["replay_failures"].get(mnemonic, [])),
            "head": summarize_values(
                head_m["replay_failures"].get(mnemonic, [])),
        }
    out["replay_failures"] = failures
    replay_cpu = {}
    for mnemonic in sorted(
            set(base_m["replay_cpu_s"]) | set(head_m["replay_cpu_s"])):
        replay_cpu[mnemonic] = {
            "base": summarize_values(
                base_m["replay_cpu_s"].get(mnemonic, [])),
            "head": summarize_values(
                head_m["replay_cpu_s"].get(mnemonic, [])),
        }
    out["replay_cpu_s"] = replay_cpu
    samples = {}
    for mnemonic in sorted(
            set(base_m["failure_samples"]) | set(head_m["failure_samples"])):
        samples[mnemonic] = {
            "base": base_m["failure_samples"].get(mnemonic),
            "head": head_m["failure_samples"].get(mnemonic),
        }
    out["failure_samples"] = samples
    out["instructions_available"] = {
        "base": base_m["instructions_available"],
        "head": head_m["instructions_available"],
    }
    out["n_replayed"] = {
        "base": sum(base_m["n_replayed"]),
        "head": sum(head_m["n_replayed"]),
    }
    out["truncated"] = {
        "base": any(base_m["truncated"]),
        "head": any(head_m["truncated"]),
    }
    out["repeats"] = {
        "base": len(base_m["n_actions"]),
        "head": len(head_m["n_actions"]),
    }
    return out


def load_collection(results_dir, ref, config, scenario):
    exe_summaries = []
    replay_reports = []
    scenario_dir = os.path.join(results_dir, ref, config, scenario)
    if not os.path.isdir(scenario_dir):
        return ([], [])
    for rep in sorted(os.listdir(scenario_dir)):
        rep_dir = os.path.join(scenario_dir, rep)
        exe_path = os.path.join(rep_dir, "execlog.json")
        replay_path = os.path.join(rep_dir, "replay.json")
        if not (os.path.isfile(exe_path) and os.path.isfile(replay_path)):
            continue
        with open(exe_path, encoding="utf-8") as fh:
            exe_summaries.append(json.load(fh))
        with open(replay_path, encoding="utf-8") as fh:
            replay_reports.append(json.load(fh))
    return (exe_summaries, replay_reports)


def discover_configs(results_dir, ref):
    ref_dir = os.path.join(results_dir, ref)
    if not os.path.isdir(ref_dir):
        return []
    return sorted(
        d for d in os.listdir(ref_dir)
        if os.path.isdir(os.path.join(ref_dir, d)))


def build_summary(results_dir, base_ref, head_ref, meta):
    configs = sorted(set(discover_configs(results_dir, base_ref))
                     | set(discover_configs(results_dir, head_ref)))
    summary = {
        "base_ref": base_ref,
        "head_ref": head_ref,
        "meta": meta,
        "configs": {},
    }
    for config in configs:
        scenarios = []
        for ref in [base_ref, head_ref]:
            config_dir = os.path.join(results_dir, ref, config)
            if os.path.isdir(config_dir):
                scenarios.extend(
                    d for d in os.listdir(config_dir)
                    if os.path.isdir(os.path.join(config_dir, d)))
        compared = {}
        for scenario in sorted(set(scenarios)):
            base_exe, base_replay = load_collection(
                results_dir, base_ref, config, scenario)
            head_exe, head_replay = load_collection(
                results_dir, head_ref, config, scenario)
            if not base_exe or not head_exe:
                compared[scenario] = {"error": "missing repeats"}
                continue
            compared[scenario] = compare_metrics(
                scenario_metrics(base_exe, base_replay),
                scenario_metrics(head_exe, head_replay))
        summary["configs"][config] = {"scenarios": compared}
    return summary


def fmt(value, unit=""):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return "%.2f%s" % (value, unit)
    return "%s%s" % (value, unit)


def fmt_delta(value):
    if value is None:
        return "n/a"
    return "%+.1f%%" % value


def render_markdown(summary):
    lines = []
    lines.append("# iOS bench: %s vs %s" % (
        summary["head_ref"], summary["base_ref"]))
    lines.append("")
    meta = summary.get("meta", {})
    for key in sorted(meta):
        lines.append("- %s: %s" % (key, meta[key]))
    lines.append("")
    versions = {}
    for key in ["base_stats", "head_stats"]:
        stats = meta.get(key)
        if isinstance(stats, dict) and "generator_version" in stats:
            versions[key] = stats["generator_version"]
    if versions and not (
            len(versions) == 2 and len(set(versions.values())) == 1):
        # A v1 (unversioned) vs v2 workspace, or two different versions:
        # the generated programs differ in shape, so the numbers are never
        # comparable.
        lines.append("warning: generator workspace stats differ in shape "
                     "(base_stats generator_version=%s, head_stats "
                     "generator_version=%s): numbers across generator "
                     "versions are not comparable." % (
                         versions.get("base_stats"),
                         versions.get("head_stats")))
        lines.append("")
    lines.append("Medians over repeats; spread is [min, max]. "
                 "Delta is head-vs-base on the medians.")
    lines.append("")
    for config in sorted(summary["configs"]):
        config_entry = summary["configs"][config]
        for scenario in sorted(config_entry["scenarios"]):
            lines.append("## %s / %s" % (config, scenario))
            lines.append("")
            entry = config_entry["scenarios"][scenario]
            if "error" in entry:
                lines.append("error: %s" % entry["error"])
                lines.append("")
                continue
            lines.append("| metric | base median [min, max] | "
                         "head median [min, max] | delta |")
            lines.append("| --- | --- | --- | --- |")
            repeats = entry.get("repeats", {})
            if repeats.get("base") == 1 or repeats.get("head") == 1:
                lines.append("")
                lines.append("repeats=1: medians are single samples, no spread.")
                lines.append("")
            for key, unit in [("n_actions", ""), ("wall_s", "s"),
                              ("cpu_s", "s"), ("instructions", "")]:
                m = entry[key]
                lines.append("| %s | %s [%s, %s] | %s [%s, %s] | %s |" % (
                    key,
                    fmt(m["base"]["median"], unit), fmt(m["base"]["min"], unit),
                    fmt(m["base"]["max"], unit),
                    fmt(m["head"]["median"], unit), fmt(m["head"]["min"], unit),
                    fmt(m["head"]["max"], unit),
                    fmt_delta(m["delta_pct"])))
            lines.append("")
            replayed = entry.get("n_replayed", {})
            available = entry.get("instructions_available", {})
            if (replayed.get("base", 0) + replayed.get("head", 0) > 0
                    and not available.get("base")
                    and not available.get("head")):
                lines.append("note: no replayed action reported an "
                             "instruction counter (GitHub macOS VMs may "
                             "expose no PMU); replay CPU seconds below are "
                             "the fallback cost signal.")
                lines.append("")
            elif not (entry["instructions_complete"]["base"]
                      and entry["instructions_complete"]["head"]):
                lines.append("warning: instructions incomplete for some repeats; "
                             "totals cover only actions with a counter.")
                lines.append("")
            if entry["truncated"]["base"] or entry["truncated"]["head"]:
                lines.append("warning: replay hit its time budget on some "
                             "repeats (truncated=true in replay.json); "
                             "instruction totals are partial.")
                lines.append("")
            lines.append("Replay failures by mnemonic (median count of "
                         "non-zero exits/timeouts):")
            lines.append("")
            if entry["replay_failures"]:
                lines.append("| mnemonic | base | head |")
                lines.append("| --- | --- | --- |")
                for mnemonic in sorted(entry["replay_failures"]):
                    m = entry["replay_failures"][mnemonic]
                    lines.append("| %s | %s | %s |" % (
                        mnemonic, fmt(m["base"]["median"]),
                        fmt(m["head"]["median"])))
            else:
                lines.append("no replayed actions.")
            lines.append("")
            lines.append("Replay CPU by mnemonic (user+sys seconds from "
                         "`time -l`, median):")
            lines.append("")
            if entry.get("replay_cpu_s"):
                lines.append("| mnemonic | base | head |")
                lines.append("| --- | --- | --- |")
                for mnemonic in sorted(entry["replay_cpu_s"]):
                    m = entry["replay_cpu_s"][mnemonic]
                    lines.append("| %s | %s | %s |" % (
                        mnemonic, fmt(m["base"]["median"], "s"),
                        fmt(m["head"]["median"], "s")))
            else:
                lines.append("no replayed actions.")
            lines.append("")
            samples = entry.get("failure_samples", {})
            failing = sorted(
                m for m in samples
                if (entry["replay_failures"].get(m, {}).get("base", {})
                    .get("median") or 0) > 0
                or (entry["replay_failures"].get(m, {}).get("head", {})
                    .get("median") or 0) > 0)
            if failing:
                lines.append("Sample replay failure per mnemonic (first "
                             "failing action's target, exit and stderr tail):")
                lines.append("")
                for mnemonic in failing:
                    for ref in ["base", "head"]:
                        sample = samples[mnemonic].get(ref)
                        if sample is None:
                            continue
                        lines.append("`%s` %s: target `%s`, exit `%s`:"
                                     % (mnemonic, ref,
                                        sample.get("target", ""),
                                        sample.get("exit_code", "")))
                        lines.append("")
                        lines.append("```")
                        lines.append(sample.get("stderr_tail") or "(no stderr)")
                        lines.append("```")
                        lines.append("")
            lines.append("Executed actions by mnemonic (median count):")
            lines.append("")
            lines.append("| mnemonic | base | head | delta |")
            lines.append("| --- | --- | --- | --- |")
            for mnemonic in sorted(entry["by_mnemonic"]):
                m = entry["by_mnemonic"][mnemonic]
                lines.append("| %s | %s | %s | %s |" % (
                    mnemonic, fmt(m["base"]["median"]), fmt(m["head"]["median"]),
                    fmt_delta(m["delta_pct"])))
            lines.append("")
            lines.append("Not replayed (median count per repeat):")
            lines.append("")
            if entry.get("skipped"):
                lines.append("| reason | base | head |")
                lines.append("| --- | --- | --- |")
                for key in sorted(entry["skipped"]):
                    m = entry["skipped"][key]
                    lines.append("| %s | %s | %s |" % (
                        key, fmt(m["base"]["median"]),
                        fmt(m["head"]["median"])))
            else:
                lines.append("everything executed was replayed.")
            lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Summarize iOS bench repeats.")
    parser.add_argument("--results", required=True)
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--head-ref", required=True)
    parser.add_argument("--out-json", required=True)
    parser.add_argument("--out-md", required=True)
    parser.add_argument("--meta", default="{}",
                        help="extra JSON metadata object")
    args = parser.parse_args(argv)
    meta = json.loads(args.meta)
    meta.setdefault("generated_at",
                    datetime.datetime.now(datetime.timezone.utc).isoformat())
    summary = build_summary(args.results, args.base_ref, args.head_ref, meta)
    with open(args.out_json, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    with open(args.out_md, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render_markdown(summary))
    print("configs=%s" % sorted(summary["configs"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
