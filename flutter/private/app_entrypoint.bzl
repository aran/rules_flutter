"""Resolves the kernel entrypoint for a Flutter app.

This module owns the "what does frontend_server compile as the application
root, and under what library URI" concern.

Hot-reload correctness depends on the running (Bazel-built) kernel keying
the app's libraries under the *same* URIs the dev tool's incremental
compiler uses. A `main` under its package's `lib/` is compiled as its
`package:` URI (via the package_config app entry that
`flutter_compile_kernel` writes); one outside it — `flutter run -t` allows
any — as `org-dartlang-app:///<workspace path>`, with the same file-system
root mounted on both sides (`app_main_location`). Pre-main setup (plugin
registrant, agent extensions) is NOT interposed here — it lives in the
generated registrant library the engine invokes before `main()` on every
root-isolate launch (see plugin_registrant.bzl), which is what keeps it
alive across hot restart.
"""

load("@rules_dart//dart:utils.bzl", "colocate_packages", "generate_package_config", "merged_package_record", "package_lib_prefix")

visibility("//flutter/...")

# The file-system scheme a file with no `package:` URI is compiled under — a
# `main` outside its package's `lib/`, and the generated plugin registrant. One
# name for the build's kernel compile and the dev loop's compiler alike, which
# is what lets the running kernel and a hot reload agree on a library's URI.
# rules_dart's dev package config mounts a source-assembled package under the
# same scheme, and a frontend_server mounts one scheme at a time, so there is no
# second name to choose.
APP_SCHEME = "org-dartlang-app"

def app_scheme_location(file):
    """Where `file` sits under `APP_SCHEME`, and the root it sits under.

    rules_dart's `generate_dev_package_config` convention: the path is the
    file's workspace-relative one (a file in another repository sits under
    `external/<repo>/`), and the root is the exec root for a source file or its
    output directory for a generated one. Both halves mean the same thing in the
    build's sandbox and in the dev loop, which is the point — a source file's
    exec path is a sandbox path, and naming a library by it gives the dev loop a
    URI it can never compile again.

    Args:
        file: A `File`.

    Returns:
        struct(uri, root): `org-dartlang-app:///<path>`, and the
        exec-root-relative directory to mount for it (`""` for the exec root).
    """
    rel = file.short_path
    if rel.startswith("../"):
        rel = "external/" + rel[len("../"):]
    if not file.path.endswith(rel):
        fail("%s: cannot place %s under a file-system root: its path does not end in %s" % (file.owner, file.path, rel))
    root = file.path[:len(file.path) - len(rel)].rstrip("/")
    return struct(uri = "%s:///%s" % (APP_SCHEME, rel), root = root)

def with_root(roots, root):
    """`roots` with `root` appended unless it is None or already there.

    Args:
        roots: Exec-root-relative directories (`""` for the exec root).
        root: One more, or None.

    Returns:
        A new list.
    """
    if root == None or root in roots:
        return list(roots)
    return list(roots) + [root]

def app_main_location(package_name, package_root, main):
    """The URI the app's `main` is compiled under, everywhere it is compiled.

    Its `package:` URI when it has one (`app_main_package_uri`), which needs
    no file-system root. Otherwise — a `main` outside the package's `lib/`, as
    `flutter run -t test_driver/app.dart` allows, or an app with no
    `package_name` — its `app_scheme_location`.

    Args:
        package_name: The app's Dart package name, or `""`.
        package_root: The app's package root, its declaration's directory.
        main: The app's `main` `File`.

    Returns:
        struct(uri, root): `root` is None for a `package:` URI.
    """
    package_uri = app_main_package_uri(package_name, package_root, main.short_path)
    if package_uri:
        return struct(uri = package_uri, root = None)
    return app_scheme_location(main)

def check_foreign_root_package(label, packages, package_name, package_root):
    """Checks that no dependency claims a *differently named* package at `package_root`.

    `synthesize_app_package` replaces every record rooted where the app is
    with the app's own, because two Dart packages cannot share a root: the
    same `lib/x.dart` would be reachable as `package:a/x.dart` and
    `package:b/x.dart`, which the frontend treats as two libraries of one file.

    Replacing a record that carries the app's *own* name is the ordinary case and
    stays silent — a `flutter_library` and the `flutter_test` beside it naming
    the same package are two Bazel targets contributing to one Dart package, and
    the synthesized record is what they collapse into.

    A record with a *different* name has to stop the build. No other record can
    supply that name, so every `package:<it>/…` import fails at the frontend as
    an unresolved URI — a message naming the import and not the target whose
    presence caused it. The frontend cannot be taught to explain it, because by
    then the record no longer exists.

    Args:
      label: The app/test rule's label, for the message.
      packages: List of `DartPackageInfo` (from `collect_packages`).
      package_name: The app's own package name.
      package_root: The app's package root.

    Returns:
      An error message naming every foreign package at the app's root, or
      `None` when there is none.
    """
    foreign = [
        p.package_name
        for p in packages
        if p.package_root == package_root and p.package_name != package_name
    ]
    if not foreign:
        return None

    return (
        ("%s: a dependency declares Dart package `%s` rooted at `%s`, which is " +
         "this target's own package root — its `package` is package `%s`. " +
         "Two Dart packages cannot share a root, so only one of them can be " +
         "expressed, and `package:%s/…` imports would fail at the frontend as " +
         "an unresolved URI.\n\n" +
         "Either give that library a Bazel package of its own (its own " +
         "directory with its own `lib/`), or let this target *be* that " +
         "package: name that library's `dart_package_metadata` (package " +
         "`%s`) in `package`, and depend on the library or list its sources " +
         "in `srcs`.") %
        (label, ", ".join(foreign), package_root if package_root else "the workspace root", package_name, foreign[0], foreign[0])
    )

def synthesize_app_package(label, packages, package_name, package_root, metadata):
    """Replace the records at the app's root with the app's own package.

    A `flutter_application` / `flutter_test` / `flutter_web_application` whose
    own sources live under `lib/` is the root of its Dart package, and any
    `flutter_library` or `dart_library` it depends on rooted at the same
    directory is that same package. One directory is one entry in a
    `package_config.json`, so their records give way to one record for the
    app: the app's merged with theirs by rules_dart's `merged_package_record`.
    Every one of them names the package's one `dart_package_metadata`, the
    app's included, so they state the same facts; one naming another, or
    none, fails the build naming both.

    `package_root` is the app's own, its declaration's directory, not a bare
    `""`. They agree for a workspace-rooted app and differ for one in a nested
    Bazel package, where `""` claims the workspace root and makes
    `package:<self>/main.dart` resolve to a *different app's* `lib/main.dart`.
    See `package_lib_prefix`.

    The selection is by `package_root`, not by `package_name`. Two packages
    rooted at the same directory cannot both be expressed in a
    `package_config.json` whatever they are called, so a differently named
    record there cannot be kept, and it cannot be dropped silently either:
    `check_foreign_root_package` fails the build and says what to do about
    it, because nothing downstream can still explain the disappearance.

    Args:
      label: The app/test rule's label, recorded on the app's record and
        named in errors.
      packages: List of `DartPackageInfo` (from `collect_packages`).
      package_name: The app's package name, its declaration's.
      package_root: The app's package root, its declaration's directory.
      metadata: The `DartPackageMetadataInfo` of the app's package, or None
        for a program naming none (a test compiled in a package it does not
        declare).

    Returns:
      The packages list with every entry at `package_root` replaced by the
      app's own `DartPackageInfo`, last.
    """
    err = check_foreign_root_package(label, packages, package_name, package_root)
    if err != None:
        fail(err)

    at_root = [p for p in packages if p.package_root == package_root]
    return [p for p in packages if p.package_root != package_root] + [
        merged_package_record(label, package_name, package_root, metadata, at_root),
    ]

def resolve_wrapper_main_import(package_name, package_root, main_short_path, main_path, wrapper_depth):
    """Import URI a generated wrapper should use to reach the user's `main`.

    Used by the web bootstrap wrapper (`make_web_wrapper_main_content`).
    Prefers `package:<name>/<main-rel-to-lib>` when the app is a Dart package
    and `main` sits under its `lib/` — this URI flows through the assembled
    `rootUri` written into `package_config.json` by `compile_package_config`,
    so codegen siblings (`.g.dart`, `.freezed.dart`) reach the wrapper's
    consuming compile via the same co-located directory. Falls back to a
    relative file path from the wrapper otherwise.

    Takes both of `main`'s paths because the two branches need different ones:
    the `package:` mapping is decided in `short_path` space (what `package_root`
    speaks), while the relative fallback is walked from the wrapper's own
    location in the exec root.

    Args:
      package_name: The app's `package_name` (or `""`).
      package_root: The app's package root, its declaration's directory.
      main_short_path: `main.short_path`, tested against the package prefix.
      main_path: Exec-root-relative path to the user's main `.dart`.
      wrapper_depth: Number of path components in the wrapper's `dirname`.

    Returns:
      A string suitable for the wrapper's `import '<value>' as entrypoint`.
    """
    return app_main_package_uri(package_name, package_root, main_short_path) or compute_wrapper_main_import(wrapper_depth, main_path)

def compile_package_config(ctx, packages, all_srcs):
    """Co-locate packages and write the matching `package_config.json`.

    The co-location step assembles any package whose hand-written + generated
    sources straddle the source tree and `bazel-out` (e.g. a `dart_codegen`
    `part`) into one real directory, then rewrites that package's `package_root`
    to the assembled directory's `short_path`. The package_config is written
    using the exec-root-relative generator so an assembled package's
    `rootUri` resolves to its bazel-out tree artifact. The two steps are
    locked together — writing the config with the prefix-based generator
    against a colocated `package_root` would yield the wrong `rootUri`.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of `DartPackageInfo` (already synthesized via
        `synthesize_app_package` when applicable).
      all_srcs: Flat list of transitive source Files; should include the
        app's own `main` if the consumer wants `main` co-located with its
        package siblings.

    Returns:
      `struct(config_file, srcs, packages)` — `srcs` and `packages` are the
      post-colocation values to feed the compile action. The config's package
      roots reach into `srcs`, so a consumer that reads sources through the
      config after the build declares its build outputs among `srcs`.
    """
    packages2, srcs2 = colocate_packages(ctx, packages, all_srcs)
    config_file = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(config_file, generate_package_config(packages2, srcs2, config_file))
    return struct(
        config_file = config_file,
        srcs = srcs2,
        packages = packages2,
    )

def compute_wrapper_main_import(wrapper_dir_depth, main_path):
    """Relative import path from a generated wrapper to the original main.

    Used when no `package:` mapping applies (e.g. web's
    `org-dartlang-app:` scheme, or a main outside any `lib/`). The wrapper
    sits in `bazel-out/.../bin/pkg/` while main is at its exec-root-relative
    path, so climb out of the wrapper's dir then descend into main.

    Args:
        wrapper_dir_depth: Number of path components in the wrapper's dirname.
        main_path: Exec-root-relative path to the original main file.

    Returns:
        A relative import string like "../../../../my_app/lib/main.dart".
    """
    return "../" * wrapper_dir_depth + main_path

def compute_same_root_main_import(wrapper_dir, main_path):
    """Relative import path from a generated wrapper to a `main` generated beside it.

    A `main` a rule wrote is in the same output directory as the wrapper
    (`bazel-out/<config>/bin`), so the way from one to the other does not go
    through the config segment, which a path-mapped action sees under a name of
    its own: a path written into the wrapper as `bazel-out/<config>/bin/...`
    names a directory that does not exist where the action runs. Both paths are
    relative to the output directory, which is what they have in common.

    Args:
        wrapper_dir: The wrapper's directory, relative to the output directory
            (`""` for its top).
        main_path: The main's path, relative to the output directory.

    Returns:
        A relative import string like "../../pkg/main.dart".
    """
    depth = len(wrapper_dir.split("/")) if wrapper_dir else 0
    return "../" * depth + main_path

def app_main_package_uri(package_name, package_root, main_short_path):
    """The `package:` URI for the app's own `main`, for hot-reload URI parity.

    `synthesize_app_package` registers the app as a package rooted at
    `package_root`, so `package:<name>/X` resolves to `<package_root>/lib/X`. The dev
    tool's incremental compiler keys the entrypoint by that same
    `package:<name>/main.dart`. The running kernel must reach the user's main
    via this `package:` URI — not a relative file path — or it keys the
    library `file://` and `reloadSources` can't match it.

    The mapping is decided by stripping `package_lib_prefix(package_root)`, the
    one place that arithmetic lives, so the URI this returns is backed by the
    record synthesis writes rather than derived independently of it. The
    previous `rsplit("/lib/")` was such an independent derivation: it named
    `package:<name>/main.dart` for a nested app's `<pkg>/lib/main.dart` while
    the record said `package_root=""`, so the URI resolved to the *workspace
    root's* `lib/main.dart`.

    Args:
        package_name: The app's Dart package name (its `package`'s).
        package_root: The app's package root, its declaration's directory.
        main_short_path: The app main's `short_path`. Not its exec path — see
            `package_lib_prefix` for why the two are not interchangeable.

    Returns:
        `package:<package_name>/<main relative to its `lib/`>`, or None when
        there is no package mapping to express (no package_name, or main not
        under the package's own `lib/`).
    """
    if not package_name:
        return None
    prefix = package_lib_prefix(package_root)
    if not main_short_path.startswith(prefix):
        return None
    rel = main_short_path[len(prefix):]
    if not rel:
        return None
    return "package:%s/%s" % (package_name, rel)

def app_scheme_files(package_name, package_root, main, srcs):
    """The first-party source files the app reads under `APP_SCHEME`.

    Empty for a `main` with a `package:` URI. Otherwise the `main` and every
    first-party source in `srcs` outside the package's `lib/` — the only files
    outside a package the app can read, since the build's compile sees nothing
    it does not declare.

    Only source files in this repository: a generated file is rewritten by a
    build, not edited, and a file in another repository is not in the
    workspace the dev loop watches.

    Args:
        package_name: The app's Dart package name, or `""`.
        package_root: The app's package root, its declaration's directory.
        main: The app's `main` `File`.
        srcs: The app's own `srcs` `File`s.

    Returns:
        A list of `File`s.
    """
    if app_main_package_uri(package_name, package_root, main.short_path):
        return []
    prefix = package_lib_prefix(package_root)
    out = []
    for f in [main] + [s for s in srcs if s != main]:
        if not f.is_source or f.short_path.startswith("../"):
            continue
        if package_name and f.short_path.startswith(prefix):
            continue
        out.append(f)
    return out

def app_scheme_sources(package_name, package_root, main, srcs):
    """The files the dev loop reloads under `APP_SCHEME`, by workspace path.

    The files of `app_scheme_files`, each keyed by its URI: an edit to a file
    outside every `lib/` maps to nothing in the dev loop without the list, and a
    reload drops it.

    Args:
        package_name: The app's Dart package name, or `""`.
        package_root: The app's package root, its declaration's directory.
        main: The app's `main` `File`.
        srcs: The app's own `srcs` `File`s.

    Returns:
        A list of `{"path": <workspace-relative path>, "uri": <APP_SCHEME URI>}`.
    """
    return [
        {"path": f.short_path, "uri": app_scheme_location(f).uri}
        for f in app_scheme_files(package_name, package_root, main, srcs)
    ]
