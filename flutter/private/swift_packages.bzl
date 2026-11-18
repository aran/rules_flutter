"""The Swift packages Apple plugins depend on, which the root module declares.

A pub plugin's `Package.swift` can depend on other Swift packages:

    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),

The root module owns those packages, as it owns its Maven artifacts: it lists
them in a `Package.swift` of its own, declares them with
rules_swift_package_manager's `swift_deps.from_package`, which makes one
`swiftpkg_<identity>` repository per pin of its `Package.resolved`, and hands
each package a plugin names to the pub extension with
`inject_repo(flutter_pub, "swiftpkg_<identity>")`. So the app's own Swift code
and the plugins share one copy of each package, and every setting
rules_swift_package_manager offers applies to both.

rules_flutter declares none of those repositories. A plugin's dependency on a
product of such a package (`.product(name: "FirebaseCore", package:
"firebase-ios-sdk")`) is the product's target in the repository of that name
(`swift_product_label`), which `swift_package_product.bzl` checks the root
injected. It reads the root's `Package.resolved`, named by
`flutter_pub.from_lock(swift_package_resolved = ...)`, to check each pin
against what the plugins' manifests require (`requirement_violation`).

`bazel run @<hub>//swift:packages` prints what the root's `Package.swift` and
`MODULE.bazel` need for the hub's plugins (`flutter_swift_packages_report.bzl`).
"""

visibility("//flutter/...")

# The repository that lists the root's pins, for the plugins' Apple
# repositories.
SWIFT_PACKAGES_REPO = "flutter_pub_swift_packages"
SWIFT_PACKAGES_FILE = "swift_packages.json"

def swift_package_repo(identity):
    """The repository rules_swift_package_manager declares for the package of `identity`.

    Its `bazel_repo_names.from_identity`: the root's repositories are named
    so, and a plugin's repository names them as the root injects them.
    """
    return "swiftpkg_" + identity.replace("-", "_")

def swift_product_label(identity, product):
    """The label of a package's library product, as the root's repository names it."""
    return "@{}//:{}".format(swift_package_repo(identity), product)

def parse_package_resolved(content, path):
    """The pins of a `Package.resolved` (version 1, 2 or 3).

    Args:
        content: The file's text.
        path: Its path, for messages.

    Returns:
        A list of structs with `identity`, `location`, `revision`, `branch`
        and `version` ("" where the pin has none).
    """
    data = json.decode(content)
    version = data.get("version")
    if version == 1:
        # Version 1 nests the pins under `object` and names fields otherwise.
        pins = []
        for pin in data.get("object", {}).get("pins", []):
            location = pin.get("repositoryURL", "")
            identity = location.rstrip("/").rsplit("/", 1)[-1].lower()
            if identity.endswith(".git"):
                identity = identity[:-len(".git")]
            state = pin.get("state", {})
            pins.append(struct(
                identity = identity,
                location = location,
                revision = state.get("revision") or "",
                branch = state.get("branch") or "",
                version = state.get("version") or "",
            ))
        return pins
    if version not in (2, 3):
        fail("{}: Package.resolved version {} is not one rules_flutter reads (1, 2 or 3).".format(path, version))
    pins = []
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        pins.append(struct(
            identity = pin.get("identity", ""),
            location = pin.get("location", ""),
            revision = state.get("revision") or "",
            branch = state.get("branch") or "",
            version = state.get("version") or "",
        ))
    return pins

def merge_pins(resolved):
    """The pins of several `Package.resolved` files, which must agree.

    Args:
        resolved: A list of `(path, pins)`, `pins` as `parse_package_resolved` returns them.

    Returns:
        A dict of identity to pin. Fails when two files pin a package
        differently.
    """
    merged = {}
    where = {}
    for path, pins in resolved:
        for pin in pins:
            other = merged.get(pin.identity)
            if other and (other.revision != pin.revision or other.version != pin.version):
                fail((
                    "The Swift package `{id}` is pinned differently by {a} ({ra}) and {b} ({rb}). " +
                    "The root module declares one version of each package: name its " +
                    "`Package.resolved` in every `swift_package_resolved`."
                ).format(id = pin.identity, a = where[pin.identity], ra = other.version or other.revision, b = path, rb = pin.version or pin.revision))
            merged[pin.identity] = pin
            where[pin.identity] = path
    return merged

def _version_parts(version):
    """`version` as `(major, minor, patch, prerelease)` for ordering, or None.

    Semantic versioning's precedence, as SwiftPM orders versions: build
    metadata is ignored, and a prerelease is below its release.
    """
    core = version.split("+", 1)[0]
    prerelease = ""
    if "-" in core:
        core, prerelease = core.split("-", 1)
    numbers = core.split(".")
    if len(numbers) != 3 or [n for n in numbers if not n.isdigit()]:
        return None
    identifiers = []
    for part in prerelease.split(".") if prerelease else []:
        # Numeric identifiers sort below alphanumeric ones, and by value.
        identifiers.append((0, int(part), "") if part.isdigit() else (1, 0, part))
    return ([int(n) for n in numbers], identifiers)

def compare_versions(a, b):
    """How two semantic versions order, as SwiftPM orders them.

    Args:
        a: A version.
        b: Another.

    Returns:
        -1, 0 or 1 as `a` is below, equal to or above `b`.
    """
    pa, pb = _version_parts(a), _version_parts(b)
    if pa == None or pb == None:
        fail("not a semantic version: {}".format(a if pa == None else b))
    if pa[0] != pb[0]:
        return -1 if pa[0] < pb[0] else 1
    ra, rb = pa[1], pb[1]
    if ra == rb:
        return 0
    if not ra or not rb:
        # A release is above its prereleases.
        return 1 if not ra else -1
    for i in range(min(len(ra), len(rb))):
        if ra[i] != rb[i]:
            return -1 if ra[i] < rb[i] else 1
    return -1 if len(ra) < len(rb) else 1

def requirement_text(requirement):
    """A `Package.swift` dependency requirement, as a person reads it.

    Args:
        requirement: The requirement, as `dump-package` writes it.

    Returns:
        "exact 13.1.1", "1.2.0 to below 2.0.0", "branch main" or "revision <sha>".
    """
    if "exact" in requirement:
        return "exact " + requirement["exact"][0]
    if "range" in requirement:
        bounds = requirement["range"][0]
        return "{} to below {}".format(bounds["lowerBound"], bounds["upperBound"])
    if "branch" in requirement:
        return "branch " + requirement["branch"][0]
    if "revision" in requirement:
        return "revision " + requirement["revision"][0]
    return json.encode(requirement)

def requirement_swift(requirement):
    """A dependency requirement as `Package.swift` writes it after the URL.

    Args:
        requirement: The requirement, as `dump-package` writes it.

    Returns:
        `exact: "13.1.1"`, `from: "1.2.0"`, `.upToNextMinor(from: "1.2.0")`,
        `"1.2.0"..<"1.2.5"`, `branch: "main"` or `revision: "<sha>"`.
    """
    if "exact" in requirement:
        return 'exact: "{}"'.format(requirement["exact"][0])
    if "range" in requirement:
        bounds = requirement["range"][0]
        lower, upper = bounds["lowerBound"], bounds["upperBound"]
        parts = _version_parts(lower)
        if parts and not parts[1]:
            major, minor, _ = parts[0]
            if upper == "{}.0.0".format(major + 1):
                return 'from: "{}"'.format(lower)
            if upper == "{}.{}.0".format(major, minor + 1):
                return '.upToNextMinor(from: "{}")'.format(lower)
        return '"{}"..<"{}"'.format(lower, upper)
    if "branch" in requirement:
        return 'branch: "{}"'.format(requirement["branch"][0])
    if "revision" in requirement:
        return 'revision: "{}"'.format(requirement["revision"][0])
    return json.encode(requirement)

def pin_text(pin):
    """What a `Package.resolved` pin records, as a person reads it.

    Args:
        pin: A pin of `parse_package_resolved`.

    Returns:
        Its version, else its branch and revision, else its revision.
    """
    if pin.version:
        return pin.version
    if pin.branch:
        return "branch {} ({})".format(pin.branch, pin.revision)
    return "revision " + pin.revision

def requirement_violation(requirement, pin):
    """Why `pin` does not meet a manifest's `requirement`, or "" when it does.

    Args:
        requirement: A dependency's `requirement` in `dump-package`'s output:
            `{"exact": [v]}`, `{"range": [{"lowerBound", "upperBound"}]}`,
            `{"branch": [b]}` or `{"revision": [r]}`.
        pin: A pin of `parse_package_resolved`.

    Returns:
        A clause naming what is pinned, or "".
    """
    pinned = "pins " + pin_text(pin)
    if "exact" in requirement or "range" in requirement:
        if not pin.version or _version_parts(pin.version) == None:
            return pinned
        if "exact" in requirement:
            return "" if compare_versions(pin.version, requirement["exact"][0]) == 0 else pinned
        bounds = requirement["range"][0]
        inside = (compare_versions(pin.version, bounds["lowerBound"]) >= 0 and
                  compare_versions(pin.version, bounds["upperBound"]) < 0)
        return "" if inside else pinned
    if "branch" in requirement:
        return "" if pin.branch == requirement["branch"][0] else pinned
    if "revision" in requirement:
        return "" if pin.revision == requirement["revision"][0] else pinned
    return ""

def _flutter_swift_packages_impl(ctx):
    ctx.file(SWIFT_PACKAGES_FILE, json.encode({
        "pins": json.decode(ctx.attr.pins),
        "resolved": ctx.attr.resolved,
    }))
    ctx.file("BUILD.bazel", 'exports_files(["{}"])\n'.format(SWIFT_PACKAGES_FILE))
    return ctx.repo_metadata(reproducible = True)

flutter_swift_packages = repository_rule(
    implementation = _flutter_swift_packages_impl,
    attrs = {
        "pins": attr.string(doc = "The root's pins, as JSON: identity to `parse_package_resolved`'s fields."),
        "resolved": attr.string_list(doc = "The `Package.resolved` files read, for messages."),
    },
    doc = "Lists the root's Swift package pins. See the module docstring.",
)

def pins_from_listing(entries):
    """The pins `flutter_swift_packages` lists, as `parse_package_resolved` structs by identity."""
    return {identity: struct(identity = identity, **fields) for identity, fields in entries.items()}

def declare_swift_packages(module_ctx, resolved_labels):
    """Declares the listing of the root's pins, read from the tags' `Package.resolved` files.

    Args:
        module_ctx: The pub extension's `module_ctx`.
        resolved_labels: The `swift_package_resolved` labels of the tags.
    """
    resolved = []
    for label in resolved_labels:
        resolved.append((str(label), parse_package_resolved(module_ctx.read(label), str(label))))
    pins = merge_pins(resolved)
    flutter_swift_packages(
        name = SWIFT_PACKAGES_REPO,
        pins = json.encode({
            identity: {
                "branch": pin.branch,
                "location": pin.location,
                "revision": pin.revision,
                "version": pin.version,
            }
            for identity, pin in pins.items()
        }),
        resolved = [str(label) for label in resolved_labels],
    )
