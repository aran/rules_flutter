"""For rules_flutter's generated repositories only.

The repositories this module's extensions generate (the pub hub's packages,
the Apple plugin and app settings repositories, the engine face, the Linux
runtime, the Android emulator images) write BUILD files that load rules and
macros from rules_flutter. They are other repositories, so `visibility()` on
the private `.bzl` file that defines each of them would keep them out. The one
exception is this file: it is public, loads everything a generated BUILD file
needs, and re-exports it. A generated BUILD file loads from here and from no
other private file.

The e2e suites that declare a copy of a generated repository, to test the
repository rule, load that rule from here too, so the rules that make
repositories are re-exported with the rules that those repositories' BUILD
files load.

This is not an API. Names come and go with the repositories that load them,
and no user's BUILD file may load this file.
"""

load(":android_build_config.bzl", _android_build_config = "android_build_config")
load(":android_plugin_maven.bzl", _maven_labels = "maven_labels")
load(":flutter_android_emulator.bzl", _flutter_android_system_image = "flutter_android_system_image")
load(":flutter_android_engine_jar.bzl", _flutter_android_engine_jar = "flutter_android_engine_jar")
load(":flutter_android_engine_repo.bzl", _flutter_android_engine_repo = "flutter_android_engine_repo")
load(":flutter_android_plugin_libs.bzl", _flutter_android_maven_requirements = "flutter_android_maven_requirements")
load(":flutter_apple_kept_symbols.bzl", _flutter_apple_kept_symbols = "flutter_apple_kept_symbols")
load(":flutter_cross_repo.bzl", _flutter_cross_compilation_repo = "flutter_cross_compilation_repo")
load(":flutter_desktop_engine_repo.bzl", _flutter_desktop_engine_repo = "flutter_desktop_engine_repo")
load(":flutter_dev_root_repo.bzl", _flutter_dev_root_repo = "flutter_dev_root_repo")
load(":flutter_font.bzl", _flutter_font = "flutter_font", _flutter_font_family = "flutter_font_family")
load(":flutter_framework_package.bzl", _flutter_framework_package = "flutter_framework_package")
load(":flutter_gen_l10n_repo.bzl", _flutter_gen_l10n_repo = "flutter_gen_l10n_repo")
load(":flutter_ios_engine_repo.bzl", _flutter_ios_engine_repo = "flutter_ios_engine_repo")
load(":flutter_library.bzl", _aggregate_pub_contributions = "aggregate_pub_contributions", _flutter_framework_library = "flutter_framework_library")
load(":flutter_linux_runtime.bzl", _flutter_linux_runtime = "flutter_linux_runtime")
load(":flutter_linux_sysroot_repo.bzl", _flutter_linux_sysroot_repo = "flutter_linux_sysroot_repo")
load(":flutter_plugin_platform.bzl", _flutter_plugin_platform = "flutter_plugin_platform")
load(":flutter_profile_repo.bzl", _flutter_profile_repo = "flutter_profile_repo")
load(":flutter_pub_index.bzl", _INDEX_REPO = "INDEX_REPO", _files_repo = "files_repo", _flutter_pub_index = "flutter_pub_index", _library_repo = "library_repo", _source_repo = "source_repo")
load(":flutter_pub_library.bzl", _flutter_pub_library = "flutter_pub_library", _flutter_pub_member = "flutter_pub_member")
load(":flutter_pub_library_repo.bzl", _flutter_pub_library_repo = "flutter_pub_library_repo")
load(":flutter_pub_package.bzl", _flutter_pub_package = "flutter_pub_package")
load(":flutter_sky_engine_repo.bzl", _flutter_sky_engine_repo = "flutter_sky_engine_repo")
load(":flutter_source_files.bzl", _flutter_source_files = "flutter_source_files", _flutter_source_packages = "flutter_source_packages")
load(":flutter_swift_packages_report.bzl", _flutter_swift_packages_report = "flutter_swift_packages_report")
load(":flutter_test.bzl", _flutter_test = "flutter_test")
load(":flutter_web_sdk_repo.bzl", _flutter_web_sdk_repo = "flutter_web_sdk_repo")
load(":resolved_package.bzl", _resolved_package = "resolved_package")
load(":swift_package_product.bzl", _flutter_swift_package_product = "flutter_swift_package_product")
load(":swiftpm_app_settings.bzl", _flutter_swiftpm_app_libraries = "flutter_swiftpm_app_libraries", _flutter_swiftpm_app_library = "flutter_swiftpm_app_library", _flutter_swiftpm_app_settings = "flutter_swiftpm_app_settings")
load(":unbuilt_native_code.bzl", _flutter_unbuilt_plugin_library = "flutter_unbuilt_plugin_library")
load(":versions.bzl", _FLUTTER_VERSIONS = "FLUTTER_VERSIONS")

visibility("public")

FLUTTER_VERSIONS = _FLUTTER_VERSIONS
INDEX_REPO = _INDEX_REPO
aggregate_pub_contributions = _aggregate_pub_contributions
android_build_config = _android_build_config
files_repo = _files_repo
flutter_android_engine_jar = _flutter_android_engine_jar
flutter_android_engine_repo = _flutter_android_engine_repo
flutter_android_maven_requirements = _flutter_android_maven_requirements
flutter_android_system_image = _flutter_android_system_image
flutter_apple_kept_symbols = _flutter_apple_kept_symbols
flutter_cross_compilation_repo = _flutter_cross_compilation_repo
flutter_desktop_engine_repo = _flutter_desktop_engine_repo
flutter_dev_root_repo = _flutter_dev_root_repo
flutter_font = _flutter_font
flutter_font_family = _flutter_font_family
flutter_framework_library = _flutter_framework_library
flutter_framework_package = _flutter_framework_package
flutter_gen_l10n_repo = _flutter_gen_l10n_repo
flutter_ios_engine_repo = _flutter_ios_engine_repo
flutter_linux_runtime = _flutter_linux_runtime
flutter_linux_sysroot_repo = _flutter_linux_sysroot_repo
flutter_plugin_platform = _flutter_plugin_platform
flutter_profile_repo = _flutter_profile_repo
flutter_pub_index = _flutter_pub_index
flutter_pub_library = _flutter_pub_library
flutter_pub_library_repo = _flutter_pub_library_repo
flutter_pub_member = _flutter_pub_member
flutter_pub_package = _flutter_pub_package
flutter_sky_engine_repo = _flutter_sky_engine_repo
flutter_source_files = _flutter_source_files
flutter_source_packages = _flutter_source_packages
flutter_swift_package_product = _flutter_swift_package_product
flutter_swift_packages_report = _flutter_swift_packages_report
flutter_swiftpm_app_libraries = _flutter_swiftpm_app_libraries
flutter_swiftpm_app_library = _flutter_swiftpm_app_library
flutter_swiftpm_app_settings = _flutter_swiftpm_app_settings
flutter_test = _flutter_test
flutter_unbuilt_plugin_library = _flutter_unbuilt_plugin_library
flutter_web_sdk_repo = _flutter_web_sdk_repo
library_repo = _library_repo
maven_labels = _maven_labels
resolved_package = _resolved_package
source_repo = _source_repo
