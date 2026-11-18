"""The `include_tags` and `exclude_tags` attributes of the test rules."""

visibility("//flutter/...")

def tag_selectors(ctx, attr_name, rule_kind):
    """The entries of the `include_tags` or `exclude_tags` attribute.

    Each entry is one `package:test` selector, as one `--tags` value is. An
    empty entry selects nothing, a comma is how `--tags` separates selectors
    (and rules_dart's `dart_test`, which passes each entry as its own `--tags`,
    refuses one), and the runner joins entries with newlines: each is a mistake
    in the BUILD file. Whether an entry is a selector `package:test` can parse
    is only known to the runner, which says so when the test runs.

    Args:
        ctx: The rule context.
        attr_name: `include_tags` or `exclude_tags`.
        rule_kind: How the failure names the rule.

    Returns:
        The attribute's entries.
    """
    entries = getattr(ctx.attr, attr_name)
    for entry in entries:
        if not entry.strip() or "\n" in entry or "," in entry:
            fail(("{kind} {label}: {attr} entry {entry} is empty, spans lines or holds a comma: " +
                  "give each selector its own entry").format(
                kind = rule_kind,
                label = ctx.label,
                attr = attr_name,
                entry = repr(entry),
            ))
    return entries
