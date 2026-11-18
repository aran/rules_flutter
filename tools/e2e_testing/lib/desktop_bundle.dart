/// Checks on a built Linux or Windows bundle directory.
library;

import 'dart:io';

import 'dart:convert';

import 'bundle_check.dart';
import 'bytes.dart';
import 'runfiles_paths.dart';

/// A bundle directory `flutter_linux_app` or `flutter_windows_app` produced,
/// found in the test's runfiles.
///
/// A bundle holds its runner next to the engine and a `data/` directory. The
/// two platforms name those differently; [LinuxBundle] and [WindowsBundle]
/// say how, and both check the layout every Flutter app has.
abstract class DesktopBundle {
  DesktopBundle(this.path, {BundleCheck? check})
    : name = path.split(RegExp(r'[\\/]')).last,
      check = check ?? BundleCheck();

  /// The bundle directory.
  final String path;

  /// The runner's name, which is also the bundle directory's.
  final String name;

  /// Where checks are recorded.
  final BundleCheck check;

  /// The runner binary.
  String get runner;

  /// Where `data/` is under [path].
  String get dataDir => '$path/data';

  /// `data/flutter_assets`.
  String get flutterAssets => '$dataDir/flutter_assets';

  /// The engine library the runner loads.
  String get engineLibrary;

  /// The AOT snapshot a release build holds.
  String get aotSnapshot;

  /// What the platform calls its bundle in the success line.
  String get platform;

  /// Checks the layout every Flutter app on this platform has: the runner,
  /// the engine, the Dart code (an AOT snapshot or, in a debug build, a kernel
  /// blob), the asset manifests and ICU data.
  void checkStandardLayout() {
    check
      ..exists('Runner binary', runner, nonEmpty: true)
      ..exists(
        engineLibrary.split(RegExp(r'[\\/]')).last,
        engineLibrary,
        nonEmpty: true,
      );
    final kernelBlob = '$flutterAssets/kernel_blob.bin';
    if (File(aotSnapshot).existsSync()) {
      check.exists('AOT snapshot', aotSnapshot, nonEmpty: true);
    } else if (File(kernelBlob).existsSync()) {
      check.exists('Kernel blob (debug)', kernelBlob, nonEmpty: true);
    } else {
      check.fail(
        'Neither ${_relative(aotSnapshot)} nor ${_relative(kernelBlob)} found',
      );
    }
    check
      ..exists('flutter_assets directory', flutterAssets)
      ..exists('AssetManifest.bin', '$flutterAssets/AssetManifest.bin')
      ..exists('FontManifest.json', '$flutterAssets/FontManifest.json')
      ..exists('NOTICES.Z', '$flutterAssets/NOTICES.Z')
      ..exists('icudtl.dat', '$dataDir/icudtl.dat', nonEmpty: true);
  }

  /// [relative], a path under the bundle, as a full path.
  String file(String relative) => '$path/$relative';

  /// Ends the test: prints the success line if every check passed; otherwise
  /// lists the bundle and exits 1.
  void finish() {
    check.finish(
      'All $platform bundle verification checks passed.',
      onFailure: () {
        stderr
          ..writeln()
          ..writeln('Actual bundle contents:');
        check.listTree(Directory(path));
      },
    );
  }

  String _relative(String file) => file.substring(path.length + 1);
}

/// A bundle from `flutter_linux_app`.
class LinuxBundle extends DesktopBundle {
  /// The bundle in directory [path].
  LinuxBundle(super.path, {super.check});

  /// The bundle that `workspacePath` (a target name or a path) names in the
  /// test's runfiles. Exits 1 if it is not there.
  LinuxBundle.fromRunfiles(String workspacePath)
    : super(requireRunfile(workspacePath, what: 'Bundle directory'));

  @override
  String get platform => 'Linux';

  @override
  String get runner => '$path/$name';

  @override
  String get engineLibrary => '$path/lib/libflutter_linux_gtk.so';

  @override
  String get aotSnapshot => '$path/lib/libapp.so';

  /// A shared library under `lib/`.
  String lib(String file) => '$path/lib/$file';

  /// Checks the standard layout, and that `lib/` holds shared libraries
  /// alone, as `flutter build linux` installs it: the engine's headers are
  /// for compiling, not for the bundle.
  @override
  void checkStandardLayout() {
    super.checkStandardLayout();
    final dir = Directory('$path/lib');
    final others = [
      if (dir.existsSync())
        for (final entry in dir.listSync())
          if (!RegExp(r'\.so(\.[0-9]+)*$').hasMatch(entry.path))
            entry.path.substring(dir.path.length + 1),
    ]..sort();
    check.expect(
      'lib/ holds shared libraries alone',
      condition: others.isEmpty,
      detail: others.join(', '),
    );
  }
}

/// A bundle from `flutter_windows_app`.
class WindowsBundle extends DesktopBundle {
  /// The bundle in directory [path].
  WindowsBundle(super.path, {super.check});

  /// The bundle that `workspacePath` (a target name or a path) names in the
  /// test's runfiles. Exits 1 if it is not there.
  WindowsBundle.fromRunfiles(String workspacePath)
    : super(requireRunfile(workspacePath, what: 'Bundle directory'));

  @override
  String get platform => 'Windows';

  @override
  String get runner => '$path/$name.exe';

  @override
  String get engineLibrary => '$path/flutter_windows.dll';

  @override
  String get aotSnapshot => '$dataDir/app.so';

  /// Checks that the runner carries the resources `flutter create`'s
  /// `Runner.rc` and `runner.exe.manifest` give it: version information
  /// for [version] (`FLUTTER_VERSION`) with the numeric file version
  /// [fileVersion] (major, minor, patch, build), every image of the icon file
  /// [icon], and the manifest's per-monitor DPI awareness.
  void checkRunnerResources({
    required String version,
    required List<int> fileVersion,
    required String icon,
  }) {
    final exe = File(runner).readAsBytesSync();
    final [major, minor, patch, build] = fileVersion;
    // VS_FIXEDFILEINFO: its signature and structure version, then the file
    // version as two little-endian words, (major, minor) and (patch, build).
    final fixedFileInfo = [
      ..._u32le(0xFEEF04BD),
      ..._u32le(0x00010000),
      ..._u32le(major << 16 | minor),
      ..._u32le(patch << 16 | build),
    ];
    check
      ..expect(
        'Version information, file version ${fileVersion.join('.')}',
        condition: containsBytes(exe, fixedFileInfo),
      )
      ..expect(
        'Version string $version',
        condition:
            containsBytes(exe, utf16leBytes('FileVersion')) &&
            containsBytes(exe, utf16leBytes(version)),
      )
      ..expect(
        'Embedded manifest (PerMonitorV2 DPI awareness)',
        condition: containsBytes(
          exe,
          utf8.encode(
            '<dpiAwareness xmlns="http://schemas.microsoft.com/'
            'SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>',
          ),
        ),
      );
    final images = iconImages(File(icon).readAsBytesSync());
    check.expect(
      'Icon (${images.length} images of ${icon.split(RegExp(r'[\\/]')).last})',
      condition:
          images.isNotEmpty &&
          images.every((image) => containsBytes(exe, image)),
    );
  }
}

/// The images an `.ico` file holds, each as the bytes a resource compiler
/// copies into an `RT_ICON` resource.
List<List<int>> iconImages(List<int> ico) {
  int u16(int at) => ico[at] | ico[at + 1] << 8;
  int u32(int at) => u16(at) | u16(at + 2) << 16;
  return [
    for (var i = 0; i < u16(4); i++)
      ico.sublist(
        u32(6 + i * 16 + 12),
        u32(6 + i * 16 + 12) + u32(6 + i * 16 + 8),
      ),
  ];
}

List<int> _u32le(int value) => [
  for (var shift = 0; shift < 32; shift += 8) value >> shift & 0xff,
];
