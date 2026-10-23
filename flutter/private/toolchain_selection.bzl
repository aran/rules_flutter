"""Picks one Flutter SDK version per toolchain name from the versions modules request."""

def _parse_identifier_list(text, what, version):
    """Validates dot-separated prerelease/build identifiers."""
    identifiers = []
    for identifier in text.split("."):
        if not identifier:
            fail("Invalid Flutter SDK version \"{v}\": the {what} part is empty.".format(v = version, what = what))
        for c in identifier.elems():
            if not (c.isalnum() or c == "-"):
                fail("Invalid Flutter SDK version \"{v}\": bad character {c} in the {what} part.".format(v = version, c = repr(c), what = what))
        if identifier.isdigit():
            identifiers.append((0, int(identifier), ""))
        else:
            identifiers.append((1, 0, identifier))
    return identifiers

def _parse_version(v):
    """Parses a Flutter SDK version into a comparable key.

    Accepts a numeric dotted core plus an optional semver-style `-<prerelease>`
    and/or `+<build>` suffix, so enterprise rebuilds (`3.44.1-acme`), Flutter
    prereleases (`3.45.0-0.1.pre`) and build-stamped versions (`3.44.1+corp.7`)
    all compare. Ordering is numeric on the core first; a prerelease sorts
    below its release; build metadata never decides. Anything else fails with
    the offending version named.

    Args:
      v: The version string.

    Returns:
      A `(core, release_rank, prerelease)` tuple of comparables.
    """
    build_split = v.split("+")
    if len(build_split) > 2:
        fail("Invalid Flutter SDK version \"{v}\": at most one +<build> suffix is allowed.".format(v = v))
    without_build = build_split[0]
    if len(build_split) == 2:
        _parse_identifier_list(build_split[1], "build", v)
    dash = without_build.find("-")
    if dash == -1:
        core_text = without_build
        prerelease = []
        release_rank = 1
    else:
        core_text = without_build[:dash]
        prerelease_text = without_build[dash + 1:]
        prerelease = _parse_identifier_list(prerelease_text, "prerelease", v)
        release_rank = 0
    core = []
    for part in core_text.split("."):
        if not part or not part.isdigit():
            fail("Invalid Flutter SDK version \"{v}\": expected numeric components separated by dots (e.g. '3.44.1'), optionally followed by -<prerelease> and/or +<build>.".format(v = v))
        core.append(int(part))
    if not core:
        fail("Invalid Flutter SDK version \"{v}\": the numeric core is empty.".format(v = v))
    return (core, release_rank, prerelease)

def _request_module(request):
    """The module name a toolchain request came from, or "" when unrecorded."""
    return getattr(request, "module", "")

def _describe_request(request):
    """`version` plus its module, for tie-failure messages."""
    module = _request_module(request)
    if module:
        return "{v} from module {m}".format(v = request.version, m = module)
    return request.version

def _fail_equal_rank(name, first, second, both_root):
    """Fails on two equally-ranked but differently-spelled version requests.

    Build metadata never decides ordering, so `3.44.1` and `3.44.1+corp.7`
    compare equal — yet they name different releases. Picking by module order
    would resolve different bytes depending on which module Bazel visits
    first, so the tie fails naming both requests instead.

    Args:
      name: The toolchain name.
      first: The first tied request struct.
      second: The second tied request struct.
      both_root: Whether both requests came from the root module's own tags.
    """
    if both_root:
        fail("Flutter toolchain {name} has two equally-ranked version requests that differ only where ordering never decides (build metadata): {first} and {second}. Keep exactly one flutter.toolchain(flutter_version = ...) tag for {name} in the root module.".format(
            name = name,
            first = _describe_request(first),
            second = _describe_request(second),
        ))
    fail("Flutter toolchain {name} has two equally-ranked version requests that differ only where ordering never decides (build metadata): {first} and {second}. Pin one with flutter.toolchain(flutter_version = ...) in the root module.".format(
        name = name,
        first = _describe_request(first),
        second = _describe_request(second),
    ))

def _highest_request(requests, keys, name, both_root):
    """Returns the highest-versioned request, failing on undecidable ties.

    Args:
      requests: Non-empty list of request structs with a `version` field.
      keys: `version` string to `_parse_version` key.
      name: The toolchain name, used in tie failures.
      both_root: Whether the requests all came from the root module's tags.
    """
    selected = requests[0]
    for request in requests[1:]:
        if keys[request.version] > keys[selected.version]:
            selected = request
        elif keys[request.version] == keys[selected.version] and request.version != selected.version:
            _fail_equal_rank(name, selected, request, both_root)
    return selected

def _newer_dep_note(name, selected, dep_requests, keys):
    """Names the newest dependency request newer than the root's pin, if any."""
    newer_dep_versions = [
        r.version
        for r in dep_requests
        if keys[r.version] > keys[selected]
    ]
    if not newer_dep_versions:
        return None
    newest_dep = newer_dep_versions[0]
    for v in newer_dep_versions[1:]:
        if keys[v] > keys[newest_dep]:
            newest_dep = v
    return "Flutter toolchain {} uses {} requested by the root module, which is older than {} requested by a dependency".format(
        name,
        selected,
        newest_dep,
    )

def select_toolchain_version(name, requests):
    """Selects the Flutter SDK version for one toolchain name.

    The root module's request wins when it makes one: a root pin is selected
    even when a dependency requests a newer SDK. With no root request, the
    highest requested version wins, as before.

    When several root tags request the same name, the highest of the root's own
    requests is used.

    Requests that compare equally but spell different versions (they differ
    only in build metadata, which never decides) fail naming both requests:
    the choice would otherwise depend on module order. Either spell the same
    version everywhere or pin one in the root module.

    Args:
      name: The toolchain name, used in the note.
      requests: Non-empty list of `struct(version, is_root)`, one per tag.
        A `module` field naming the requesting module is used in tie
        failures when present.

    Returns:
      `struct(version, note)`. `note` is a message for the user when the root
      module pinned a version older than a dependency's request (the root still
      wins), and None otherwise.
    """
    root_requests = [r for r in requests if r.is_root]
    dep_requests = [r for r in requests if not r.is_root]

    # Every requested version parses up front, so a malformed string fails
    # here naming the version — even a lone root pin that no comparison
    # would otherwise touch.
    keys = {r.version: _parse_version(r.version) for r in requests}

    if root_requests:
        selected = _highest_request(root_requests, keys, name, True).version

        # The root pin wins even when it is older than a dependency's request;
        # surface that as an informational note naming both versions.
        return struct(version = selected, note = _newer_dep_note(name, selected, dep_requests, keys))

    # No root request: highest requested version wins.
    selected = _highest_request(requests, keys, name, False)
    return struct(version = selected.version, note = None)

def select_toolchain_source(name, requests):
    """Selects the source (local SDK or downloaded version) for one toolchain name.

    The root module's choice wins exactly as it does for versions: a root
    `local_path` replaces every non-root version request for the name, and a
    root version pin goes through `select_toolchain_version`. "Mixed" is an
    error only when the root module itself sets both `local_path` and
    `flutter_version` for the name. A non-root `local_path` is always an
    error: dependencies must request downloadable versions.

    Args:
      name: The toolchain name, used in notes and errors.
      requests: Non-empty list of `struct(version, local_path, is_root)`, one
        per tag. `version` is `""` for local requests, `local_path` is `""`
        for download requests. A request setting both counts as both, so it
        trips the root-mix error below. A `module` field naming the
        requesting module is forwarded to version selection for tie failures
        when present.

    Returns:
      `struct(local_path, version, note)`: exactly one of `local_path` and
      `version` is set. `note` names the overridden non-root requests, if
      any, and None otherwise.
    """
    for r in requests:
        if r.local_path and not r.is_root:
            fail("Only the root module may source a Flutter toolchain from a local SDK (local_path); dependencies must request downloadable versions.")
    root_locals = [r for r in requests if r.is_root and r.local_path]
    root_downloads = [r for r in requests if r.is_root and r.version]
    dep_downloads = [r for r in requests if not r.is_root and not r.local_path]
    if root_locals and root_downloads:
        fail("Flutter toolchain {} mixes a local SDK (local_path) with a downloaded version; use one or the other.".format(name))
    if root_locals:
        local_paths = {r.local_path: True for r in root_locals}.keys()
        if len(local_paths) > 1:
            fail("Flutter toolchain {} has multiple local SDKs {}; keep exactly one local_path.".format(name, list(local_paths)))
        local_path = root_locals[0].local_path
        note = None
        if dep_downloads:
            note = "Flutter toolchain {} uses local SDK {} requested by the root module, ignoring {} version request(s) from dependencies".format(
                name,
                local_path,
                len(dep_downloads),
            )
        return struct(local_path = local_path, version = "", note = note)
    selection = select_toolchain_version(
        name,
        [struct(version = r.version, is_root = r.is_root, module = _request_module(r)) for r in requests],
    )
    return struct(local_path = "", version = selection.version, note = selection.note)
