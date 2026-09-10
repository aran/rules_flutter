// Entrypoint for the two dual-hub binaries.
//
// A binary rather than a bare library because the duplicate-record check lives
// in `collect_packages`, which a consumer emitting a `package_config.json`
// calls — `dart_library` accumulates records into depsets and never dedups, so
// a library alone would never reach the guard this workspace exists to reach.
void main() {
  print('dual_hub');
}
