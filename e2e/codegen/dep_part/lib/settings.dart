/// A dependency package whose own `lib/` mixes a hand-written source with a
/// generated `part` (settings.g.dart, from tools/settings_generator.dart).
///
/// This exercises per-DEPENDENCY source assembly + the dev tool resolving a
/// generated part that belongs to a package OTHER than the app — the codegen
/// e2e otherwise keeps all generated files in the app's own package.
part 'settings.g.dart';

class Settings {
  final String mode;

  const Settings(this.mode);
}
