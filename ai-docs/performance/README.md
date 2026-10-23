# Performance review (started 2026-10-14)

A review of rules_flutter for large monorepos: analysis time, how many actions
each target creates, what those actions take as inputs, and what a one-line edit
re-runs. It runs alongside rules_dart's review (`ai-docs/performance/` on
`Mivr/rules_dart` `main`), which a separate agent drives.

Read in this order:

1. [`plan.md`](plan.md): every item, who owns it, and its status.
2. [`decisions.md`](decisions.md): who decided what, and why.
3. [`findings.md`](findings.md): measurements and facts the plan rests on.
4. [`asks-for-rules-dart.md`](asks-for-rules-dart.md): what rules_flutter
   needs from rules_dart, so neither side builds the same thing twice.

## Split with rules_dart

rules_dart's agent owns the Dart-side mechanisms: modular kernel compilation,
analyzer summaries, reproducible compile outputs, SDK file subsets, and
dropping `bazel_lib`. This review owns everything Flutter-specific, and the
work of adopting those mechanisms in Flutter's rules. When rules_flutter needs
something from rules_dart, it goes in `asks-for-rules-dart.md`. Nobody edits
the other rule set.

## Process every change follows

The same process as rules_dart's:

1. A Haiku agent implements the change in its own git worktree, branched from
   `main`.
2. The reviewing agent reads the diff, then runs:
   - the root `bazel test //...`;
   - the Linux e2e workspaces the change touches;
   - the benchmark A/B against current `main`;
   - a lockfile check when a module-extension `.bzl` file changed.
3. Only then does it land, with a `Changelog:` trailer per `AGENTS.md`.

The review machine is Linux x64. macOS, iOS and Android paths are verified only
by CI.
