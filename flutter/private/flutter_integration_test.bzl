"""The integration test rules and the runner rules that say where they run.

One test rule per family of device, sharing one implementation: the build
flags that put the app on a device (an Android ABI, a simulator CPU) must come
from the test rule itself, and a transition reads attributes but not providers,
so they cannot come from the runner. The runner rule of a family says which
device of the family, and the test rule refuses a runner of another.
"""

load("@rules_android//providers:providers.bzl", "AndroidSdkInfo")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo", "FlutterLinuxRuntimeInfo")
load("//flutter/private:dbg_transition.bzl", "DBG_SETTINGS", "dbg_transition")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_android_emulator.bzl", "FlutterAndroidSystemImageInfo")
load("//flutter/private:flutter_linux_runtime.bzl", "linux_runtime_check")
load("//flutter/private:program_analysis.bzl", "BundledProgramInfo", "bundled_program_aspect")
load("//flutter/private:test_tags.bzl", "tag_selectors")

visibility("//flutter/...")

_ANDROID_PLATFORMS = str(Label("@rules_android//flags:android_platforms"))

def _android_dbg_transition_impl(_settings, attr):
    # Debug mode as everywhere, and the one ABI the device runs: the engine,
    # `libapp.so` and the native libraries are the ones the device loads, which
    # `AndroidDevice.buildArgs` sets the same flag for.
    return DBG_SETTINGS | {
        _ANDROID_PLATFORMS: [str(Label("@rules_android//:" + attr.abi))],
    }

# Exported for the test of what it does to a target built under it.
android_dbg_transition = transition(
    implementation = _android_dbg_transition_impl,
    inputs = [],
    outputs = DBG_SETTINGS.keys() + [_ANDROID_PLATFORMS],
)

_IOS_MULTI_CPUS = "//command_line_option:ios_multi_cpus"

# The configuration an iOS simulator test's app is built in: debug mode, for
# the arm64 simulator. rules_flutter supports Apple-silicon Macs only, whose
# simulator runs arm64 apps; there is no x86_64 iOS toolchain. The dev tool's
# own build says the same (`--ios_multi_cpus=sim_arm64`).
IOS_SIMULATOR_DBG_SETTINGS = DBG_SETTINGS | {_IOS_MULTI_CPUS: ["sim_arm64"]}

def _ios_simulator_dbg_transition_impl(_settings, _attr):
    return IOS_SIMULATOR_DBG_SETTINGS

ios_simulator_dbg_transition = transition(
    implementation = _ios_simulator_dbg_transition_impl,
    inputs = [],
    outputs = DBG_SETTINGS.keys() + [_IOS_MULTI_CPUS],
)

ANDROID = "android"
DESKTOP = "desktop"
IOS_SIMULATOR = "ios_simulator"
WEB = "web"

# What a runner of a desktop, Android or iOS simulator test asks of the test's
# placement: the app runs on this machine, in this machine's session, or on a
# device attached to it, so neither a remote executor nor Bazel's sandbox can
# host the test.
#
# The web family asks for neither (`flutter_chrome_runner`): its browser is a
# pinned headless shell that runs from the test's runfiles, on a profile and a
# loopback port of its own, and needs no desktop session, so the test is
# sandboxed and its result cached remotely like any other test.
_EXECUTION_REQUIREMENTS = {
    "no-remote": "1",
    "no-sandbox": "1",
}

def _linux_runtime_launcher(ctx):
    """What a runner's `linux_runtime` adds to its launcher config and runfiles."""
    runtime = ctx.attr.linux_runtime
    if not runtime:
        return {}, depset()
    info = runtime[FlutterLinuxRuntimeInfo]
    return {"linuxRuntime": info.config}, info.files

_LINUX_RUNTIME_ATTR = attr.label(
    doc = "On a Linux host, the runtime the test runs with in place of the host's libraries: a `flutter_linux_runtime`, such as `@flutter_linux_runtime_amd64//:runtime`. Without one a Linux test fails, saying so.",
    providers = [FlutterLinuxRuntimeInfo],
)

def _flutter_desktop_runner_impl(ctx):
    launcher, runfiles = _linux_runtime_launcher(ctx)
    return [FlutterIntegrationRunnerInfo(
        family = DESKTOP,
        launcher_config = struct(**launcher),
        runfiles = runfiles,
        execution_requirements = dict(_EXECUTION_REQUIREMENTS),
        target_compatible_with = [],
    )]

flutter_desktop_runner = rule(
    implementation = _flutter_desktop_runner_impl,
    attrs = {
        "linux_runtime": _LINUX_RUNTIME_ATTR,
    },
    doc = """Runs a desktop integration test on the host's own desktop, or on Linux on an X server of the test's own.

On macOS the test needs a desktop session: an unlocked screen and an awake
display. The runner checks both before it launches the app and fails, saying
which, when either is not so. It holds the display awake for the run and takes a
lock on the screen (`macos-gui`), because a window that is covered stops
producing frames, so two tests share the screen one after the other.

On Windows the app's window is created on the desktop of the session the test
runs in, which needs no check and no lock: windows that overlap keep drawing.

On Linux the app draws on an X server the test starts for itself, never the
host's display, with the GTK, software OpenGL and fonts of `linux_runtime`
rather than the host's: the test needs no desktop session and no library of the
host's but its C and C++ runtime, and tests do not share a screen.""",
)

def _flutter_chrome_runner_impl(ctx):
    chrome = ctx.file.chrome
    chrome_files = depset([chrome], transitive = [ctx.attr.chrome[DefaultInfo].default_runfiles.files])
    launcher, runtime_files = _linux_runtime_launcher(ctx)
    validation = []
    if ctx.attr.linux_runtime:
        # The browser loads the runtime's libraries, so it is held to what the
        # runtime is: nothing more of the host than its floor, and nothing the
        # runtime lacks.
        info = ctx.attr.linux_runtime[FlutterLinuxRuntimeInfo]
        validation.append(linux_runtime_check(
            ctx,
            portable_tools(ctx),
            ctx.file._linux_runtime_tool,
            ctx.label.name,
            checked = chrome_files,
            providers = info.libraries,
            floor = info.floor,
        ))
    return [
        DefaultInfo(files = depset([chrome])),
        FlutterIntegrationRunnerInfo(
            family = WEB,
            launcher_config = struct(chrome = runfiles_path(chrome, ctx.workspace_name), **launcher),
            # The browser and what it needs beside itself: `chrome` is the file to
            # run and its `data` the libraries and resources it loads.
            runfiles = depset(transitive = [chrome_files, runtime_files]),
            execution_requirements = {},
            target_compatible_with = [],
        ),
        OutputGroupInfo(_validation = depset(validation)),
    ]

flutter_chrome_runner = rule(
    implementation = _flutter_chrome_runner_impl,
    attrs = {
        "chrome": attr.label(
            doc = "The browser: a target whose one file is the executable, carrying the rest of the browser as `data` (the Chrome for Testing repositories' `chrome`).",
            mandatory = True,
            allow_single_file = True,
        ),
        "linux_runtime": _LINUX_RUNTIME_ATTR,
        "_linux_runtime_tool": attr.label(
            default = "//flutter/private/tools:linux_runtime.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """Runs a web integration test in a headless Chrome of the runner's own.

`chrome` is the executable the test launches, on a profile of its own that is
deleted when the test ends; the browser is the one the runner names rather than
one found on the host, so the page is drawn by the same browser everywhere the
test runs. The default runner, `@rules_flutter//flutter/integration_test:chrome`,
is a pinned Chrome for Testing headless shell for the host.

On Linux the browser loads the libraries of `linux_runtime` rather than the
host's, and the build checks that it needs none the runtime lacks. On Linux and
macOS it runs without its own sandbox, as upstream's headless Chrome does: on
Linux the sandbox needs the host set up for it (unprivileged user namespaces,
which Ubuntu denies by default since 23.10, or Chrome's set-user-ID helper), and
on macOS it cannot be applied inside Bazel's sandbox, which confines the test
instead. The test asks for neither `no-sandbox` nor `no-remote`.""",
)

# The families whose app cannot be handed an environment, and what to call
# their devices.
_FAMILIES_WITHOUT_ENVIRONMENT = {
    ANDROID: "an Android device",
    IOS_SIMULATOR: "an iOS simulator",
}

def _android_host_tools(ctx):
    """The `adb` of the runner's SDK and the `aapt2` of `@androidsdk`.

    Args:
      ctx: The context of an Android runner, with `sdk` and `_aapt2`.

    Returns:
      A struct of `launcher_config` (the runfiles paths of `adb` and `aapt2`)
      and `runfiles` (a depset of the files they run with).
    """

    # The SDK says which `adb` it has for the platform its tools run on, so the
    # one named here runs on the host that runs the test: `adb.exe` on Windows.
    adb = ctx.attr.sdk[AndroidSdkInfo].adb.executable
    aapt2 = ctx.attr._aapt2[DefaultInfo]
    workspace = ctx.workspace_name
    return struct(
        launcher_config = {
            "aapt2": runfiles_path(aapt2.files_to_run.executable, workspace),
            "adb": runfiles_path(adb, workspace),
        },
        runfiles = depset(
            [adb, aapt2.files_to_run.executable],
            transitive = [aapt2.default_runfiles.files],
        ),
    )

# The `aapt2` that reads the app's package and launchable activity out of the
# APK: the one of the SDK that built it, `@androidsdk` (the Android toolchain's
# default), for the host that runs the test, as `adb` is.
_AAPT2_ATTR = attr.label(
    default = Label("@androidsdk//:aapt2"),
    # A script beside its binary on Linux and macOS, `aapt2.exe` itself on
    # Windows.
    allow_files = True,
    cfg = "exec",
    executable = True,
)

def _flutter_android_device_runner_impl(ctx):
    tools = _android_host_tools(ctx)
    return [FlutterIntegrationRunnerInfo(
        family = ANDROID,
        launcher_config = struct(**tools.launcher_config),
        runfiles = tools.runfiles,
        execution_requirements = dict(_EXECUTION_REQUIREMENTS),
        target_compatible_with = [],
    )]

flutter_android_device_runner = rule(
    implementation = _flutter_android_device_runner_impl,
    attrs = {
        "sdk": attr.label(
            doc = "The Android SDK, an `android_sdk` target such as `@androidsdk//:sdk`. Its `adb` runs the test.",
            mandatory = True,
            cfg = "exec",
            providers = [AndroidSdkInfo],
        ),
        "_aapt2": _AAPT2_ATTR,
    },
    doc = """Runs an Android integration test on an attached phone or a running emulator.

The device is the one `ANDROID_SERIAL` names (`--test_env=ANDROID_SERIAL=<serial>`),
else the only one attached; none, or several with none named, fails the test,
naming `adb devices`. The app is installed over the `adb` of `sdk`,
started, and driven through the VM service forwarded from the device. It stays
installed afterwards, as `flutter test` leaves it. The test takes a lock on the
device (`android-<serial>`), so two tests on one device run one after the other
instead of installing over each other.

`adb` is the SDK's own, never one found on `PATH`, and the one the SDK has for the
host the test runs on (`adb.exe` on Windows). The `aapt2` that reads the app's
package and launchable activity out of the APK is that of `@androidsdk`, the SDK
that built it.""",
)

def _flutter_android_emulator_runner_impl(ctx):
    tools = _android_host_tools(ctx)
    image = ctx.attr.system_image[FlutterAndroidSystemImageInfo]
    emulator = ctx.file.emulator
    emulator_files = depset([emulator], transitive = [ctx.attr.emulator[DefaultInfo].default_runfiles.files])
    launcher, runtime_files = _linux_runtime_launcher(ctx)
    validation = []
    if ctx.attr.linux_runtime:
        # The emulator loads the runtime's libraries (the X client libraries it
        # links), so it is held to what the runtime is, as a browser is.
        info = ctx.attr.linux_runtime[FlutterLinuxRuntimeInfo]
        validation.append(linux_runtime_check(
            ctx,
            portable_tools(ctx),
            ctx.file._linux_runtime_tool,
            ctx.label.name,
            checked = emulator_files,
            providers = info.libraries,
            floor = info.floor,
        ))
    workspace = ctx.workspace_name
    return [
        DefaultInfo(files = depset([emulator])),
        OutputGroupInfo(_validation = depset(validation)),
        FlutterIntegrationRunnerInfo(
            family = ANDROID,
            launcher_config = struct(
                emulator = struct(
                    executable = runfiles_path(emulator, workspace),
                    systemImage = runfiles_path(image.properties, workspace),
                    abi = image.abi,
                    apiLevel = image.api_level,
                    tag = image.tag,
                    cores = ctx.attr.cores,
                    memoryMb = ctx.attr.memory_mb,
                ),
                **(launcher | tools.launcher_config)
            ),
            runfiles = depset(transitive = [tools.runfiles, emulator_files, image.files, runtime_files]),
            # What the emulator takes of the machine, so that Bazel schedules the
            # test with it: its virtual cores, and the host's work of drawing
            # its screen and serving its devices.
            execution_requirements = dict(_EXECUTION_REQUIREMENTS) | {"cpu:%d" % (ctx.attr.cores + 1): ""},
            target_compatible_with = [],
        ),
    ]

flutter_android_emulator_runner = rule(
    implementation = _flutter_android_emulator_runner_impl,
    attrs = {
        "cores": attr.int(
            doc = "The emulated device's CPU cores. The test is scheduled with one core more, for the emulator's own work on the host.",
            default = 2,
        ),
        "emulator": attr.label(
            doc = "The Android emulator: a target whose one file is the `emulator` launcher, carrying the rest of the emulator as `data`, such as `@rules_flutter//flutter/integration_test:android_emulator`, the pinned emulator of the host.",
            mandatory = True,
            allow_single_file = True,
        ),
        "linux_runtime": _LINUX_RUNTIME_ATTR,
        "_linux_runtime_tool": attr.label(
            default = "//flutter/private/tools:linux_runtime.dart",
            allow_single_file = True,
        ),
        "memory_mb": attr.int(
            doc = "The emulated device's memory, in MB.",
            default = 2048,
        ),
        "sdk": attr.label(
            doc = "The Android SDK, an `android_sdk` target such as `@androidsdk//:sdk`. Its `adb` drives the emulator.",
            mandatory = True,
            cfg = "exec",
            providers = [AndroidSdkInfo],
        ),
        "_aapt2": _AAPT2_ATTR,
        "system_image": attr.label(
            doc = "The system image the emulator boots, a `flutter_android_system_image`, such as `@rules_flutter//flutter/integration_test:android_system_image`, the pinned AOSP test image of the host's ABI. A test's `abi` must be the image's.",
            mandatory = True,
            providers = [FlutterAndroidSystemImageInfo],
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """Runs an Android integration test on an emulator the test boots for itself.

Each test makes a device (an AVD) of `system_image` in its own temporary
directory, boots it with `emulator` with no window, from a cold start with fresh
data, installs and drives the app as on any device, and shuts the emulator down
however the test ends, a Bazel timeout included. The emulator answers to an `adb`
server of the test's own, which sees no USB or network device, so the test
touches no phone attached to the host and an attached phone is no obstacle.
Each test takes a pair of the emulator ports `adb` knows (5554 to 5585, passing
over those of emulators already running) and holds a lock on them for its run,
so up to 16 tests boot emulators side by side. An emulator that a SIGKILL left
behind is shut down by the next Android emulator test to take its ports. The
emulator's log and the device's (`emulator.log`, `logcat.txt`) are among the
test's outputs.

The emulator needs the host's hypervisor: Hypervisor.framework on macOS, KVM
(`/dev/kvm`, readable and writable by the user) on Linux. Without it the test
fails, saying how to enable it, before anything is booted. On Linux the emulator
loads the X client libraries it links from `linux_runtime` rather than the
host's, and the build checks that it needs none the runtime lacks.""",
)

def _flutter_ios_simulator_runner_impl(ctx):
    return [FlutterIntegrationRunnerInfo(
        family = IOS_SIMULATOR,
        launcher_config = struct(
            deviceType = ctx.attr.device_type,
            runtime = ctx.attr.runtime,
        ),
        runfiles = depset(),
        # What a simulator takes of the machine, so that Bazel schedules the test
        # with it. Measured: the processes under a booted simulator's launchd
        # used 15 CPU-seconds in the 20 seconds a test took, 0.75 of a core on
        # average; the services the simulator talks to on the host are not in
        # that, hence two.
        execution_requirements = dict(_EXECUTION_REQUIREMENTS) | {"cpu:%d" % ctx.attr.cpus: ""},
        target_compatible_with = [],
    )]

flutter_ios_simulator_runner = rule(
    implementation = _flutter_ios_simulator_runner_impl,
    attrs = {
        "device_type": attr.string(
            doc = "The simulator's device type, as `xcrun simctl list devicetypes` names it.",
            default = "iPhone 16",
        ),
        "runtime": attr.string(
            doc = "The simulator's runtime: an identifier or name `xcrun simctl list runtimes` lists. Empty is the newest installed runtime that suits the device type.",
        ),
        "cpus": attr.int(
            doc = "The cores a test on this runner is scheduled with.",
            default = 2,
        ),
    },
    doc = """Runs an iOS integration test on a simulator the test makes for itself.

Each test makes a simulator (`rules_flutter-<test>-<pid>-<start>`) of `device_type`,
boots it, installs the app, drives the suite through the app's VM service, and
shuts the simulator down and deletes it however the test ends, a Bazel timeout
included. A simulator that a SIGKILL left behind is deleted by the next iOS test
run, once the run that made it is gone. A fresh simulator shares no state with another test or with the
simulators of the person running it, so tests need no lock. No runtime installed
fails the test, saying `xcodebuild -downloadPlatform iOS`.""",
)

def integration_test_impl(ctx, family, inherited_environment = []):
    """The implementation every integration test rule shares.

    Args:
        ctx: The rule context: `app`, `runner`, `env`, `data` and `_runner`.
        family: The family of device this rule runs the app on.
        inherited_environment: What the test takes from the invoking shell.

    Returns:
        The rule's providers.
    """
    if family in _FAMILIES_WITHOUT_ENVIRONMENT and ctx.attr.env:
        fail((
            "%s: `env` is %s, but an app on %s cannot receive an environment: " +
            "the app starts as the device starts apps. Pass what the app " +
            "should see as `defines` of the program (`flutter_application_variant`) instead."
        ) % (ctx.label, ctx.attr.env, _FAMILIES_WITHOUT_ENVIRONMENT[family]))

    runner = ctx.attr.runner[FlutterIntegrationRunnerInfo]
    if runner.family != family:
        fail((
            "%s: `runner` %s is for %s devices, and this rule runs the app on a " +
            "%s one. Use a runner of the family the rule is for."
        ) % (ctx.label, ctx.attr.runner.label, runner.family, family))

    # A list: the attribute has a transition, which makes its value one.
    app = ctx.attr.app[0]
    app_files = app[DefaultInfo].files.to_list()
    if not app_files:
        fail("%s: `app` %s builds no files, so there is nothing to launch." % (ctx.label, app.label))

    workspace = ctx.workspace_name

    # The goldens of the test are compared by a `flutter_test` the host runner
    # starts (it has no `dart:ui`), which is told the test's source: goldens are
    # relative to its directory.
    service = ctx.attr.golden_service
    goldens = None
    if service:
        goldens = {
            "executable": runfiles_path(service[DefaultInfo].files_to_run.executable, workspace),
            "environment": service[RunEnvironmentInfo].environment,
            "testSource": ctx.file.src.short_path,
        }

    config = ctx.actions.declare_file(ctx.label.name + ".integration_config.json")
    ctx.actions.write(config, json.encode({
        "family": family,
        "appArtifacts": [runfiles_path(f, workspace) for f in app_files],
        "launcher": runner.launcher_config,
        "testDisplayName": str(ctx.label),
        "env": ctx.attr.env,
        "goldens": goldens,
        # Read by the host runner for the library's `@Tags`.
        "source": runfiles_path(ctx.file.src, workspace),
        "includeTags": tag_selectors(ctx, "include_tags", "integration test"),
        "excludeTags": tag_selectors(ctx, "exclude_tags", "integration test"),
    }))

    tool = ctx.attr._runner
    tool_executable = tool[DefaultInfo].files_to_run.executable

    # The tool's extension too: Windows starts only a `.exe` (or `.bat`).
    executable = ctx.actions.declare_file(ctx.label.name + ("." + tool_executable.extension if tool_executable.extension else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = tool_executable,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [config, ctx.file.src] + app_files + ctx.files.data,
        transitive_files = runner.runfiles,
    ).merge(tool[DefaultInfo].default_runfiles).merge(app[DefaultInfo].default_runfiles)
    for data in ctx.attr.data:
        runfiles = runfiles.merge(data[DefaultInfo].default_runfiles)
    if service:
        runfiles = runfiles.merge(service[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = ctx.attr.env | {
                "FLUTTER_INTEGRATION_TEST_CONFIG": runfiles_path(config, workspace),
            },
            inherited_environment = inherited_environment,
        ),
        testing.ExecutionInfo(runner.execution_requirements),
    ] + _program_analyzable_info(app)

def _program_analyzable_info(app):
    """The program's own Dart files, for rules_dart's analysis to check the test file and what it imports under the test's name.

    As the app passes them on, or, for an Android app (rules_android's
    `android_binary`, which passes nothing on), as `bundled_program_aspect`
    reads them off its `flutter_android_bundle`.

    Args:
      app: The test's app Target.

    Returns:
      A list of the program's `DartAnalyzableInfo`, or an empty list.
    """
    if DartAnalyzableInfo in app:
        return [app[DartAnalyzableInfo]]
    program = app[BundledProgramInfo] if BundledProgramInfo in app else None
    return [program.info] if program and program.info else []

# The attributes every integration test rule has, whatever its family.
#
# `default_runner` is the runner a test is given when it names none, and None
# for a family that has no runner of its own to default to. `cfg` is the
# transition the app is built under. `app_aspects` find the program inside an
# app whose rule passes nothing of it on.
def _test_attrs(default_runner, cfg = dbg_transition, app_aspects = []):
    return {
        "app": attr.label(
            doc = "The app the test runs, built in debug mode whatever the command line says: the suite is driven through the VM service a debug build serves, as `flutter test` forces debug for an integration test.",
            mandatory = True,
            cfg = cfg,
            aspects = app_aspects,
        ),
        "runner": attr.label(
            doc = "Where the app runs.",
            default = Label(default_runner) if default_runner else None,
            mandatory = not default_runner,
            providers = [FlutterIntegrationRunnerInfo],
        ),
        "env": attr.string_dict(
            doc = "Environment variables for the host runner and, on desktop, for the app's process.",
        ),
        "data": attr.label_list(
            doc = "Files the test reads at run time, and its golden files: `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the directory of `src`, so the goldens are listed here (`data = glob([\"integration_test/goldens/**\"])`).",
            allow_files = True,
        ),
        "src": attr.label(
            doc = "The test's source file: its library `@Tags` select cases, and golden files are relative to its directory.",
            allow_single_file = [".dart"],
            mandatory = True,
        ),
        "include_tags": attr.string_list(
            doc = "Tag selectors a case must match to run, as `flutter test --tags` takes them and as `dart_test.yaml`'s `include_tags` does: each entry is one boolean selector (`golden`, `a && !b`), and a case must match every entry. Tags come from `@Tags` on the test library and `tags:` on a `testWidgets`. These are `package:test` tags, not Bazel's `tags`. A target none of whose cases match fails. `--test_env=DART_TEST_TAGS=...` narrows further for one run.",
        ),
        "exclude_tags": attr.string_list(
            doc = "Tag selectors that drop a case, as `flutter test --exclude-tags` takes them and as `dart_test.yaml`'s `exclude_tags` does: a case matching any entry does not run. `package:test` tags, not Bazel's `tags`. A target none of whose cases remain fails. `--test_env=DART_TEST_EXCLUDE_TAGS=...` drops more for one run.",
        ),
        "golden_service": attr.label(
            doc = "A `flutter_test` running `@rules_flutter//flutter/private/goldens:service.dart`, which compares the test's goldens for the host runner: comparing needs `dart:ui`, which the runner has not. The macros declare one. Without it every golden fails, saying there is no comparator.",
            executable = True,
            cfg = "target",
            providers = [RunEnvironmentInfo],
        ),
        "_runner": attr.label(
            default = Label("//tools/dev_tool:integration_test_runner"),
            executable = True,
            cfg = "target",
        ),
    }

def _flutter_desktop_app_integration_test_impl(ctx):
    return integration_test_impl(ctx, DESKTOP)

flutter_desktop_app_integration_test = rule(
    implementation = _flutter_desktop_app_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:desktop"),
    test = True,
    doc = """Runs the desktop app `app` (`flutter_macos_app`, `flutter_windows_app` or `flutter_linux_app`) on the host and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter`, `shard_count`, and tags
(`include_tags`, `exclude_tags`, `--test_env=DART_TEST_TAGS=...`; not Bazel's `tags`) select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The test is built in debug mode, runs outside Bazel's sandbox and never remotely.
A macOS app needs an unlocked, awake desktop session; a Windows app (`flutter_windows_app`)
needs a Windows session that can create a window; a Linux app (`flutter_linux_app`)
draws on an X server the test starts for itself, with the runner's
`linux_runtime` in place of the host's libraries, and needs no desktop session.""",
)

def _flutter_web_app_integration_test_impl(ctx):
    return integration_test_impl(ctx, WEB)

flutter_web_app_integration_test = rule(
    implementation = _flutter_web_app_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:chrome"),
    test = True,
    doc = """Runs the web bundle `app` (`flutter_web_app` or `flutter_web_bundle`) in the runner's headless Chrome and reports the integration test suite it runs.

The bundle's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. The
suite is driven over the browser's DevTools protocol, which is what a web bundle
has in place of a VM service. A suite that registers no test fails, as does a
page that is lost during a test, with the reason the browser gives.

The test is built in debug mode, runs outside Bazel's sandbox and never remotely.
The bundle is served from a directory of its own on the loopback, and the
browser's profile is deleted when the test ends.""",
)

def _flutter_android_app_integration_test_impl(ctx):
    emulator = getattr(ctx.attr.runner[FlutterIntegrationRunnerInfo].launcher_config, "emulator", None)
    if emulator and emulator.abi != ctx.attr.abi:
        fail((
            "%s: the app is built for %s, and the runner %s boots an emulator " +
            "of %s, which cannot install it. Build the app for the image's ABI " +
            "(`abi = \"%s\"`), or give the runner an image of %s."
        ) % (ctx.label, ctx.attr.abi, ctx.attr.runner.label, emulator.abi, emulator.abi, ctx.attr.abi))
    return integration_test_impl(ctx, ANDROID, inherited_environment = ["ANDROID_SERIAL"])

flutter_android_app_integration_test = rule(
    implementation = _flutter_android_app_integration_test_impl,
    attrs = _test_attrs(None, cfg = android_dbg_transition, app_aspects = [bundled_program_aspect]) | {
        "abi": attr.string(
            doc = "The ABI the app is built for, which the device must run: the platform of `--@rules_android//flags:android_platforms` the app is built under, whatever the command line says.",
            default = "arm64-v8a",
            values = ["armeabi-v7a", "arm64-v8a", "x86_64"],
        ),
    },
    test = True,
    doc = """Runs the Android app `app` (`flutter_android_app`) on a device and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The app is built in debug mode for `abi`, whatever the command line says, and the
test runs outside Bazel's sandbox and never remotely. An app on a device cannot be
handed an environment, so a non-empty `env` fails analysis; its `defines` are the
program's.

An integration test's app links `integration_test`'s Android library, which needs
`androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core`
and `com.google.guava:guava` in the workspace's `@rules_flutter_maven` install:
analysis says which are missing.""",
)

def _flutter_ios_app_integration_test_impl(ctx):
    if (ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]) and
        ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])):
        fail((
            "%s: rules_flutter supports Apple Silicon hosts only. An Intel " +
            "Mac's simulator runs x86_64 apps, and rules_flutter builds iOS " +
            "for arm64 alone."
        ) % ctx.label)
    return integration_test_impl(ctx, IOS_SIMULATOR, inherited_environment = ["DEVELOPER_DIR"])

flutter_ios_app_integration_test = rule(
    implementation = _flutter_ios_app_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:ios_simulator", cfg = ios_simulator_dbg_transition) | {
        "_macos_constraint": attr.label(default = "@platforms//os:macos"),
        "_x86_64_constraint": attr.label(default = "@platforms//cpu:x86_64"),
    },
    test = True,
    doc = """Runs the iOS app `app` (`flutter_ios_app`) on a simulator made for the test and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The app is built in debug mode for the arm64 simulator, whatever the command line
says, and the test runs outside Bazel's sandbox and never remotely. An app on a simulator
cannot be handed an environment, so a non-empty `env` fails analysis; its
`defines` are the program's.""",
)
