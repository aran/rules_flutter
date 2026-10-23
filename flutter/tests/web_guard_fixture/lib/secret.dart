// A host-side secret for the web-guard hostile fixtures. It is never listed
// in any target's `srcs`: no web compile may read it under any strategy, in
// any directive spelling. The web-guard hostile `flutter_web_bundle` fixtures
// below (manual-tagged; see `web_test.bzl`) each import it in one hostile
// spelling and must fail with `is not a declared input` before compiling.
const String webGuardSecret = 'WEB_GUARD_SECRET_v1';
