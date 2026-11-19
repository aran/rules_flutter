"""What flutter_tools reports of a flutter/flutter checkout, from its git history.

flutter_tools (`packages/flutter_tools/lib/src/version.dart`) tells a
checkout's version, channel and repository from git: the version from the tags
at or before the commit, the channel from the branch, the repository from the
branch's upstream remote or `origin`. These are its computations, step for
step, so that a program built from a checkout is told what `flutter run` in
that checkout would tell it.
"""

visibility("//flutter/...")

# `kUnknownFrameworkVersion`: what flutter_tools reports when the tags say nothing.
UNKNOWN_FRAMEWORK_VERSION = "0.0.0-unknown"

# `kOfficialChannels` and `kObsoleteBranches`: the branches flutter_tools
# reports as the channel. Any other is `kUserBranch`.
_CHANNELS = ["master", "main", "beta", "stable", "dev"]
USER_BRANCH = "[user-branch]"

def _digits(text, start):
    """The end of the run of ASCII digits at `start`, or `start` when there is none."""
    end = start
    for i in range(start, len(text)):
        if not text[i].isdigit():
            break
        end = i + 1
    return end

def _number(text, start):
    """The digits at `start` and where they end, or None."""
    end = _digits(text, start)
    return (text[start:end], end) if end > start else None

def _dev_suffix(text, start):
    """Where `-<n>.<m>.pre` at `start` ends, with n and m, or None."""
    if not text[start:].startswith("-"):
        return None
    n = _number(text, start + 1)
    if not n or not text[n[1]:].startswith("."):
        return None
    m = _number(text, n[1] + 1)
    if not m or not text[m[1]:].startswith(".pre"):
        return None
    return struct(end = m[1] + len(".pre"), version = int(n[0]), patch = int(m[0]))

def parse_git_tag_version(version):
    """`GitTagVersion.parseVersion`: a tag, or a tag and the commits past it.

    The version is `x.y.z`, optionally `-n.m.pre`, optionally `-<commits>` or
    `.<commits>`, optionally `-g<hash>` after the commits:
    `^(\\d+)\\.(\\d+)\\.(\\d+)(-\\d+\\.\\d+\\.pre)?(?:[-\\.](\\d+)(?:-g([a-f0-9]+))?)?$`.

    Args:
        version: The text, such as `3.50.0`, `3.51.0-0.1.pre` or `3.50.0-12`.

    Returns:
        A struct (`x`, `y`, `z`, `dev_version`, `dev_patch`, `commits`,
        `hash`, `git_tag`), or None when the text is not a version.
    """
    text = version.strip()
    parts = []
    at = 0
    for i in range(3):
        if i and not text[at:].startswith("."):
            return None
        number = _number(text, at + 1 if i else 0)
        if not number:
            return None
        parts.append(int(number[0]))
        at = number[1]
    tag_end = at
    dev = _dev_suffix(text, at)
    if dev:
        at = dev.end
    commits = 0
    commit_hash = ""
    if at < len(text) and text[at] in "-.":
        number = _number(text, at + 1)
        if not number:
            return None
        commits = int(number[0])
        at = number[1]
        if text[at:].startswith("-g"):
            hex_end = at + 2
            for i in range(at + 2, len(text)):
                if text[i] not in "0123456789abcdef":
                    break
                hex_end = i + 1
            if hex_end > at + 2:
                commit_hash = text[at + 2:hex_end]
                at = hex_end
    if at != len(text):
        return None
    return struct(
        x = parts[0],
        y = parts[1],
        z = parts[2],
        dev_version = dev.version if dev else None,
        dev_patch = dev.patch if dev else None,
        commits = commits,
        hash = commit_hash,
        git_tag = text[:dev.end if dev else tag_end],
    )

def framework_version_for(tag_version, revision):
    """`GitTagVersion.frameworkVersionFor`: the version flutter_tools reports at `revision`.

    Args:
        tag_version: What `parse_git_tag_version` made of the tags, or None.
        revision: The checkout's commit.

    Returns:
        The tag itself at a tag; past one, the next version's pre-release
        with the commits since (`3.50.1-0.0.pre-12`); `0.0.0-unknown` when
        the tags say nothing.
    """
    if tag_version == None or not revision.startswith(tag_version.hash):
        return UNKNOWN_FRAMEWORK_VERSION
    if tag_version.commits == 0:
        return tag_version.git_tag
    if tag_version.dev_patch != None and tag_version.dev_version != None:
        # The next tag to hold the commit is the next candidate branch's.
        return "{}.{}.0-{}.0.pre-{}".format(tag_version.x, tag_version.y, tag_version.dev_version + 1, tag_version.commits)
    return "{}.{}.{}-0.0.pre-{}".format(tag_version.x, tag_version.y, tag_version.z + 1, tag_version.commits)

def _is_stable_tag(tag):
    parsed = parse_git_tag_version(tag)
    return parsed != None and parsed.commits == 0 and parsed.dev_version == None and parsed.git_tag == tag

def _is_dev_tag(tag):
    parsed = parse_git_tag_version(tag)
    return parsed != None and parsed.commits == 0 and parsed.dev_version != None and parsed.git_tag == tag

def checkout_framework_version(git, revision):
    """`GitTagVersion.determine` and `frameworkVersionFor`: the checkout's version at `revision`.

    Args:
        git: A function from git's arguments to a struct of `ok` and `stdout`,
            run in the checkout.
        revision: The checkout's commit, `git log -n 1 --pretty=format:%H`.

    Returns:
        The version flutter_tools reports.
    """

    # The tags at the commit, the most recent first: a release tag, then a
    # candidate branch's.
    tags = [t.strip() for t in reversed(git(["tag", "--points-at", revision]).stdout.strip().split("\n"))]
    for match in [_is_stable_tag, _is_dev_tag]:
        for tag in tags:
            if match(tag):
                return framework_version_for(parse_git_tag_version(tag), revision)

    # Else the newest tag, and the commits since it and the commit share.
    latest = git(["for-each-ref", "--sort=-v:refname", "--count=1", "--format=%(refname:short)", "refs/tags/[0-9]*.*.*"]).stdout.strip()
    ancestor = git(["merge-base", revision, latest]).stdout.strip()
    count = git(["rev-list", "--count", "{}..{}".format(ancestor, revision)]).stdout.strip()
    return framework_version_for(parse_git_tag_version("{}-{}".format(latest, count)), revision)

def checkout_channel(git):
    """`FlutterVersion.channel`: the checkout's branch when it is a channel, else `[user-branch]`.

    Args:
        git: As `checkout_framework_version` takes it.

    Returns:
        The channel flutter_tools reports.
    """
    branch = git(["symbolic-ref", "--short", "HEAD"]).stdout.strip()
    return branch if branch in _CHANNELS else USER_BRANCH

def checkout_repository_url(git):
    """`FlutterVersion.repositoryUrl`: the remote the branch tracks, else `origin`'s.

    Args:
        git: As `checkout_framework_version` takes it.

    Returns:
        The remote's URL, or None when neither has one.
    """
    url = None
    tracking = git(["rev-parse", "--abbrev-ref", "--symbolic", "@{upstream}"])
    if tracking.ok:
        upstream = tracking.stdout.strip()
        if "/" in upstream:
            remote = git(["ls-remote", "--get-url", upstream[:upstream.index("/")]])
            if remote.ok:
                url = remote.stdout.strip()
    if not url:
        origin = git(["remote", "get-url", "origin"])
        if origin.ok:
            url = origin.stdout.strip()
    return url
