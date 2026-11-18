"""The targets an aspect follows from the rule it visits."""

visibility("//flutter/...")

def rule_attr_targets(rule_attr, names):
    """The Targets a rule's attributes hold.

    An aspect visits rules it does not own, and an attribute named like a list
    of dependencies may hold a single label: `resolved_package`'s `deps` holds
    the one target a resolve-mapped pub package stands for. An attribute the
    rule lacks, or one that holds no label, contributes nothing.

    Args:
      rule_attr: `ctx.rule.attr` of the aspect's context.
      names: The attribute names to read.

    Returns:
      A list of Targets, in attribute order.
    """
    targets = []
    for name in names:
        value = getattr(rule_attr, name, None)
        for item in value if type(value) == "list" else [value]:
            if type(item) == "Target":
                targets.append(item)
    return targets
