"""Hermetic Apple framework import and application bundle rules for the `xtool` backend.

Provides:
  - `flutter_darwin_xcframework_import`: Host-agnostic `.xcframework` /
    `.framework` import rule returning `DefaultInfo`, `CcInfo`, and
    `FlutterDarwinFrameworkInfo` without depending on `@rules_apple`.
  - `flutter_xtool_ios_bundle`: Assembles an unsigned `.ipa`
    (`Payload/<App>.app`) using `//flutter/private/tools:xtool_pack` without
    Xcode, or signs it when `zsign` is provided.
  - `flutter_xtool_macos_bundle`: Assembles an unsigned `.app.zip`
    (`<App>.app/Contents/...`) using `//flutter/private/tools:xtool_pack`
    without Xcode, or signs it when `zsign` is provided.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterDarwinFrameworkInfo")
load(":constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load(":xtool_darwin_sdk_repo.bzl", "FlutterXtoolSdkInfo", "UNCONFIGURED_SDK_ERROR")

FlutterXtoolVersionInfo = provider(
    doc = "Carries host-agnostic bundle version metadata for the xtool backend.",
    fields = {
        "build_version": "Resolved or pattern string for CFBundleVersion.",
        "short_version_string": "Resolved or pattern string for CFBundleShortVersionString.",
        "version_file": "JSON File containing `build_version` and `short_version_string`.",
    },
)

def _collect_version_group_names(s):
    names = []
    length = len(s)
    end_index = 0
    for i in range(length):
        if i < end_index:
            continue
        if s[i] == "{":
            end_index = s.find("}", i + 1)
            if end_index != -1:
                names.append(s[i + 1:end_index])
    return names

def _flutter_xtool_bundle_version_impl(ctx):
    build_label_pattern = ctx.attr.build_label_pattern
    capture_groups = ctx.attr.capture_groups
    fallback_build_label = ctx.attr.fallback_build_label

    if (build_label_pattern and not capture_groups) or (not build_label_pattern and capture_groups):
        fail(
            "%s: in 'version' target, if either build_label_pattern or capture_groups is provided, then both must be provided." % ctx.label,
        )
    if fallback_build_label and not build_label_pattern:
        fail(
            "%s: in 'version' target, if fallback_build_label is provided, then build_label_pattern and capture_groups must be provided." % ctx.label,
        )

    short_version_string = ctx.attr.short_version_string or ctx.attr.build_version
    patterns = {
        "build_version": ctx.attr.build_version,
        "short_version_string": short_version_string,
    }
    if build_label_pattern:
        patterns["build_label_pattern"] = build_label_pattern

    group_keys = (capture_groups or {}).keys()
    for attr_name, pattern in patterns.items():
        missing = [g for g in _collect_version_group_names(pattern) if g not in group_keys]
        if missing:
            fail(
                "%s: in 'version' target attribute %r, placeholder group(s) [%s] were not defined in capture_groups." % (
                    ctx.label,
                    attr_name,
                    ", ".join(sorted(missing)),
                ),
            )

    bundle_version_file = ctx.actions.declare_file(ctx.label.name + ".bundle_version")
    if build_label_pattern:
        control_file = ctx.actions.declare_file(ctx.label.name + ".versiontool-control")
        control = {
            "build_info_path": ctx.info_file.path,
            "build_label_pattern": build_label_pattern,
            "build_version_pattern": ctx.attr.build_version,
            "capture_groups": capture_groups,
            "short_version_string_pattern": short_version_string,
        }
        if fallback_build_label:
            control["fallback_build_label"] = fallback_build_label
        ctx.actions.write(
            output = control_file,
            content = json.encode(control),
        )
        ctx.actions.run(
            executable = ctx.executable._xtool_pack,
            arguments = [
                "resolve-version",
                "--control",
                control_file.path,
                "--output",
                bundle_version_file.path,
            ],
            env = {"TMPDIR": "/tmp"},
            use_default_shell_env = False,
            inputs = [control_file, ctx.info_file],
            outputs = [bundle_version_file],
            mnemonic = "FlutterXtoolBundleVersion",
        )
    else:
        ctx.actions.write(
            output = bundle_version_file,
            content = json.encode({
                "build_version": ctx.attr.build_version,
                "short_version_string": short_version_string,
            }) + "\n",
        )

    return [
        FlutterXtoolVersionInfo(
            version_file = bundle_version_file,
            build_version = ctx.attr.build_version if not build_label_pattern else "",
            short_version_string = short_version_string if not build_label_pattern else "",
        ),
        DefaultInfo(files = depset([bundle_version_file])),
    ]

flutter_xtool_bundle_version = rule(
    implementation = _flutter_xtool_bundle_version_impl,
    attrs = {
        "build_label_pattern": attr.string(default = ""),
        "build_version": attr.string(mandatory = True),
        "capture_groups": attr.string_dict(default = {}),
        "fallback_build_label": attr.string(default = ""),
        "short_version_string": attr.string(default = ""),
        "_xtool_pack": attr.label(
            default = Label("//flutter/private/tools:xtool_pack"),
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [FlutterXtoolVersionInfo, DefaultInfo],
    doc = "Host-agnostic replacement for `apple_bundle_version` on the `xtool` backend.",
)

def _xtool_version_name(version, pkg):
    """The same-package target name behind a `version` label, or None when cross-package."""
    ver_name = None
    if version.startswith(":"):
        ver_name = version[1:]
    elif "/" not in version and ":" not in version:
        ver_name = version
    elif version.startswith("//" + pkg + ":"):
        ver_name = version.split(":", 1)[1]
    return ver_name

def _mirror_xtool_bundle_version(name, existing, internal_tags):
    """Mirror an `apple_bundle_version` rule's attributes into a host-agnostic helper target.

    Returns the `(version_label, build_version, short_version)` triple.
    """
    bv = existing.get("build_version") or ""
    sv = existing.get("short_version_string") or ""
    blp = existing.get("build_label_pattern") or ""
    cg = existing.get("capture_groups") or {}
    fbl = existing.get("fallback_build_label") or ""
    helper_name = "__%s_xtool_version" % name
    flutter_xtool_bundle_version(
        name = helper_name,
        build_version = bv,
        short_version_string = sv,
        build_label_pattern = blp,
        capture_groups = cg,
        fallback_build_label = fbl,
        tags = internal_tags,
        visibility = ["//visibility:private"],
    )
    return ":" + helper_name, (bv if not blp else ""), ((sv or bv) if not blp else "")

def _resolve_xtool_same_package(name, macro_name, ver_name, version, pkg, internal_tags):
    """Resolve a same-package `version` label without triggering Apple toolchains."""
    existing = native.existing_rule(ver_name)
    if existing != None:
        kind = existing.get("kind", "")
        if kind == "apple_bundle_version" or "build_version" in existing or "short_version_string" in existing:
            label, bv, sv = _mirror_xtool_bundle_version(name, existing, internal_tags)
            return label, bv, sv, ""
        if kind in ("flutter_xtool_bundle_version", "write_file", "_write_file", "genrule", "filegroup"):
            return version, "", "", ""
        return None, "", "", "%s(name = %r): 'version' target %r (rule kind %r) is not supported on the xtool backend; pass an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON version file." % (
            macro_name,
            name,
            version,
            kind,
        )

    if native.glob([ver_name], allow_empty = True):
        return version, "", "", ""
    return None, "", "", "%s(name = %r): 'version' target %r does not exist in package '//%s'; pass an 'apple_bundle_version' target or a JSON version file." % (
        macro_name,
        name,
        version,
        pkg,
    )

def resolve_xtool_version(name, macro_name, version, internal_tags):
    """Resolves a `version` attribute for `backend = 'xtool'` without triggering Apple toolchains.

    Inspects same-package `apple_bundle_version` targets via `native.existing_rule`
    and mirrors their attributes into a host-agnostic `flutter_xtool_bundle_version`
    target so Bazel never resolves `@rules_apple` macOS toolchains on Linux.

    Args:
        name: Application target name.
        macro_name: Calling macro name (`"flutter_ios_app"` or `"flutter_macos_app"`).
        version: The `version` argument passed to the macro.
        internal_tags: Tags to apply to any synthesized helper target.

    Returns:
        A 4-tuple `(version_label, build_version, short_version, invalid_version_error)`.
    """
    if version == None:
        return None, "", "", ""
    if type(version) != "string":
        return None, "", "", "%s(name = %r): 'version' (%r) is not supported on the xtool backend; expected an 'apple_bundle_version' target or JSON version file label." % (
            macro_name,
            name,
            version,
        )

    pkg = native.package_name()
    ver_name = _xtool_version_name(version, pkg)

    if ver_name != None:
        return _resolve_xtool_same_package(name, macro_name, ver_name, version, pkg, internal_tags)

    return None, "", "", "%s(name = %r): cross-package 'version' target %r is not supported on the xtool backend because 'apple_bundle_version' requires a macOS toolchain unless declared in the same package; declare 'apple_bundle_version' in '//%s' or pass `build_version` / `short_version`." % (
        macro_name,
        name,
        version,
        pkg,
    )

# -- Transitions & Architecture Helpers ----------------------------------------

def _xtool_ios_transition_impl(settings, _attr):
    comp_mode = settings["//command_line_option:compilation_mode"]
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:ios_arm64"))
    if comp_mode == "dbg":
        target_platform = str(Label("//flutter/platforms:ios_x64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":ios_arm64") or p_str.endswith(":ios_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

_xtool_ios_transition = transition(
    implementation = _xtool_ios_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _xtool_macos_transition_impl(settings, _attr):
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:macos_arm64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":macos_arm64") or p_str.endswith(":macos_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

_xtool_macos_transition = transition(
    implementation = _xtool_macos_transition_impl,
    inputs = [
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _target_arch(ctx):
    if ctx.target_platform_has_constraint(
        ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo],
    ):
        return "x86_64"
    cpu = ctx.var.get("TARGET_CPU", "")
    if "x86_64" in cpu or "k8" in cpu:
        return "x86_64"
    return "arm64"

# -- flutter_darwin_xcframework_import -----------------------------------------

def _infer_framework_name(files, explicit_name, fallback_name):
    if explicit_name:
        return explicit_name
    for f in files:
        for segment in f.path.split("/"):
            if segment.endswith(".framework"):
                return segment[:-len(".framework")]
            if segment.endswith(".xcframework"):
                return segment[:-len(".xcframework")]
    return fallback_name

def _scan_path_segments(parts, framework_dirs, framework_search_dirs, include_dirs):
    """Index the `.framework` / `Headers` segments of one split file path."""
    for idx, part in enumerate(parts):
        if part.endswith(".framework"):
            fw_dir = "/".join(parts[:idx + 1])
            parent_dir = "/".join(parts[:idx])
            if fw_dir not in framework_dirs:
                framework_dirs.append(fw_dir)
            if parent_dir:
                framework_search_dirs[parent_dir] = True
        if part == "Headers" and idx > 0 and (
            parts[idx - 1].endswith(".framework") or
            (idx >= 3 and parts[idx - 2] == "Versions")
        ):
            include_dirs["/".join(parts[:idx + 1])] = True

def _scan_framework_search_paths(files):
    """Index framework dirs, headers and include dirs across every file path."""
    framework_dirs = []
    headers = []
    include_dirs = {}
    framework_search_dirs = {}

    for f in files:
        path = f.path
        if f.is_directory and (path.endswith(".framework") or path.endswith(".xcframework")):
            if path not in framework_dirs:
                framework_dirs.append(path)

        parts = path.split("/")
        _scan_path_segments(parts, framework_dirs, framework_search_dirs, include_dirs)

        if path.endswith(".h"):
            headers.append(f)
    return framework_dirs, headers, include_dirs, framework_search_dirs

def _choose_framework_slice(framework_dirs, target_arch, is_simulator, files):
    """Prefer a slice matching simulator vs device when several exist in an xcframework."""
    chosen_dir = ""
    if framework_dirs:
        chosen_dir = framework_dirs[0]
        for candidate in framework_dirs:
            lower = candidate.lower()
            if is_simulator and "simulator" in lower:
                chosen_dir = candidate
                break
            if not is_simulator and "ios-" in lower and "simulator" not in lower:
                chosen_dir = candidate
                break
            if "macos-" in lower:
                chosen_dir = candidate
                break
            if target_arch and target_arch in lower and "simulator" not in lower:
                chosen_dir = candidate

    if not chosen_dir and files:
        chosen_dir = files[0].dirname
    return chosen_dir

def _select_framework_dir_and_headers(files, target_arch, is_simulator):
    framework_dirs, headers, include_dirs, framework_search_dirs = _scan_framework_search_paths(files)
    chosen_dir = _choose_framework_slice(framework_dirs, target_arch, is_simulator, files)
    return chosen_dir, headers, include_dirs.keys(), framework_search_dirs.keys()

def _flutter_darwin_xcframework_import_impl(ctx):
    all_files = ctx.files.xcframework_imports
    target_arch = _target_arch(ctx)
    is_simulator = (target_arch == "x86_64") and ("ios" in ctx.bin_dir.path)

    framework_name = _infer_framework_name(
        all_files,
        ctx.attr.framework_name,
        ctx.label.name,
    )
    framework_dir, headers, include_dirs, fw_search_dirs = _select_framework_dir_and_headers(
        all_files,
        target_arch,
        is_simulator,
    )

    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(headers),
            includes = depset(include_dirs),
            framework_includes = depset(fw_search_dirs),
        ),
    )

    return [
        DefaultInfo(files = depset(all_files)),
        cc_info,
        FlutterDarwinFrameworkInfo(
            framework_name = framework_name,
            framework_files = depset(all_files),
            framework_dir = framework_dir,
            headers = depset(headers),
            is_dynamic = ctx.attr.is_dynamic,
        ),
    ]

flutter_darwin_xcframework_import = rule(
    implementation = _flutter_darwin_xcframework_import_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "xcframework_imports": attr.label_list(
                allow_files = True,
                mandatory = True,
                doc = "Files comprising the .xcframework or .framework bundle.",
            ),
            "framework_name": attr.string(
                default = "",
                doc = "Explicit framework name (e.g. 'Flutter' or 'FlutterMacOS'). Inferred when omitted.",
            ),
            "is_dynamic": attr.bool(
                default = True,
                doc = "Whether the imported framework is a dynamic framework.",
            ),
        },
    ),
    provides = [
        DefaultInfo,
        CcInfo,
        FlutterDarwinFrameworkInfo,
    ],
    doc = "Host-agnostic Darwin .xcframework / .framework import rule for the xtool backend.",
)

# -- Shared bundle helpers -----------------------------------------------------

def _extract_framework_dirs_from_files(files, seen_dirs, framework_dirs):
    for f in files:
        if f.is_directory:
            if f.path not in seen_dirs:
                seen_dirs[f.path] = True
                framework_dirs.append(f.path)
        else:
            parts = f.path.split("/")
            for idx, part in enumerate(parts):
                if part.endswith(".xcframework") or part.endswith(".framework"):
                    candidate = "/".join(parts[:idx + 1])
                    if candidate not in seen_dirs:
                        seen_dirs[candidate] = True
                        framework_dirs.append(candidate)
                    break

def _record_framework_info(fw_info, seen_dirs, framework_dirs, transitive_inputs):
    """Fold one `FlutterDarwinFrameworkInfo` into the shared accumulators."""
    transitive_inputs.append(fw_info.framework_files)
    if fw_info.framework_dir:
        if fw_info.framework_dir not in seen_dirs:
            seen_dirs[fw_info.framework_dir] = True
            framework_dirs.append(fw_info.framework_dir)
    else:
        _extract_framework_dirs_from_files(
            fw_info.framework_files.to_list(),
            seen_dirs,
            framework_dirs,
        )

def _framework_files_in(files):
    """The subset of `files` that belongs to a `.framework` / `.xcframework`."""
    return [
        f
        for f in files
        if f.is_directory or ".framework/" in f.path or ".xcframework/" in f.path or f.path.endswith(".framework") or f.path.endswith(".xcframework")
    ]

def _collect_framework_args_and_inputs(framework_targets, plugin_and_dep_targets = []):
    framework_dirs = []
    seen_dirs = {}
    direct_inputs = []
    transitive_inputs = []

    for target in framework_targets:
        if FlutterDarwinFrameworkInfo in target:
            _record_framework_info(
                target[FlutterDarwinFrameworkInfo],
                seen_dirs,
                framework_dirs,
                transitive_inputs,
            )
        else:
            files = target[DefaultInfo].files.to_list()
            direct_inputs.extend(files)
            _extract_framework_dirs_from_files(files, seen_dirs, framework_dirs)

    for target in plugin_and_dep_targets:
        if FlutterDarwinFrameworkInfo in target:
            _record_framework_info(
                target[FlutterDarwinFrameworkInfo],
                seen_dirs,
                framework_dirs,
                transitive_inputs,
            )
        else:
            fw_files = _framework_files_in(target[DefaultInfo].files.to_list())
            if fw_files:
                direct_inputs.extend(fw_files)
                _extract_framework_dirs_from_files(fw_files, seen_dirs, framework_dirs)

    return framework_dirs, direct_inputs, transitive_inputs

def _classify_runner_file(seen, buckets, f):
    """Sort one file into the runner's source/header/modulemap buckets, deduplicated by path."""
    if f.path in seen:
        return
    seen[f.path] = True
    if f.path.endswith(".swift") or f.path.endswith(".m") or f.path.endswith(".mm") or f.path.endswith(".c") or f.path.endswith(".cc") or f.path.endswith(".cpp"):
        buckets["sources"].append(f)
    elif f.path.endswith(".h"):
        buckets["headers"].append(f)
    elif f.path.endswith(".modulemap"):
        buckets["modulemaps"].append(f)

def _add_sdk_name(seen_names, ordered, value):
    """Append an SDK framework/dylib name once, preserving first-seen order."""
    if value and value not in seen_names:
        seen_names[value] = True
        ordered.append(value)

def _collect_runner_own_files(ctx, seen, buckets):
    """Classify the runner's own `srcs` and `registrant` files."""
    for f in ctx.files.srcs:
        _classify_runner_file(seen, buckets, f)
    for f in ctx.files.registrant:
        _classify_runner_file(seen, buckets, f)

def _collect_runner_linker_sdk_names(target, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib):
    """Record the SDK frameworks/dylibs named by a dep's linker flags."""
    for li in target[CcInfo].linking_context.linker_inputs.to_list():
        flags = li.user_link_flags
        for idx in range(len(flags)):
            if flags[idx] == "-framework" and idx + 1 < len(flags):
                _add_sdk_name(seen_sdk_fw, sdk_frameworks, flags[idx + 1])
            elif flags[idx].startswith("-l") and len(flags[idx]) > 2:
                _add_sdk_name(seen_sdk_dylib, sdk_dylibs, flags[idx][2:])

def _collect_runner_dep_files(ctx, seen, buckets, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib, transitive_sets):
    """Classify plugin/dep files and record their SDK frameworks, dylibs and header sets."""
    for target in ctx.attr.plugins + ctx.attr.deps:
        for f in target[DefaultInfo].files.to_list():
            _classify_runner_file(seen, buckets, f)
        if FlutterApplePluginInfo in target:
            for fw in target[FlutterApplePluginInfo].sdk_frameworks:
                _add_sdk_name(seen_sdk_fw, sdk_frameworks, fw)
            for dylib in target[FlutterApplePluginInfo].sdk_dylibs:
                _add_sdk_name(seen_sdk_dylib, sdk_dylibs, dylib)
        if CcInfo in target:
            cc_hdrs = target[CcInfo].compilation_context.headers
            transitive_sets.append(cc_hdrs)
            for f in cc_hdrs.to_list():
                _classify_runner_file(seen, buckets, f)
            _collect_runner_linker_sdk_names(target, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib)

def _collect_runner_compile_inputs(ctx):
    sources = []
    headers = []
    modulemaps = []
    sdk_frameworks = []
    sdk_dylibs = []
    seen = {}
    seen_sdk_fw = {}
    seen_sdk_dylib = {}
    transitive_sets = []
    buckets = {"sources": sources, "headers": headers, "modulemaps": modulemaps}

    _collect_runner_own_files(ctx, seen, buckets)
    _collect_runner_dep_files(ctx, seen, buckets, sdk_frameworks, seen_sdk_fw, sdk_dylibs, seen_sdk_dylib, transitive_sets)

    return sources, headers, modulemaps, sdk_frameworks, sdk_dylibs, transitive_sets

def _check_resource_file_for_xtool(ctx, file_obj, attr_name):
    lower = file_obj.short_path.lower()
    segments = lower.split("/")
    for seg in segments:
        if seg.endswith(".storyboard") or seg.endswith(".xib"):
            return "%s: '%s' contains Interface Builder source %r which requires Xcode 'ibtool' to compile into a runtime .storyboardc/.nib bundle, and has no hermetic implementation on the xtool backend." % (
                ctx.label,
                attr_name,
                file_obj.short_path,
            )
        if seg.endswith(".xcassets") or seg.endswith(".appiconset") or seg.endswith(".icon"):
            return "%s: '%s' contains uncompiled asset catalog %r which requires Xcode 'actool' to compile into Assets.car/.icns, and has no hermetic implementation on the xtool backend." % (
                ctx.label,
                attr_name,
                file_obj.short_path,
            )
    return None

def _fail_on_xtool_unsupported_attrs(ctx):
    """Fail on xtool-backend attribute combinations that have no hermetic implementation."""
    if ctx.attr.unsupported_kwargs:
        fail(
            "%s (backend = 'xtool'): unsupported attribute(s) %s are not supported on the xtool backend." % (
                ctx.label,
                ", ".join(["'%s'" % k for k in sorted(ctx.attr.unsupported_kwargs)]),
            ),
        )

    if ctx.attr.invalid_version_error:
        fail(ctx.attr.invalid_version_error)

    if ctx.attr.certificate_password:
        fail(
            "%s: plain-text 'certificate_password' is not supported because signing secrets must never appear on action command lines. Use 'certificate_password_file' (a File label) or 'certificate_password_env' (an environment variable name) instead." % ctx.label,
        )

def _collect_xtool_ib_errors(ctx):
    """The Interface Builder / asset catalog errors for resources needing Xcode tools."""
    ib_errors = []
    if hasattr(ctx.file, "launch_storyboard") and ctx.file.launch_storyboard:
        ib_errors.append(
            "%s: 'launch_storyboard' (%s) is not supported on the xtool backend because compiling .storyboard files requires Xcode 'ibtool', which has no hermetic cross-platform implementation." % (
                ctx.label,
                ctx.file.launch_storyboard.short_path,
            ),
        )

    if hasattr(ctx.file, "menu_xib") and ctx.file.menu_xib:
        ib_errors.append(
            "%s: 'menu_xib' (%s) is not supported on the xtool backend because compiling .xib files requires Xcode 'ibtool', which has no hermetic cross-platform implementation. Remove %s (and omit 'menu_xib') to use the default programmatic menu, or use backend = \"rules_apple\"." % (
                ctx.label,
                ctx.file.menu_xib.short_path,
                ctx.file.menu_xib.short_path,
            ),
        )

    if ctx.files.app_icons:
        fail(
            "%s: 'app_icons' (%s) is not supported on the xtool backend because compiling asset catalogs (.xcassets / .appiconset / .icon) requires Xcode 'actool', which has no hermetic cross-platform implementation." % (
                ctx.label,
                ctx.files.app_icons[0].short_path,
            ),
        )

    for res_file in ctx.files.resources:
        err = _check_resource_file_for_xtool(ctx, res_file, "resources")
        if err:
            ib_errors.append(err)
    return ib_errors

def _collect_xtool_additional_contents(ctx, ib_errors):
    """Validate `additional_contents` and return its `(subdir=file)` pairs and files."""
    additional_content_pairs = []
    additional_content_files = []
    for target, subdir in ctx.attr.additional_contents.items():
        if not subdir or subdir.startswith("/") or ".." in subdir.split("/"):
            fail(
                "%s: invalid 'additional_contents' subdirectory %r for %s; must be a relative bundle subdirectory without '..'." % (
                    ctx.label,
                    subdir,
                    target.label,
                ),
            )
        for f in target[DefaultInfo].files.to_list():
            err = _check_resource_file_for_xtool(ctx, f, "additional_contents")
            if err:
                ib_errors.append(err)
            additional_content_pairs.append("%s=%s" % (subdir, f.path))
            additional_content_files.append(f)
    return additional_content_pairs, additional_content_files

def _xtool_sdk_availability(ctx):
    """Whether the xtool SDK repo resolved, plus its files for action inputs."""
    sdk_available = False
    sdk_transitive = []
    if ctx.attr._xtool_sdk_status and FlutterXtoolSdkInfo in ctx.attr._xtool_sdk_status:
        sdk_info = ctx.attr._xtool_sdk_status[FlutterXtoolSdkInfo]
        sdk_available = sdk_info.sdk_available
        sdk_transitive.append(sdk_info.sdk_files)
    return sdk_available, sdk_transitive

def _compile_xtool_runner(ctx, platform, app_name, arch, sdk_available, fw_dirs, fw_direct_inputs, fw_transitive_inputs, sdk_transitive):
    """Compile the runner executable via `xtool_pack compile-runner`; returns its File."""
    executable_file = ctx.actions.declare_file("%s_runner_bin" % ctx.label.name)
    sources, headers, modulemaps, sdk_frameworks, sdk_dylibs, plugin_transitive_sets = _collect_runner_compile_inputs(ctx)

    runner_args = ctx.actions.args()
    runner_args.add("compile-runner")
    runner_args.add("--platform", platform)
    runner_args.add("--arch", arch)
    runner_args.add("--app-name", app_name)
    runner_args.add("--minimum-os-version", ctx.attr.minimum_os_version)
    runner_args.add("--sdk-available", "true" if sdk_available else "false")
    runner_args.add("--output", executable_file.path)

    for src in sources:
        runner_args.add("--source", src.path)
    for hdr in headers:
        runner_args.add("--header", hdr.path)
    for mm in modulemaps:
        runner_args.add("--modulemap", mm.path)
    for fw_dir in fw_dirs:
        runner_args.add("--framework", fw_dir)
    for sdk_fw in sdk_frameworks:
        runner_args.add("--sdk-framework", sdk_fw)
    for sdk_dylib in sdk_dylibs:
        runner_args.add("--sdk-dylib", sdk_dylib)

    ctx.actions.run(
        executable = ctx.executable._xtool_pack,
        arguments = [runner_args],
        env = {"TMPDIR": "/tmp"},
        use_default_shell_env = False,
        inputs = depset(
            direct = sources + headers + modulemaps + fw_direct_inputs,
            transitive = fw_transitive_inputs + plugin_transitive_sets + sdk_transitive,
        ),
        outputs = [executable_file],
        mnemonic = "FlutterXtoolRunner",
        progress_message = "Compiling runner executable for %s (%s) via xtool_pack" % (ctx.label, platform),
    )
    return executable_file

def _add_xtool_bundle_content_args(ctx, args, families, fw_dirs, native_libs, resources, additional_content_pairs, infoplists):
    """Append the bundle payload flags (families, defines, plists, frameworks, libs, resources)."""
    for fam in families:
        args.add("--family", fam)
    if ctx.attr.build_version:
        args.add("--define", "FLUTTER_BUILD_NUMBER=%s" % ctx.attr.build_version)
    if ctx.attr.short_version:
        args.add("--define", "FLUTTER_BUILD_NAME=%s" % ctx.attr.short_version)
    for k, v in ctx.attr.defines.items():
        args.add("--define", "%s=%s" % (k, v))

    for plist in infoplists:
        args.add("--info-plist", plist.path)

    for fw_dir in fw_dirs:
        args.add("--framework", fw_dir)

    for dylib in native_libs:
        args.add("--native-lib", dylib.path)

    for res in resources:
        args.add("--resource", res.path)

    for pair in additional_content_pairs:
        args.add("--additional-content", pair)

def _add_xtool_version_args(ctx, args, direct_inputs):
    """Append the `--version-file` flag and register the version file as an input."""
    version_files = ctx.files.version
    if not version_files:
        fail(
            "%s: 'version' target %s did not produce a version file; expected an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON file with 'build_version' and 'short_version_string'." % (
                ctx.label,
                ctx.attr.version.label,
            ),
        )
    vf = version_files[0]
    if FlutterXtoolVersionInfo not in ctx.attr.version and not (vf.basename.endswith(".json") or vf.basename.endswith(".bundle_version")):
        fail(
            "%s: 'version' target %s (%s) is not supported on the xtool backend; expected an 'apple_bundle_version' target, 'flutter_xtool_bundle_version', or a JSON file with 'build_version' and 'short_version_string'." % (
                ctx.label,
                ctx.attr.version.label,
                vf.short_path,
            ),
        )
    args.add("--version-file", vf.path)
    direct_inputs.append(vf)

def _add_xtool_signing_args(ctx, args, direct_inputs):
    """Append the signing flags, registering each referenced file as an input."""
    if ctx.file.provisioning_profile:
        args.add("--provisioning-profile", ctx.file.provisioning_profile.path)
        direct_inputs.append(ctx.file.provisioning_profile)

    if ctx.file.entitlements:
        args.add("--entitlements", ctx.file.entitlements.path)
        direct_inputs.append(ctx.file.entitlements)

    if ctx.executable.zsign:
        args.add("--zsign", ctx.executable.zsign.path)
        direct_inputs.append(ctx.executable.zsign)

    if ctx.file.certificate:
        args.add("--certificate", ctx.file.certificate.path)
        direct_inputs.append(ctx.file.certificate)

    if ctx.file.certificate_password_file:
        args.add("--certificate-password-file", ctx.file.certificate_password_file.path)
        direct_inputs.append(ctx.file.certificate_password_file)

def _xtool_bundle_action_env(ctx):
    """The hermetic environment for the `xtool_pack bundle` action."""
    action_env = dict(ctx.attr.env)
    if ctx.attr.certificate_password_env:
        if ctx.attr.certificate_password_env not in action_env:
            action_env[ctx.attr.certificate_password_env] = ""
    if not action_env.get("TMPDIR"):
        action_env["TMPDIR"] = "/tmp"
    return action_env

def _xtool_bundle_base_args(ctx, platform, app_name, executable_file, archive_file, app_dir):
    """The leading `xtool_pack bundle` flags identifying the app and its outputs."""
    args = ctx.actions.args()
    args.add("bundle")
    args.add("--platform", platform)
    args.add("--app-name", app_name)
    args.add("--bundle-id", ctx.attr.bundle_id)
    args.add("--executable", executable_file.path)
    args.add("--minimum-os-version", ctx.attr.minimum_os_version)
    args.add("--temp-dir", archive_file.path + ".tmp")
    args.add("--output-archive", archive_file.path)
    args.add("--output-app-dir", app_dir.path)
    return args

def _run_xtool_pack_bundle(
        ctx,
        *,
        platform,
        archive_ext,
        mnemonic,
        families = [],
        native_libs = []):
    _fail_on_xtool_unsupported_attrs(ctx)
    ib_errors = _collect_xtool_ib_errors(ctx)
    additional_content_pairs, additional_content_files = _collect_xtool_additional_contents(ctx, ib_errors)

    if ib_errors:
        fail("\n".join(ib_errors))

    sdk_available, sdk_transitive = _xtool_sdk_availability(ctx)

    if ctx.attr.require_sdk and not sdk_available:
        fail(UNCONFIGURED_SDK_ERROR)

    app_name = ctx.attr.app_name if ctx.attr.app_name else ctx.label.name
    archive_file = ctx.actions.declare_file("%s%s" % (ctx.label.name, archive_ext))
    app_dir = ctx.actions.declare_directory("%s_bundle/%s.app" % (ctx.label.name, app_name))

    infoplists = ctx.files.infoplists
    resources = ctx.files.resources

    fw_dirs, fw_direct_inputs, fw_transitive_inputs = _collect_framework_args_and_inputs(
        ctx.attr.frameworks,
        ctx.attr.plugins + ctx.attr.deps,
    )

    arch = _target_arch(ctx)

    executable_file = ctx.file.executable
    if not executable_file:
        executable_file = _compile_xtool_runner(ctx, platform, app_name, arch, sdk_available, fw_dirs, fw_direct_inputs, fw_transitive_inputs, sdk_transitive)

    args = _xtool_bundle_base_args(ctx, platform, app_name, executable_file, archive_file, app_dir)

    direct_inputs = (
        [executable_file] +
        infoplists +
        resources +
        native_libs +
        additional_content_files +
        fw_direct_inputs
    )

    if ctx.attr.version:
        _add_xtool_version_args(ctx, args, direct_inputs)

    _add_xtool_bundle_content_args(ctx, args, families, fw_dirs, native_libs, resources, additional_content_pairs, infoplists)

    _add_xtool_signing_args(ctx, args, direct_inputs)

    action_env = _xtool_bundle_action_env(ctx)
    args.add("--isolated-env")
    for env_key in sorted(ctx.attr.env.keys()):
        if env_key != "TMPDIR" and env_key != "TEST_TMPDIR":
            args.add("--declared-env", env_key)
    if ctx.attr.certificate_password_env:
        args.add("--certificate-password-env", ctx.attr.certificate_password_env)
        if ctx.attr.certificate_password_env not in action_env:
            action_env[ctx.attr.certificate_password_env] = ""
    if not action_env.get("TMPDIR"):
        action_env["TMPDIR"] = "/tmp"

    ctx.actions.run(
        executable = ctx.executable._xtool_pack,
        arguments = [args],
        env = action_env,
        use_default_shell_env = False,
        inputs = depset(
            direct = direct_inputs,
            transitive = fw_transitive_inputs,
        ),
        outputs = [archive_file, app_dir],
        mnemonic = mnemonic,
        progress_message = "Packaging %s (%s) via xtool_pack" % (ctx.label, platform),
    )

    return [
        DefaultInfo(
            files = depset([archive_file]),
            runfiles = ctx.runfiles(files = [archive_file]),
        ),
        OutputGroupInfo(
            archive = depset([archive_file]),
            app_dir = depset([app_dir]),
            runner_binary = depset([executable_file]),
        ),
    ]

# -- flutter_xtool_ios_bundle --------------------------------------------------

def _flutter_xtool_ios_bundle_impl(ctx):
    if not ctx.attr.families:
        fail(
            "%s: 'families' must not be empty; expected one or more of 'iphone', 'ipad'." % ctx.label,
        )
    for fam in ctx.attr.families:
        if fam not in ("iphone", "ipad"):
            fail(
                "%s: invalid device family %r in 'families'; expected 'iphone' or 'ipad'." % (
                    ctx.label,
                    fam,
                ),
            )

    target_arch = _target_arch(ctx)
    is_sim = (target_arch == "x86_64") or (ctx.var.get("COMPILATION_MODE", "") == "dbg")
    platform = "ios_sim" if is_sim else "ios"
    return _run_xtool_pack_bundle(
        ctx,
        platform = platform,
        archive_ext = ".ipa",
        mnemonic = "FlutterXtoolIosBundle",
        families = ctx.attr.families,
    )

_COMMON_BUNDLE_ATTRS = {
    "app_name": attr.string(
        default = "",
        doc = "Application bundle name (`<app_name>.app`). Defaults to the target name.",
    ),
    "bundle_id": attr.string(
        mandatory = True,
        doc = "Bundle identifier (e.g. `com.example.app`).",
    ),
    "version": attr.label(
        allow_files = True,
        doc = "Optional version target (such as `apple_bundle_version`, `flutter_xtool_bundle_version`, or a JSON file with `build_version` and `short_version_string`).",
    ),
    "invalid_version_error": attr.string(
        default = "",
        doc = "Internal validation error message when `version` references an unsupported target.",
    ),
    "build_version": attr.string(
        default = "",
        doc = "Optional explicit `CFBundleVersion` (`FLUTTER_BUILD_NUMBER`) override.",
    ),
    "short_version": attr.string(
        default = "",
        doc = "Optional explicit `CFBundleShortVersionString` (`FLUTTER_BUILD_NAME`) override.",
    ),
    "defines": attr.string_dict(
        default = {},
        doc = "Optional variable substitutions (`KEY: VALUE`) applied when merging `Info.plist` files.",
    ),
    "env": attr.string_dict(
        default = {},
        doc = "Optional explicit environment variables set on the `xtool_pack` bundle action.",
    ),
    "infoplists": attr.label_list(
        allow_files = [".plist"],
        default = [],
        doc = "List of `Info.plist` files to merge and variable-substitute into the bundle.",
    ),
    "executable": attr.label(
        allow_single_file = True,
        doc = "Optional pre-compiled Mach-O main executable binary. When omitted, `FlutterXtoolRunner` compiles/synthesizes the runner from `srcs`, `registrant`, `plugins`, and `deps`.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Runner Swift/ObjC source files compiled by `FlutterXtoolRunner` when `executable` is omitted.",
    ),
    "registrant": attr.label(
        allow_files = True,
        doc = "GeneratedPluginRegistrant target compiled into the runner.",
    ),
    "plugins": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Apple plugin aggregator or plugin library targets linked into the runner.",
    ),
    "deps": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional runner library targets.",
    ),
    "require_sdk": attr.bool(
        default = False,
        doc = "When True, fails at analysis with a named error if `@flutter_xtool_darwin_sdk` is not configured.",
    ),
    "_xtool_sdk_status": attr.label(
        default = Label("@flutter_xtool_darwin_sdk//:sdk_status"),
    ),
    "frameworks": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Framework targets (`FlutterDarwinFrameworkInfo` or `.framework`/`.xcframework` files) to embed in `Frameworks/`.",
    ),
    "resources": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional pre-compiled resource files or directories to copy into the bundle (`ibtool`/`actool` sources like `.storyboard`, `.xib`, and `.xcassets` are rejected at analysis).",
    ),
    "additional_contents": attr.label_keyed_string_dict(
        allow_files = True,
        default = {},
        doc = "Mapping of file/directory targets to relative bundle subdirectories (e.g. `{\":helper\": \"PlugIns\"}`).",
    ),
    "app_icons": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Asset catalog icon files. Rejected at analysis on the `xtool` backend because `actool` is not hermetically available.",
    ),
    "provisioning_profile": attr.label(
        allow_single_file = True,
        doc = "Optional `.mobileprovision` file to embed as `embedded.mobileprovision`.",
    ),
    "entitlements": attr.label(
        allow_single_file = [".plist", ".entitlements"],
        doc = "Optional entitlements plist passed to `zsign` when signing.",
    ),
    "zsign": attr.label(
        executable = True,
        cfg = "exec",
        doc = "Optional `zsign` executable for cryptographic code signing.",
    ),
    "certificate": attr.label(
        allow_single_file = True,
        doc = "Optional signing certificate (`.p12` or `.pem`) for `zsign`.",
    ),
    "certificate_password_file": attr.label(
        allow_single_file = True,
        doc = "Optional file containing the password for `certificate`. Read at execution time by `xtool_pack` so the secret never appears on action command lines.",
    ),
    "certificate_password_env": attr.string(
        default = "",
        doc = "Optional environment variable name holding the password for `certificate`, read at execution time from the action's declared `env` by `xtool_pack`.",
    ),
    "certificate_password": attr.string(
        default = "",
        doc = "Deprecated/rejected plain-text password attribute. Setting this fails at analysis to prevent leaking secrets on command lines; use `certificate_password_file` or `certificate_password_env`.",
    ),
    "unsupported_kwargs": attr.string_list(
        default = [],
        doc = "Internal list of unsupported attribute names forwarded from macros so they fail at analysis with a named error.",
    ),
    "_xtool_pack": attr.label(
        default = Label("//flutter/private/tools:xtool_pack"),
        executable = True,
        cfg = "exec",
    ),
    "_allowlist_function_transition": attr.label(
        default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
    ),
}

flutter_xtool_ios_bundle = rule(
    implementation = _flutter_xtool_ios_bundle_impl,
    cfg = _xtool_ios_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = IOS_MINIMUM_OS_VERSION,
                doc = "Minimum iOS deployment target version.",
            ),
            "families": attr.string_list(
                default = ["iphone", "ipad"],
                doc = "Supported iOS device families (`'iphone'`, `'ipad'`). Populates `UIDeviceFamily` in `Info.plist`.",
            ),
            "launch_storyboard": attr.label(
                allow_single_file = True,
                doc = "Launch storyboard file. Rejected at analysis on the `xtool` backend because `ibtool` is not hermetically available.",
            ),
        },
    ),
    doc = "Packages an iOS application into an unsigned `.ipa` (`Payload/<App>.app`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)

# -- flutter_xtool_macos_bundle ------------------------------------------------

def _flutter_xtool_macos_bundle_impl(ctx):
    return _run_xtool_pack_bundle(
        ctx,
        platform = "macos",
        archive_ext = ".app.zip",
        mnemonic = "FlutterXtoolMacosBundle",
        native_libs = ctx.files.native_libs,
    )

flutter_xtool_macos_bundle = rule(
    implementation = _flutter_xtool_macos_bundle_impl,
    cfg = _xtool_macos_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = MACOS_MINIMUM_OS_VERSION,
                doc = "Minimum macOS deployment target version.",
            ),
            "native_libs": attr.label_list(
                allow_files = True,
                default = [],
                doc = "Optional staged native dynamic libraries (`flutter_macos_native_libs`) embedded under `Contents/Frameworks/`.",
            ),
            "menu_xib": attr.label(
                allow_single_file = True,
                doc = "Main menu `.xib` file. Rejected at analysis on the `xtool` backend because `ibtool` is not hermetically available.",
            ),
        },
    ),
    doc = "Packages a macOS application into an unsigned `.app.zip` (`<App>.app/Contents/...`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)
