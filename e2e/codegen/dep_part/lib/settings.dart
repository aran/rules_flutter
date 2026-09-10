/// A dependency package whose own `lib/` mixes a hand-written source with a
/// generated `part` (settings.g.dart, from tools/settings_generator.dart).
///
/// This exercises per-DEPENDENCY source assembly + the dev tool resolving a
/// generated part that belongs to a package OTHER than the app — the codegen
/// e2e otherwise keeps all generated files in the app's own package.
library;

part 'settings.g.dart';

/// A model in a dependency package whose generated `part` must resolve
/// against that package rather than the app's.
class Settings {
  /// Creates settings with the given [mode].
  const Settings(this.mode);

  /// The configured mode, echoed by the generated `part`.
  final String mode;
}
