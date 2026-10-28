# Feedback report for rules_flutter

Write one when the dev tool cost you more than it should, made you guess, gave
an error that did not say what to do, disagreed with its docs or this skill, or
hung. One report per distinct problem; then go back to the user's task.

## What to collect

- **rules_flutter version.** In the user's workspace,
  `grep -n -A4 'rules_flutter' MODULE.bazel` shows the `bazel_dep` version or
  the override's commit or path. Inside the rules_flutter repository,
  `git rev-parse --short HEAD`.
- **Platform and device.** `uname -sm`, and the `-d` you passed.
- **The exact commands and requests**, copied from your own calls, with the
  token replaced by `<token>`.
- **The output or error**, trimmed to the lines that matter.

## Template

```markdown
### <one line: what went wrong, from the agent's side>

**Trying to:** <what you were doing for the user, in one sentence>

**Ran:**
    <flutter_bazel command line>
    <curl request, token redacted>

**Got:**
    <output or error, trimmed>

**Guessed:** <what you assumed or tried; what turned out to be right, and how
you found out>

**Cost:** <rough waste: tokens or bytes of output, number of calls, minutes>

**Expected:** <what would have saved the cost: a clearer error, a parameter, a
smaller reply, a docs fix>

**Environment:** rules_flutter <version or commit>, <uname -sm>, `-d <device>`
```

## Where it goes

1. **A rules_flutter Claude session on this machine.** List the running agents
   and sessions (in Claude Code, ListAgents), and if one is working in a
   rules_flutter checkout, send it the report (SendMessage). That session owns
   the tool and decides the fix.
2. **Otherwise, a draft GitHub issue** for https://github.com/aran/rules_flutter.
   Show the user the title and body. File it only if they say so, and with
   the text they approved (for example
   `gh issue create -R aran/rules_flutter --title … --body-file …`). An issue
   is public text under the user's name; never post one on your own.

Before sending, take out anything private: tokens, paths that name people or
clients, and the user's code beyond the lines needed to reproduce.
