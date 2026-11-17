"""Adapters that hand a Flutter checkout and its engine out dirs to rules_flutter.

The engine is built outside Bazel (`et`, or `tools/gn` and ninja, in the
developer's checkout), and these repository rules point at it, like a precompiled
`protoc`: `flutter_local_engine` is an engine source (the contract of
`@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source
directory, and `flutter_local_framework` is a framework source over a checkout's
packages.

They are the halves, for an SDK that pairs a checkout's framework or engine
with another's. A checkout's own framework and engine, the pairing
`flutter run --local-engine` makes, are one declaration instead, which cannot
pair them with anything else: `flutter.checkout(name = "local")` in
`@rules_flutter//flutter:extensions.bzl`.

The paths are machine-local, so they never appear in MODULE.bazel. The
committed MODULE.bazel declares the SDK without a path; the paths and the choice
to use the SDK live in the untracked `.bazelrc.user`. `FLUTTER_CHECKOUT` is the
flutter/flutter checkout, and `FLUTTER_ENGINE` is the engine's source directory,
as flutter_tools reads it (the default of `--local-engine-src-path`), usually
`<checkout>/engine/src`:

```
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --repo_env=FLUTTER_ENGINE=/Users/me/src/flutter/engine/src
common --@rules_flutter//flutter:sdk=local
```

MODULE.bazel:

```starlark
local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_engine")
local_framework(name = "flutter_local_framework")
local_engine(name = "flutter_local_engine")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.custom_sdk(name = "local", framework = "@flutter_local_framework", engine = "@flutter_local_engine")
```

Nothing is read until a build selects the SDK. Where a variable is not set the
repositories still load, with targets that fail when something uses them, so
`bazel query` works on a machine without a checkout.

When the out dirs of a slot are ambiguous (both `host_debug_arm64` and
`host_debug_unopt_arm64`), pin one with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64`.
A pin chooses only for the slots it fits.
"""

load("//flutter/private:framework_source.bzl", "FRAMEWORK_JSON")
load("//flutter/private:local_engine.bzl", "read_engine_out_dirs", "unset_message")

def _source_path(repository_ctx, env, label):
    """A directory's path: the directory of the file `label` names, or the environment variable's value."""
    if label:
        return str(repository_ctx.path(label).dirname)
    return repository_ctx.getenv(env)

def _local_framework_impl(repository_ctx):
    env = repository_ctx.attr.path_env
    repository_ctx.file("BUILD.bazel", 'exports_files(["%s"], visibility = ["//visibility:public"])\n' % FRAMEWORK_JSON)
    checkout = _source_path(repository_ctx, env, repository_ctx.attr.checkout)
    if not checkout:
        unset = unset_message(env, "a flutter/flutter checkout", "/path/to/flutter")
        repository_ctx.file(FRAMEWORK_JSON, json.encode({"unset": unset}) + "\n")
        return
    root = repository_ctx.path(checkout)
    if not root.get_child("packages").get_child("flutter").get_child("pubspec.yaml").exists:
        fail("{}={} is not a flutter/flutter checkout: it has no packages/flutter/pubspec.yaml.".format(env, checkout))

    # The packages and the files the framework expects of its tree, linked so
    # that an edit to the checkout is seen. The `sky_engine` package is the
    # engine's.
    repository_ctx.symlink(root.get_child("packages"), "packages")
    repository_ctx.watch_tree(root.get_child("packages"))
    internal = root.get_child("bin").get_child("internal")
    if not internal.exists:
        fail("{}={} has no bin/internal.".format(env, checkout))
    repository_ctx.symlink(internal, "bin/internal")
    repository_ctx.watch_tree(internal)

    # Which commit it is, and whether it is clean: the host's git, since only
    # git can say what a developer's own checkout is.
    commit = ""
    dirty = False
    head = repository_ctx.execute(["git", "-C", checkout, "rev-parse", "HEAD"])
    if head.return_code == 0:
        commit = head.stdout.strip()
        status = repository_ctx.execute(["git", "-C", checkout, "status", "--porcelain"])
        dirty = status.return_code == 0 and bool(status.stdout.strip())
        git_dir = root.get_child(".git")
        if git_dir.is_dir:
            repository_ctx.watch(git_dir.get_child("HEAD"))
            ref = repository_ctx.read(git_dir.get_child("HEAD")).strip()
            if ref.startswith("ref: "):
                repository_ctx.watch(git_dir.get_child(ref[len("ref: "):]))
            repository_ctx.watch(git_dir.get_child("packed-refs"))

    version_file = root.get_child("bin").get_child("cache").get_child("flutter.version.json")
    if version_file.exists:
        repository_ctx.watch(version_file)
        version = json.decode(repository_ctx.read(version_file))["flutterVersion"]
    else:
        describe = repository_ctx.execute(["git", "-C", checkout, "describe", "--tags"])
        if describe.return_code != 0:
            fail("Cannot tell which Flutter version {} is: it has no bin/cache/flutter.version.json and `git describe --tags` fails.".format(checkout))
        version = describe.stdout.strip()

    repository_ctx.file(FRAMEWORK_JSON, json.encode_indent({
        "version": version,
        "commit": commit,
        "dirty": dirty,
        "origin": "local",
        "path": checkout,
    }) + "\n")

flutter_local_framework = repository_rule(
    _local_framework_impl,
    doc = "A framework source (`flutter_framework.json`, `packages/`, ...) over a flutter/flutter checkout whose path an environment variable gives.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "checkout": attr.label(
            doc = "A file at the root of a checkout that another repository lays out, in place of the " +
                  "environment variable: for a checkout that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)

def _local_engine_impl(repository_ctx):
    path_env = repository_ctx.attr.path_env
    engine_src = _source_path(repository_ctx, path_env, repository_ctx.attr.src)
    read_engine_out_dirs(
        repository_ctx,
        engine_src = engine_src,
        named = "{}={}".format(path_env, engine_src),
        unset = unset_message(path_env, "the engine's source directory, `engine/src` of a flutter/flutter checkout, in which the engine is built in `out`", "/path/to/flutter/engine/src"),
        engines_env = repository_ctx.attr.engines_env,
    )

flutter_local_engine = repository_rule(
    _local_engine_impl,
    doc = "An engine source (the contract of `@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source directory (`engine/src`, as flutter_tools reads `FLUTTER_ENGINE`) whose path an environment variable gives: the host tools, the platform kernels, the engines of macOS, iOS, Android, Linux and Windows, their gen_snapshots, and the web SDK. A slice no out dir provides is a missing slice that says why.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the engine source directory's path. Set it with `--repo_env`.",
            default = "FLUTTER_ENGINE",
        ),
        "engines_env": attr.string(
            doc = "The environment variable naming the out dirs to use, when a slot has more than one candidate.",
            default = "FLUTTER_LOCAL_ENGINES",
        ),
        "src": attr.label(
            doc = "A file at the root of an engine source directory that another repository lays out, in place of the " +
                  "environment variable: for an engine that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)
