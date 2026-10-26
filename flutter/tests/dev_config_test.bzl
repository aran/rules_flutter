"""Every build output `_dev_config.json` names is one its target declares.

The dev tool reads these paths off this machine, and only a declared output is
sure to be there: a cache hit runs no action, so an output that is only some
action's input is never written. The test reads the config and the package
configs it names, and holds each output path in them to the target's
`DefaultInfo`, for a native and a web target depending on a package whose
sources are all generated.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")

_MAX_NODES = 100000

def _source_tree_impl(ctx):
    tree = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        outputs = [tree],
        command = "mkdir -p {0}/lib && echo 'const prebuilt = 1;' > {0}/lib/prebuilt.dart".format(tree.path),
    )
    return [DefaultInfo(files = depset([tree]))]

source_tree = rule(
    implementation = _source_tree_impl,
    doc = "A built directory holding a Dart package's `lib/`.",
)

def _written(env, suffix):
    """The decoded JSON of each `ctx.actions.write` whose output ends in `suffix`, by output path."""
    return {
        a.outputs.to_list()[0].path: json.decode(a.content)
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(suffix)
    }

def _strings(value):
    """Every string in a decoded JSON value."""
    found = []
    work = [value]
    for _ in range(_MAX_NODES):
        if not work:
            break
        v = work.pop()
        if type(v) == "dict":
            work.extend(v.values())
        elif type(v) == "list":
            work.extend(v)
        elif type(v) == "string":
            found.append(v)
    return found

def _normalize(path):
    parts = []
    for part in path.split("/"):
        if part == "..":
            parts.pop()
        elif part not in ("", "."):
            parts.append(part)
    return "/".join(parts)

def _declared_test_impl(ctx):
    env = analysistest.begin(ctx)
    declared = {
        f.path: True
        for f in analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    }

    configs = _written(env, "_dev_config.json")
    asserts.equals(env, 1, len(configs), "expected one _dev_config.json")
    package_configs = _written(env, "package_config.json")
    roots = []
    for config in configs.values():
        # The search roots are directories, not files the config names.
        named = {k: v for k, v in config.items() if k != "filesystemRoots"}
        for s in _strings(named):
            if not s.startswith("bazel-out/"):
                continue
            asserts.true(env, s in declared, "the dev config names %s, which the target does not declare" % s)

            # A package config names directories, and the dev tool reads the
            # files under each.
            # A scheme root resolves under each filesystem root, and the dev
            # compiler reads whichever holds the file.
            if s in package_configs:
                config_dir = s.rsplit("/", 1)[0]
                scheme_prefix = config.get("filesystemScheme", "") + ":///"
                for entry in package_configs[s]["packages"]:
                    uri = entry["rootUri"]
                    if ":" not in uri:
                        candidates = [_normalize(config_dir + "/" + uri)]
                    elif config.get("filesystemScheme") and uri.startswith(scheme_prefix):
                        rest = uri[len(scheme_prefix):]
                        candidates = [_normalize(r + "/" + rest) for r in config["filesystemRoots"]]
                    else:
                        continue
                    candidates = [c for c in candidates if c.startswith("bazel-out/")]
                    if candidates:
                        roots.append(candidates)

    asserts.true(
        env,
        [c for r in roots for c in r if c.endswith("/flutter/tests/dev_config_fixture/tree")] != [],
        "the prebuilt package must be rooted in the output tree, or this test proves nothing; got %r" % roots,
    )
    for candidates in roots:
        asserts.true(
            env,
            [
                p
                for p in declared
                for root in candidates
                if p == root or p.startswith(root + "/") or root.startswith(p + "/")
            ] != [],
            "a package config names %s, and the target declares nothing holding it or under it" % candidates,
        )
    return analysistest.end(env)

_declared_test = analysistest.make(
    _declared_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)

def dev_config_test_suite(name):
    """Fixtures and tests for what a dev config's targets declare.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_dc_native",
        package_name = "dc_fixture",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/dev_config_fixture:prebuilt"],
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_dc_web",
        package_name = "dc_fixture",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/dev_config_fixture:prebuilt"],
        tags = ["manual"],
    )
    _declared_test(name = name + "_native", target_under_test = ":_dc_native")
    _declared_test(name = name + "_web", target_under_test = ":_dc_web")
    native.test_suite(name = name, tests = [":" + name + "_native", ":" + name + "_web"])
