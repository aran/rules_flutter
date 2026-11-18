"""What an Android emulator runner boots: a system image, and what it is."""

visibility("//flutter/...")

FlutterAndroidSystemImageInfo = provider(
    doc = "An Android emulator system image: what the emulator's device is configured as, and the image's files.",
    fields = {
        "abi": "The ABI the image runs: `arm64-v8a` or `x86_64`.",
        "api_level": "The image's Android API level, an int.",
        "files": "depset of the image's files.",
        "properties": "The image's `source.properties`, whose directory is the image.",
        "tag": "The image's tag, such as `aosp_atd` or `google_apis`.",
    },
)

def _flutter_android_system_image_impl(ctx):
    files = depset([ctx.file.properties] + ctx.files.files)
    return [
        DefaultInfo(files = files),
        FlutterAndroidSystemImageInfo(
            abi = ctx.attr.abi,
            api_level = ctx.attr.api_level,
            files = files,
            properties = ctx.file.properties,
            tag = ctx.attr.tag,
        ),
    ]

flutter_android_system_image = rule(
    implementation = _flutter_android_system_image_impl,
    attrs = {
        "abi": attr.string(
            doc = "The ABI the image runs, which a test's app must be built for.",
            mandatory = True,
            values = ["arm64-v8a", "x86_64"],
        ),
        "api_level": attr.int(doc = "The image's Android API level.", mandatory = True),
        "files": attr.label_list(
            doc = "The rest of the image: `system.img`, `kernel-ranchu` and the files beside them.",
            allow_files = True,
        ),
        "properties": attr.label(
            doc = "The image's `source.properties`, in the image's directory.",
            allow_single_file = True,
            mandatory = True,
        ),
        "tag": attr.string(doc = "The image's tag, such as `aosp_atd`, `google_atd` or `google_apis`.", mandatory = True),
    },
    doc = """An Android system image an emulator runner boots: an archive of Google's Android SDK repository, extracted as it is.

`@rules_flutter//flutter/integration_test:android_system_image` is the pinned
AOSP Automated Test Device image of the host's ABI. To boot another, extract its
archive (`https://dl.google.com/android/repository/sys-img/<tag>/<abi>-<api>_<revision>.zip`)
with `http_archive` and declare it with this rule.""",
)
