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

load("@rules_dart//dart:utils.bzl", "colocate_packages", "generate_package_config")

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

def app_main_location(package_name, lib_root, main):
    """The URI the app's `main` is compiled under, everywhere it is compiled.

    Its `package:` URI when it has one (`app_main_package_uri`), which needs
    no file-system root. Otherwise — a `main` outside the package's `lib/`, as
    `flutter run -t test_driver/app.dart` allows, or an app with no
    `package_name` — its `app_scheme_location`.

    Args:
        package_name: The app's Dart package name, or `""`.
        lib_root: The app's library root, from `derive_lib_root`.
        main: The app's `main` `File`.

    Returns:
        struct(uri, root): `root` is None for a `package:` URI.
    """
    package_uri = app_main_package_uri(package_name, lib_root, main.short_path)
    if package_uri:
        return struct(uri = package_uri, root = None)
    return app_scheme_location(main)

def package_lib_prefix(lib_root):
    """The `short_path` prefix holding a package's `package:`-reachable files.

    A Dart package rooted at `lib_root` exposes `<lib_root>/lib/x.dart` as
    `package:<name>/x.dart`; a workspace-rooted package (`lib_root == ""`)
    exposes `lib/x.dart`. Every question of the form "is this file reachable
    as `package:<self>/…`, and under what suffix" is this prefix plus a
    `startswith`, so the arithmetic is written once, here, and shared by the
    compile path, the dev-config path and the analyzer's source split.

    `lib_root` always comes from `derive_lib_root`, which speaks `short_path`
    convention (`external/X` → `../X`). Paths tested against this prefix must
    therefore be `short_path`s too — an exec path carries a `bazel-out/…`
    prefix for a generated `main` and would not match.

    Args:
      lib_root: The package's library root, from `derive_lib_root`.

    Returns:
      The prefix, always ending in `/`.
    """
    return (lib_root + "/lib/") if lib_root else "lib/"

def check_foreign_root_package(label, packages, package_name, lib_root):
    """Checks that no dependency claims a *differently named* package at `lib_root`.

    `synthesize_app_package` drops every transitive record rooted where the app
    is, because two Dart packages cannot share a root: the same `lib/x.dart`
    would be reachable as `package:a/x.dart` and `package:b/x.dart`, which the
    frontend treats as two libraries of one file.

    Dropping a record that carries the app's *own* name is the ordinary case and
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
      package_name: The app's own `package_name`.
      lib_root: The app's library root, from `derive_lib_root`.

    Returns:
      An error message naming every foreign package at the app's root, or
      `None` when there is none.
    """
    foreign = [
        p.package_name
        for p in packages
        if p.lib_root == lib_root and p.package_name != package_name
    ]
    if not foreign:
        return None

    return (
        ("%s: a dependency declares Dart package `%s` rooted at `%s`, which is " +
         "this target's own package root — it declares `package_name = \"%s\"`. " +
         "Two Dart packages cannot share a root, so only one of them can be " +
         "expressed, and `package:%s/…` imports would fail at the frontend as " +
         "an unresolved URI.\n\n" +
         "Either give that library a Bazel package of its own (its own " +
         "directory with its own `lib/`), or let this target *be* that " +
         "package: set `package_name = \"%s\"`, list the library's sources in " +
         "`srcs` (typically `glob([\"lib/**/*.dart\"])`), and drop the " +
         "dependency on it.") %
        (label, ", ".join(foreign), lib_root if lib_root else "the workspace root", package_name, foreign[0], foreign[0])
    )

def synthesize_app_package(label, packages, package_name, lib_root, language_version):
    """Replace colliding transitive entries with the app's own package.

    A `flutter_application` / `flutter_test` / `flutter_web_application` whose
    own sources live under `lib/` is conceptually the root of its Dart
    package — but any `dart_library` it depends on rooted at the same
    directory exposes a `DartPackageInfo` with that same `lib_root`, which
    would collide with the app's mapping (two packages can't share a
    `rootUri`). Drop those colliding transitive entries and append one fresh
    entry for the app itself.

    `lib_root` is the app's own, from `derive_lib_root`, not a bare `""`. They
    agree for a workspace-rooted app and differ for one in a nested Bazel
    package, where `""` claims the workspace root and makes
    `package:<self>/main.dart` resolve to a *different app's* `lib/main.dart`.
    See `package_lib_prefix`.

    The filter is on `lib_root`, not on `package_name`: every record at the
    app's root is dropped, including one whose name differs from the app's.
    Two packages rooted at the same directory cannot both be expressed in a
    `package_config.json` regardless of what they are called, so there is no
    shape here where keeping the foreign one would be right. A differently
    named record is not a silent drop, though — `check_foreign_root_package`
    fails the build and says what to do about it, because nothing downstream
    can still explain the disappearance.

    Args:
      label: The app/test rule's label, for the foreign-package message.
      packages: List of `DartPackageInfo` (from `collect_packages`).
      package_name: The app's `package_name`. Always non-empty — every
        Flutter consumer rule declares it as a mandatory attribute.
      lib_root: The app's library root, from `derive_lib_root`.
      language_version: The app's `language_version` attr, or `""` when it
        states none. Required rather than defaulted: a caller that forgot to
        forward it and an app that genuinely declares none would otherwise be
        the same call, which is how `flutter_test` and `flutter_web_bundle`
        came to accept the attribute and silently drop it.

    Returns:
      The packages list with every entry at `lib_root` replaced by one
      synthesized app entry, carrying `language_version`.

    Pub writes the root package's `languageVersion` from its own
    `environment.sdk` lower bound. An absent key is not "the default":
    `package_config.json` reads it as the current SDK's, so an app without one
    is compiled under newer semantics than its pubspec declares. The value
    arrives as an attribute because it lives in `pubspec.yaml`, which the
    analysis phase cannot read — the same reason `package_name` is explicit.
    """
    err = check_foreign_root_package(label, packages, package_name, lib_root)
    if err != None:
        fail(err)

    return [p for p in packages if p.lib_root != lib_root] + [struct(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
    )]

def resolve_wrapper_main_import(package_name, lib_root, main_short_path, main_path, wrapper_depth):
    """Import URI a generated wrapper should use to reach the user's `main`.

    Used by the web bootstrap wrapper (`make_web_wrapper_main_content`).
    Prefers `package:<name>/<main-rel-to-lib>` when the app is a Dart package
    and `main` sits under its `lib/` — this URI flows through the assembled
    `rootUri` written into `package_config.json` by `compile_package_config`,
    so codegen siblings (`.g.dart`, `.freezed.dart`) reach the wrapper's
    consuming compile via the same co-located directory. Falls back to a
    relative file path from the wrapper otherwise.

    Takes both of `main`'s paths because the two branches need different ones:
    the `package:` mapping is decided in `short_path` space (what `lib_root`
    speaks), while the relative fallback is walked from the wrapper's own
    location in the exec root.

    Args:
      package_name: The app's `package_name` (or `""`).
      lib_root: The app's library root, from `derive_lib_root`.
      main_short_path: `main.short_path`, tested against the package prefix.
      main_path: Exec-root-relative path to the user's main `.dart`.
      wrapper_depth: Number of path components in the wrapper's `dirname`.

    Returns:
      A string suitable for the wrapper's `import '<value>' as entrypoint`.
    """
    return app_main_package_uri(package_name, lib_root, main_short_path) or compute_wrapper_main_import(wrapper_depth, main_path)

def compile_package_config(ctx, packages, all_srcs):
    """Co-locate packages and write the matching `package_config.json`.

    The co-location step assembles any package whose hand-written + generated
    sources straddle the source tree and `bazel-out` (e.g. a `dart_codegen`
    `part`) into one real directory, then rewrites that package's `lib_root`
    to the assembled directory's `short_path`. The package_config is written
    using the exec-root-relative generator so an assembled package's
    `rootUri` resolves to its bazel-out tree artifact. The two steps are
    locked together — writing the config with the prefix-based generator
    against a colocated `lib_root` would yield the wrong `rootUri`.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of `DartPackageInfo` (already synthesized via
        `synthesize_app_package` when applicable).
      all_srcs: Flat list of transitive source Files; should include the
        app's own `main` if the consumer wants `main` co-located with its
        package siblings.

    Returns:
      `struct(config_file, srcs, packages)` — `srcs` and `packages` are
      the post-colocation values to feed the compile action.
    """
    packages2, srcs2 = colocate_packages(ctx, packages, all_srcs)
    config_file = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(config_file, generate_package_config(packages2, srcs2, config_file))
    return struct(config_file = config_file, srcs = srcs2, packages = packages2)

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

def app_main_package_uri(package_name, lib_root, main_short_path):
    """The `package:` URI for the app's own `main`, for hot-reload URI parity.

    `synthesize_app_package` registers the app as a package rooted at
    `lib_root`, so `package:<name>/X` resolves to `<lib_root>/lib/X`. The dev
    tool's incremental compiler keys the entrypoint by that same
    `package:<name>/main.dart`. The running kernel must reach the user's main
    via this `package:` URI — not a relative file path — or it keys the
    library `file://` and `reloadSources` can't match it.

    The mapping is decided by stripping `package_lib_prefix(lib_root)`, the
    one place that arithmetic lives, so the URI this returns is backed by the
    record synthesis writes rather than derived independently of it. The
    previous `rsplit("/lib/")` was such an independent derivation: it named
    `package:<name>/main.dart` for a nested app's `<pkg>/lib/main.dart` while
    the record said `lib_root=""`, so the URI resolved to the *workspace
    root's* `lib/main.dart`.

    Args:
        package_name: The app's Dart package name (`ctx.attr.package_name`).
        lib_root: The app's library root, from `derive_lib_root`.
        main_short_path: The app main's `short_path`. Not its exec path — see
            `package_lib_prefix` for why the two are not interchangeable.

    Returns:
        `package:<package_name>/<main relative to its `lib/`>`, or None when
        there is no package mapping to express (no package_name, or main not
        under the package's own `lib/`).
    """
    if not package_name:
        return None
    prefix = package_lib_prefix(lib_root)
    if not main_short_path.startswith(prefix):
        return None
    rel = main_short_path[len(prefix):]
    if not rel:
        return None
    return "package:%s/%s" % (package_name, rel)

def app_scheme_sources(package_name, lib_root, main, srcs):
    """The files the dev loop reloads under `APP_SCHEME`, by workspace path.

    Empty for a `main` with a `package:` URI. Otherwise the `main` and every
    first-party source in `srcs` outside the package's `lib/` — the only files
    outside a package the app can read, since the build's compile sees nothing
    it does not declare. The dev loop keys an edit to one of them by this URI;
    without the list, an edit to a file outside every `lib/` maps to nothing
    and a reload drops it.

    Only source files in this repository: a generated file is rewritten by a
    build, not edited, and a file in another repository is not in the
    workspace the dev loop watches.

    Args:
        package_name: The app's Dart package name, or `""`.
        lib_root: The app's library root, from `derive_lib_root`.
        main: The app's `main` `File`.
        srcs: The app's own `srcs` `File`s.

    Returns:
        A list of `{"path": <workspace-relative path>, "uri": <APP_SCHEME URI>}`.
    """
    if app_main_package_uri(package_name, lib_root, main.short_path):
        return []
    prefix = package_lib_prefix(lib_root)
    out = []
    for f in [main] + [s for s in srcs if s != main]:
        if not f.is_source or f.short_path.startswith("../"):
            continue
        if package_name and f.short_path.startswith(prefix):
            continue
        out.append({"path": f.short_path, "uri": app_scheme_location(f).uri})
    return out

def resolve_kernel_entrypoint(ctx, package_name, lib_root):
    """Resolve the application kernel entrypoint: the user's own `main`.

    Args:
        ctx: The rule context (for `file.main`).
        package_name: The app's Dart package name, or "" when the app is not
            registered as a package (no `package:` URI is possible then).
        lib_root: The app's library root, from `derive_lib_root`.

    Returns:
        struct(
            file: File — the entrypoint compiled into the kernel,
            uri: str — what frontend_server uses as the compilation root, from
                `app_main_location`: identical to the dev tool's incremental
                compile root (hot-reload URI parity) wherever `main` sits,
            root: str or None — the exec-root-relative directory `uri` needs
                mounted under `APP_SCHEME`, or None for a `package:` URI.
        )
    """
    location = app_main_location(package_name, lib_root, ctx.file.main)
    return struct(
        file = ctx.file.main,
        uri = location.uri,
        root = location.root,
    )
