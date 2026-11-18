"""Whether the engine of the selected SDK holds what a mobile app is built for.

A custom engine is built for one CPU, and an iOS one for one environment (the
device or the simulator). The release's engines hold every one an app can be
built for, so these checks pass for it; for a local engine they fail at
analysis, naming the engine and what it holds, rather than at link time or at
launch.
"""

load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:engine_labels.bzl", "android_engine_cpu")

visibility("//flutter/...")

def check_ios_engine(label, sdk_record, arch, is_device):
    """Fails when the iOS engine has no xcframework slice for the app's environment and CPU.

    Args:
        label: The target being built.
        sdk_record: The `FlutterSdkRecordInfo` of the SDK.
        arch: The CPU of the build (`arm64`, `x86_64`).
        is_device: Whether the build is for a device, not the simulator.
    """
    slices = sdk_record.engine_xcframework_slices
    if not slices:
        return
    for platform_dir in slices:
        # `ios-arm64`, `ios-arm64-simulator`, `ios-arm64_x86_64-simulator`.
        is_simulator = platform_dir.endswith("-simulator")
        if is_simulator == is_device:
            continue
        if arch in platform_dir[len("ios-"):]:
            return
    fail(("%s: the engine %s has the xcframework slices %s, and this build is for the %s on %s. " +
          "Build the engine for it (a device build needs an `ios_<mode>` out dir, the simulator an " +
          "`ios_debug_sim` one for the CPU), or build for what the engine has.") % (
        label,
        sdk_record.engine_label,
        ", ".join(slices),
        "device" if is_device else "simulator",
        arch,
    ))

def check_desktop_engine(label, sdk_record, arch):
    """Fails when a Linux or Windows engine was not built for the CPU of the app.

    Args:
        label: The target being built.
        sdk_record: The `FlutterSdkRecordInfo` of the SDK.
        arch: The CPU of the build (`arm64`, `x64`).
    """
    cpu = "arm64" if arch == "arm64" else "x86_64"
    if sdk_record.engine_cpus and cpu not in sdk_record.engine_cpus:
        fail(("%s: the engine %s contains %s, and this build is for %s. " +
              "Build the engine for %s, or build for %s.") % (
            label,
            sdk_record.engine_label,
            ", ".join(sdk_record.engine_cpus),
            cpu,
            cpu,
            ", ".join(sdk_record.engine_cpus),
        ))

def check_android_engine(label, sdk_record, abi):
    """Fails when the Android engine was not built for the CPU of the app's ABI.

    Args:
        label: The target being built.
        sdk_record: The `FlutterSdkRecordInfo` of the SDK.
        abi: The ABI of the build (`arm64-v8a`, `x86_64`).
    """
    cpu = android_engine_cpu([arch for arch, name in ANDROID_ABI_FOR_ARCH.items() if name == abi][0])
    if sdk_record.engine_cpus and cpu not in sdk_record.engine_cpus:
        fail(("%s: the engine %s contains %s, and this build is for %s. " +
              "Build the engine for %s, or build for %s.") % (
            label,
            sdk_record.engine_label,
            ", ".join(sdk_record.engine_cpus),
            cpu,
            cpu,
            ", ".join(sdk_record.engine_cpus),
        ))
