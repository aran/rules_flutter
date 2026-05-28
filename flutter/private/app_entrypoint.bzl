"""Resolves the kernel entrypoint for a Flutter app.

This module owns the entire "what does frontend_server compile as the
application root, and under what library URI" concern, including whether a
generated wrapper is needed. Callers (`flutter_compile_kernel`) ask for the
entrypoint and receive a `(file, uri, extra_srcs)` triple — they neither
know nor decide that a wrapper exists.

Hot-reload correctness depends on the running (Bazel-built) kernel keying
the app's libraries under the *same* URIs the dev tool's incremental
compiler uses. The dev tool resolves the app's main to
`package:<name>/main.dart` (via the package_config app entry that
`flutter_compile_kernel` writes). So this module ensures the user's `main`
is reached through that `package:` URI — directly when it is the
entrypoint, or via the wrapper's import when a wrapper is interposed.
"""

load("@rules_dart//dart:utils.bzl", "colocate_packages", "generate_package_config")
load("//flutter/private:plugin_registrant.bzl", "make_wrapper_main_content")

def synthesize_app_package(packages, package_name):
    """Replace transitive same-package entries with the app's synthesized package.

    A `flutter_application` / `flutter_test` / `flutter_web_application` whose
    own sources live under `lib/` is conceptually the *root* of its Dart
    package — but any `dart_library` it depends on with the same
    `package_name` exposes a `DartPackageInfo` with `lib_root=""` too, which
    would collide with the root mapping (two packages can't share a
    `rootUri`). Drop those colliding transitive entries and append one fresh
    `lib_root=""` entry for the app itself.

    Args:
      packages: List of `DartPackageInfo` (from `collect_packages`).
      package_name: The app's `package_name`. Always non-empty — every
        Flutter consumer rule declares it as a mandatory attribute.

    Returns:
      The packages list with same-`lib_root==""` entries replaced by one
      synthesized app entry. `language_version` is left blank — the app's
      language version comes from the analyzer/compiler defaults, matching
      what `flutter build` does.
    """
    return [p for p in packages if p.lib_root != ""] + [struct(
        package_name = package_name,
        lib_root = "",
        language_version = "",
    )]

def resolve_wrapper_main_import(package_name, main_path, wrapper_depth):
    """Import URI a generated wrapper should use to reach the user's `main`.

    Prefers `package:<name>/<main-rel-to-lib>` when the app is a Dart package
    and `main` sits under `lib/` — this URI flows through the assembled
    `rootUri` written into `package_config.json` by `compile_package_config`,
    so codegen siblings (`.g.dart`, `.freezed.dart`) reach the wrapper's
    consuming compile via the same co-located directory. Falls back to a
    relative file path from the wrapper otherwise.

    Args:
      package_name: The app's `package_name` (or `""`).
      main_path: Exec-root-relative path to the user's main `.dart`.
      wrapper_depth: Number of path components in the wrapper's `dirname`.

    Returns:
      A string suitable for the wrapper's `import '<value>' as entrypoint`.
    """
    return app_main_package_uri(package_name, main_path) or compute_wrapper_main_import(wrapper_depth, main_path)

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

def app_main_package_uri(package_name, main_path):
    """The `package:` URI for the app's own `main`, for hot-reload URI parity.

    `flutter_compile_kernel` registers the app as a package in the generated
    package_config with `lib_root=""` (rootUri = workspace root, packageUri
    `lib/`), so `package:<name>/X` resolves to `<workspace>/lib/X`. The dev
    tool's incremental compiler keys the entrypoint by that same
    `package:<name>/main.dart`. The running kernel must reach the user's
    main via this `package:` URI — not a relative file path — or it keys
    the library `file://` and `reloadSources` can't match it.

    Args:
        package_name: The app's Dart package name (`ctx.attr.package_name`).
        main_path: The app main's path (`ctx.file.main.path`).

    Returns:
        `package:<package_name>/<main relative to its `lib/`>`, or None when
        there is no package mapping to express (no package_name, or main not
        under a `lib/` directory).
    """
    if not package_name:
        return None
    if main_path.startswith("lib/"):
        rel = main_path[len("lib/"):]
    elif "/lib/" in main_path:
        rel = main_path.rsplit("/lib/", 1)[1]
    else:
        return None
    if not rel:
        return None
    return "package:%s/%s" % (package_name, rel)

def resolve_kernel_entrypoint(ctx, package_name, registrant, staged_agent):
    """Resolve the application kernel entrypoint.

    Decides on its own whether a wrapper is required (it is, exactly when a
    plugin `registrant` and/or a `staged_agent` must run before user
    `main()`), generates it if so, and reports the entrypoint as a
    `(file, uri, extra_srcs)` struct. The caller compiles `file`, tells
    frontend_server to use `uri` as the compilation root, and adds
    `extra_srcs` to the source set — without any wrapper knowledge.

    Args:
        ctx: The rule context (for `actions.declare_file`/`write`,
            `file.main`, `label`).
        package_name: The app's Dart package name, or "" when the app is not
            registered as a package (no `package:` URI is possible then).
        registrant: The generated plugin-registrant File, or None.
        staged_agent: The staged agent-extensions File, or None.

    Returns:
        struct(
            file: File — the entrypoint compiled into the kernel,
            uri: str — what frontend_server uses as the compilation root
                (a `package:` URI keeps the root library URI stable across
                sandboxes; a wrapper's exec-path is used for the wrapper
                itself, whose own URI is irrelevant since it is never
                hot-reloaded and imports the user's main via `package:`),
            extra_srcs: list[File] — files to add to the compile's srcs.
        )
    """
    app_pkg_uri = app_main_package_uri(package_name, ctx.file.main.path)

    if registrant or staged_agent:
        wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
        wrapper_depth = len(wrapper.dirname.split("/"))

        # The wrapper imports the user's main via its `package:` URI so the
        # running kernel keys that library identically to the dev tool's
        # incremental dill. Fall back to a relative import only when no
        # package mapping exists (then hot reload of main is unsupported
        # anyway — there is no portable URI to agree on).
        main_import = resolve_wrapper_main_import(package_name, ctx.file.main.path, wrapper_depth)
        ctx.actions.write(wrapper, make_wrapper_main_content(
            main_import,
            registrant_import = registrant.basename if registrant else None,
            agent_import = staged_agent.basename if staged_agent else None,
        ))

        extra_srcs = [ctx.file.main, wrapper]
        if registrant:
            extra_srcs.append(registrant)
        if staged_agent:
            extra_srcs.append(staged_agent)

        # The wrapper is a generated file in no package: frontend_server's
        # compilation root is its exec path. Its own library URI does not
        # matter — it is never edited/hot-reloaded; parity is carried by
        # the wrapper's `package:` import of the user's main, above.
        return struct(
            file = wrapper,
            uri = wrapper.path,
            extra_srcs = extra_srcs,
        )

    # No wrapper: the user's main is itself the entrypoint. Use its
    # `package:` URI (when the app is a package) so the root library URI is
    # sandbox-independent and matches the dev tool; otherwise its exec path.
    return struct(
        file = ctx.file.main,
        uri = app_pkg_uri or ctx.file.main.path,
        extra_srcs = [],
    )
