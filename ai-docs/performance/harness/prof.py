"""Per-mnemonic action count and CPU totals from a Bazel --profile trace.

Usage: prof.py <trace.json.gz> [--all] [--cats]
Adapted from rules_dart's harness prof.py. Use --noslim_profile when recording
the trace, or short actions are merged away. `summarize()` is what suite.py calls.
"""
import collections, gzip, json, sys

# Mnemonics suite.py keeps, besides every one starting with Flutter or Dart.
KEEP = {"FlutterKernelCompile", "FlutterShaderCompile", "FlutterAssetBundle", "TestRunner",
        "DartAnalyze", "DartFormat", "DartCompile", "CopyToDirectory", "SymlinkTree",
        "DartGenKernelNativeAssets", "DartKernel", "DartKernelOutline", "DartKernelLink",
        "DartJitSnapshot"}


def events(path):
    d = json.load(gzip.open(path))
    return d["traceEvents"] if isinstance(d, dict) else d


def action_durations(path):
    by = collections.defaultdict(list)
    for e in events(path):
        if e.get("ph") == "X" and e.get("cat") == "action processing":
            mn = e.get("args", {}).get("mnemonic") or e["name"].split(" ")[0]
            by[mn].append(e["dur"] / 1e6)
    return by


def summarize(path, keep_all=False):
    """{mnemonic: {"n": actions, "cpu_s": summed seconds}} for the kept mnemonics."""
    out = {}
    for mn, ds in action_durations(path).items():
        if keep_all or mn in KEEP or mn.startswith(("Flutter", "Dart")):
            out[mn] = {"n": len(ds), "cpu_s": round(sum(ds), 2)}
    return out


def main():
    path = sys.argv[1]
    by = action_durations(path)
    print("%-28s %5s %9s %8s %8s" % ("mnemonic", "n", "total_s", "mean_s", "max_s"))
    for mn, ds in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        print("%-28s %5d %9.2f %8.2f %8.2f" % (mn, len(ds), sum(ds), sum(ds) / len(ds), max(ds)))
    if "--cats" in sys.argv:
        cats = collections.Counter()
        for e in events(path):
            if e.get("ph") == "X":
                cats[e.get("cat", "")] += e.get("dur", 0) / 1e6
        print("\ncategories (summed durations):")
        for c, t in cats.most_common(25):
            print("  %-40s %9.2f" % (c, t))


if __name__ == "__main__":
    main()
