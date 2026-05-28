## Verification policy (MANDATORY)

**Never claim work is done without full e2e verification.** `bazel test` / `build_test` passing is necessary but NOT sufficient. You must:

1. Run `bazel test //...` in root + all affected e2e workspaces
2. Run `npx playwright test` in every e2e workspace that has Playwright tests (see docs/TESTING.md § 5)
3. For web changes: inspect actual output files (`cat bazel-bin/*/index.html`, etc.) to confirm content is correct
4. For macOS changes: run the manual runtime test (`bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone`)
5. For Linux/Windows changes: run VM-based visual verification if possible
6. For dev_tool reload-path changes (`tools/dev_tool/lib/run_command.dart`, `vm_service_client.dart`, `hot_reload/**`, `session.dart`): manually verify **both** hot reload and hot restart against `e2e/macos_example` via `flutter_bazel` — see docs/TESTING.md "Hot reload / hot restart (manual)". 

The bar is **"I have seen the UI render correctly"** — not "the build succeeded."

Consult `docs/TESTING.md` § "Quick reference: what to test when" for which verification steps apply. Follow it literally.

## Testing guide

See [docs/TESTING.md](docs/TESTING.md) for the complete testing procedures.

## Key rules

- NEVER run `bazel clean` — whenever you think bazel is the issue, it's always some error on your part
- NEVER ignore pre-existing failures — investigate and fix them
- Prefer Dart over shell scripts for tooling
- Follow the two-tier API pattern for all platform rules (Tier 1 = convenience macro, Tier 2 = composable rules)
