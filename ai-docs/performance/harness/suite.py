"""rules_flutter benchmark suite. See README.md for the scenarios and how to read them.

    suite.py <rules_flutter checkout> <label> [scenarios...]
             [--rules-dart <rules_dart checkout>] [--size small|full] [--publish]

Scenarios are groups, as in rules_dart's suite: analysis, build, test, lint.
With none given, all four run. Writes $RULES_FLUTTER_BENCH_DIR/results/<label>.json
(default ~/rules_flutter_bench) and, with --publish, also
<checkout>/ai-docs/performance/results/<label>.json.

Adapted from rules_dart's harness suite.py. Workspaces are generated fresh under
the bench root; `bazel clean` only ever runs inside those.
"""
import argparse, datetime, json, os, re, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bump as bumper  # noqa: E402
from prof import summarize  # noqa: E402

S = os.environ.get("RULES_FLUTTER_BENCH_DIR", os.path.expanduser("~/rules_flutter_bench"))

SIZES = {
    # packages, files per package, packages and files for the analysis variant
    "small": dict(pkgs=4, files=3, analysis_pkgs=10, analysis_files=3),
    "full": dict(pkgs=30, files=20, analysis_pkgs=80, analysis_files=30),
}
PUB_SPOKE = re.compile(r"__|\+deps$|\+pub$|ext_pub")
API_TEXT = "\n/// Added API.\nint addedApi0x0() => 1;\n"
LEAF = "packages/pkg0/lib/src/f0.dart"

ap = argparse.ArgumentParser()
ap.add_argument("rules")
ap.add_argument("label")
ap.add_argument("scenarios", nargs="*", choices=["analysis", "build", "test", "lint"])
ap.add_argument("--rules-dart", default=None)
ap.add_argument("--size", choices=sorted(SIZES), default="small")
ap.add_argument("--publish", action="store_true")
args = ap.parse_args()

rules = os.path.abspath(args.rules)
rules_dart = os.path.abspath(args.rules_dart) if args.rules_dart else None
label = args.label
sz = SIZES[args.size]
TEST_PKG = 5 if sz["pkgs"] > 5 else 1  # the package whose test is measured in test_runfiles
TEST_TARGET = f"//packages/pkg{TEST_PKG}:pkg{TEST_PKG}_test"
os.makedirs(f"{S}/results", exist_ok=True)
want = (lambda k: not args.scenarios or k in args.scenarios)


def sh(cmd, cwd):
    """Runs cmd, returns (wall seconds, stdout+stderr). Any non-zero exit is fatal."""
    t = time.time()
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    dt = time.time() - t
    if r.returncode != 0:
        print((r.stdout + r.stderr)[-4000:])
        raise SystemExit(f"failed ({r.returncode}): {cmd} in {cwd}")
    return dt, r.stdout + r.stderr


def sandboxed(out):
    """Sandboxed actions in Bazel's final 'INFO: N processes:' line.

    Matches any *-sandbox label: linux-sandbox, processwrapper-sandbox, darwin-sandbox.
    """
    lines = re.findall(r"INFO: \d+ processes?: ([^\n]*)", out)
    if not lines:
        return 0
    return sum(int(n) for n, _ in re.findall(r"(\d+) ([\w-]*sandbox)", lines[-1]))


def build(ws, bazel_args, name):
    p = f"{S}/results/{label}.{name}.json.gz"
    dt, out = sh(f"bazel {bazel_args} --noslim_profile --profile={p}", ws)
    return {"wall_s": round(dt, 2), "sandboxed": sandboxed(out), "actions": summarize(p)}


WS = {}  # workspace name -> path, for every workspace this run generated
OB_ROOT = os.path.join(S, "ob", label)


def ws_for(name, n, f):
    """Generates the workspace once per run, with its own output base for this label.

    The output base is emptied first, so each label starts with nothing fetched. The
    workspace is registered before generation, so the final `bazel shutdown` covers
    it even if generation fails.
    """
    if name not in WS:
        ws = f"{S}/{name}"
        ob = os.path.join(OB_ROOT, name)
        if os.path.exists(ob):
            subprocess.run(["chmod", "-R", "u+w", ob], check=True)
            shutil.rmtree(ob)
        WS[name] = ws
        res["output_base"][name] = ob
        cmd = [sys.executable, os.path.join(HERE, "gen_bench.py"), ws, str(n), str(f), rules,
               "--output-base", ob]
        if rules_dart:
            cmd += ["--rules-dart", rules_dart]
        subprocess.run(cmd, check=True)
    return WS[name]


def api_edit(ws, on):
    p = os.path.join(ws, LEAF)
    s = open(p).read()
    if on:
        assert API_TEXT not in s
        s = s + API_TEXT
    else:
        assert s.endswith(API_TEXT)
        s = s[: -len(API_TEXT)]
    open(p, "w").write(s)


def output_base(ws):
    return sh("bazel info output_base", ws)[1].strip().splitlines()[-1]


def fetch_footprint(ws):
    """Sizes of the dart and flutter repos in the output base's external/ (pub spokes excluded)."""
    ext = os.path.join(output_base(ws), "external")
    names = sorted(n for n in os.listdir(ext)
                   if re.search(r"dart|flutter", n, re.I) and not PUB_SPOKE.search(n)
                   and os.path.isdir(os.path.join(ext, n)))
    entries = []
    for n in names:
        du = sh(f"du -sm '{os.path.join(ext, n)}'", ws)[1].split()[0]
        entries.append({"name": n, "mb": int(du)})
    return {
        "entries": entries,
        "total_mb": sum(e["mb"] for e in entries),
        "rules_dart_linux_sdk_fetched": "rules_dart++dart+dart_linux-x64" in names,
    }


def expand_inputs(data, action):
    """Artifact ids of an action's inputs, from an aquery --output=jsonproto document."""
    depsets = {d["id"]: d for d in data.get("depSetOfFiles", [])}
    ids, seen, stack = set(), set(), list(action.get("inputDepSetIds", []))
    while stack:
        dsid = stack.pop()
        if dsid in seen:
            continue
        seen.add(dsid)
        d = depsets[dsid]
        ids.update(d.get("directArtifactIds", []))
        stack.extend(d.get("transitiveDepSetIds", []))
    ids.update(action.get("inputIds", []))
    return ids


def kernel_inputs(ws, target):
    q = f"mnemonic(\"FlutterKernelCompile|DartKernel\", {target})"
    r = subprocess.run(["bazel", "aquery", "--output=jsonproto", "--include_commandline=false", q],
                       cwd=ws, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"aquery failed: {r.stderr[-2000:]}")
    data = json.loads(r.stdout)
    actions = [a for a in data.get("actions", [])
               if a.get("mnemonic") in ("FlutterKernelCompile", "DartKernel")]
    if not actions:
        return {"target": target, "error": "no FlutterKernelCompile or DartKernel action"}
    frags = {f["id"]: f for f in data.get("pathFragments", [])}
    arts = {a["id"]: a for a in data.get("artifacts", [])}

    def exec_path(a):
        if a.get("execPath"):
            return a["execPath"]
        parts, fid = [], a.get("pathFragmentId")
        while fid:
            frag = frags[fid]
            parts.append(frag["label"])
            fid = frag.get("parentId")
        return "/".join(reversed(parts))

    execroot = sh("bazel info execution_root", ws)[1].strip().splitlines()[-1]
    ids = expand_inputs(data, actions[0])
    total = ext_total = count = missing = 0
    for aid in ids:
        p = os.path.join(execroot, exec_path(arts[aid]))
        if not os.path.exists(p):
            missing += 1
            continue
        if os.path.isdir(p):  # tree artifact
            for root, _, files in os.walk(p):
                for f in files:
                    sz_ = os.path.getsize(os.path.join(root, f))
                    total += sz_
                    count += 1
        else:
            sz_ = os.path.getsize(p)
            total += sz_
            count += 1
            if exec_path(arts[aid]).startswith("external/"):
                ext_total += sz_
    return {"target": target, "actions": len(actions), "inputs": count,
            "mb": round(total / 2**20, 1), "external_mb": round(ext_total / 2**20, 1),
            "missing": missing}


def runfiles(ws, pkg):
    rf = os.path.realpath(os.path.join(ws, "bazel-bin", "packages", f"pkg{pkg}",
                                       f"pkg{pkg}_test.runfiles"))
    n = int(sh(f"find -L '{rf}' -type f | wc -l", ws)[1].split()[-1])
    mb = int(sh(f"du -sLm '{rf}'", ws)[1].split()[0])
    return {"target": f"//packages/pkg{pkg}:pkg{pkg}_test", "files": n, "mb": mb}


def bazel_version():
    return sh("bazel --version", HERE)[1].strip()


def git_rev(path):
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=path,
                          capture_output=True, text=True).stdout.strip() or "unknown"


res = {
    "label": label,
    "rules_rev": git_rev(rules),
    "size": args.size,
    "packages": sz["pkgs"],
    "files_per_package": sz["files"],
    "bazel": bazel_version(),
    "jobs": int(os.environ.get("RULES_FLUTTER_BENCH_JOBS", "8")),
    "date": datetime.datetime.now().isoformat(timespec="seconds"),
    "output_base": {},
    "scenarios": {},
}
if rules_dart:
    res["rules_dart_rev"] = git_rev(rules_dart)
R = res["scenarios"]
try:

    if want("analysis"):
        ws = ws_for("bench_analysis", sz["analysis_pkgs"], sz["analysis_files"])
        sh("bazel build //... --nobuild", ws)  # warm the analysis cache
        ts = []
        for i in range(3):
            # A changed --define changes the configuration, so each run re-analyses everything.
            dt, _ = sh(f"bazel build //... --nobuild --define=bench={label}-{i}-{time.time_ns()}", ws)
            ts.append(round(dt, 2))
        R[f"reanalysis_{sz['analysis_pkgs']}pkg_s"] = round(statistics.median(ts), 2)
        R[f"reanalysis_{sz['analysis_pkgs']}pkg_runs_s"] = ts

    if want("build"):
        ws = ws_for("bench", sz["pkgs"], sz["files"])
        sh("bazel clean", ws)
        R["clean_build"] = build(ws, "build //...", "clean_build")
        R["fetch_footprint"] = fetch_footprint(ws)
        bumper.bump(os.path.join(ws, LEAF))
        R["body_edit_build"] = build(ws, "build //...", "body_edit_build")
        api_edit(ws, True)
        R["api_edit_build"] = build(ws, "build //...", "api_edit_build")
        api_edit(ws, False)
        sh("bazel build //...", ws)  # back to the body-edited state, nothing timed
        R["null_build"] = build(ws, "build //...", "null_build")
        R["null_build_s"] = R["null_build"]["wall_s"]

    if want("test"):
        ws = ws_for("bench", sz["pkgs"], sz["files"])
        sh("bazel build //...", ws)
        r = build(ws, "test //... --nocache_test_results", "test")
        tr = r["actions"].get("TestRunner", {"n": 1, "cpu_s": 0})
        r["per_test_s"] = round(tr["cpu_s"] / max(tr["n"], 1), 3)
        R["test_run"] = r
        R["test_runfiles"] = runfiles(ws, TEST_PKG)
        R["kernel_inputs"] = kernel_inputs(ws, TEST_TARGET)

    if want("lint"):
        ws = ws_for("bench", sz["pkgs"], sz["files"])
        sh("bazel clean", ws)
        R["lint_clean"] = build(ws, "build --config=lint //...", "lint_clean")
        bumper.bump(os.path.join(ws, LEAF))
        R["lint_body_edit"] = build(ws, "build --config=lint //...", "lint_body_edit")

    out = f"{S}/results/{label}.json"
    with open(out, "w") as f:
        json.dump(res, f, indent=1)
    if args.publish:
        pub_dir = os.path.join(rules, "ai-docs", "performance", "results")
        os.makedirs(pub_dir, exist_ok=True)
        with open(os.path.join(pub_dir, f"{label}.json"), "w") as f:
            json.dump(res, f, indent=1)
    print(json.dumps(res, indent=1))
finally:
    # Stop the server of every output base this run used, even after a failure.
    for ws in WS.values():
        if os.path.isdir(ws):
            subprocess.run(["bazel", "shutdown"], cwd=ws, capture_output=True)
