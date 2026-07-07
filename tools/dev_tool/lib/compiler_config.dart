/// Configuration for frontend_server's compilation target.
///
/// Abstracts the difference between native (VM) and web (DDC) compilation
/// so [FrontendServer] can work with either target.
import 'toolchain_info.dart';

/// What the frontend server needs to compile for a given platform.
abstract interface class CompilerConfig {
  /// The `--target` flag: 'flutter' for native, 'dartdevc' for web.
  String get targetFlag;

  /// The `--sdk-root` path.
  String get sdkRoot;

  /// Additional flags beyond target, sdk-root, incremental, packages, output-dill.
  List<String> get extraFlags;
}

/// Compiler config for native platforms (macOS, Linux, Windows, iOS, Android).
///
/// Uses `--target=flutter` with the patched SDK and asserts enabled.
///
/// For a source-assembled (codegen) app, [fileSystemRoots] + [fileSystemScheme]
/// let the frontend_server resolve the app package's scheme-based `rootUri`
/// across the live source tree and the generated bazel-out roots — so hot
/// reload sees live edits AND generated parts. Empty for non-codegen apps
/// (then the build package_config's source-tree rootUri suffices).
class NativeCompilerConfig implements CompilerConfig {
  final String patchedSdkRoot;

  /// Directories to add as `--filesystem-root` for [fileSystemScheme].
  final List<String> fileSystemRoots;

  /// The `--filesystem-scheme` paired with [fileSystemRoots] (e.g.
  /// `org-dartlang-app`). Ignored when [fileSystemRoots] is empty.
  final String fileSystemScheme;

  /// Dart environment defines (KEY=VALUE) emitted as `-D` launch flags.
  /// The frontend_server is persistent, so launch-time defines apply to
  /// every subsequent recompile — keeping String.fromEnvironment stable
  /// across hot reload/restart. Sourced from the dev config's dartDefines.
  final List<String> dartDefines;

  NativeCompilerConfig({
    required this.patchedSdkRoot,
    this.fileSystemRoots = const [],
    this.fileSystemScheme = '',
    this.dartDefines = const [],
  });

  @override
  String get targetFlag => 'flutter';

  @override
  String get sdkRoot => patchedSdkRoot;

  @override
  List<String> get extraFlags => [
        '--enable-asserts',
        for (final define in dartDefines) '-D$define',
        for (final root in fileSystemRoots) ...['--filesystem-root', root],
        if (fileSystemRoots.isNotEmpty && fileSystemScheme.isNotEmpty)
          '--filesystem-scheme=$fileSystemScheme',
      ];
}

/// Compiler config for web (DDC) compilation.
///
/// Uses `--target=dartdevc` with the web SDK's libraries spec and DDC outline.
/// Matches Flutter's exact DDC dev mode flags:
/// - `--dartdevc-module-format=ddc` (library bundle format)
/// - `--dartdevc-canary` (enables library bundle features)
/// - `--filesystem-root` + `--filesystem-scheme=org-dartlang-app` (for synthetic entrypoint)
class WebCompilerConfig implements CompilerConfig {
  final WebToolchainPaths webToolchain;

  /// Directories to add as `--filesystem-root` for the `org-dartlang-app` scheme.
  final List<String> fileSystemRoots;

  /// Dart environment defines (KEY=VALUE) emitted as `-D` launch flags.
  /// Same replay semantics as [NativeCompilerConfig.dartDefines].
  final List<String> dartDefines;

  WebCompilerConfig({
    required this.webToolchain,
    this.fileSystemRoots = const [],
    this.dartDefines = const [],
  });

  @override
  String get targetFlag => 'dartdevc';

  @override
  String get sdkRoot => webToolchain.dartSdkRoot;

  @override
  List<String> get extraFlags => [
        '--libraries-spec=${webToolchain.librariesSpec}',
        '--platform=${webToolchain.ddcOutlineDill}',
        '--dartdevc-module-format=ddc',
        '--dartdevc-canary',
        '--experimental-emit-debug-metadata',
        for (final define in dartDefines) '-D$define',
        for (final root in fileSystemRoots) ...['--filesystem-root', root],
        if (fileSystemRoots.isNotEmpty) '--filesystem-scheme=org-dartlang-app',
      ];
}
