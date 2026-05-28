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
class NativeCompilerConfig implements CompilerConfig {
  final String patchedSdkRoot;

  NativeCompilerConfig({required this.patchedSdkRoot});

  @override
  String get targetFlag => 'flutter';

  @override
  String get sdkRoot => patchedSdkRoot;

  @override
  List<String> get extraFlags => const ['--enable-asserts'];
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

  WebCompilerConfig({
    required this.webToolchain,
    this.fileSystemRoots = const [],
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
        for (final root in fileSystemRoots) ...['--filesystem-root', root],
        if (fileSystemRoots.isNotEmpty) '--filesystem-scheme=org-dartlang-app',
      ];
}
