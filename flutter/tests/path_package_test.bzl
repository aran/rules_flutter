"""Tests for `path:` dependency spokes: scoped linking and lock-root resolution.

A path package is symlinked into its spoke, so the generator reads it in
place. The link plan parses the package's own `pubspec.yaml` from the spoke
and links only what the spoke generator reads or exposes:

* `lib/`, the pubspec, hook scripts, declared assets/fonts/shaders (plus
  each shader's own directory), and the plugin's platform directories —
  mirrored one file at a time into real repository directories, so the
  generator's `ctx.file` writes can never land in the user tree through a
  symlinked directory.
* `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files,
  and user BUILD files stay unlinked — skipped subtrees are not even
  watched, so machine-local output cannot affect the fetch.
* Source links replicate without descending and fail closed, naming the
  package and the link, when they resolve to the package or an ancestor.
* A `path:` entry resolves against the lock file's own directory, and only
  the root module's workspace is reachable from a spoke.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "ancestor_link_refusal",
    "is_path_spoke_skipped_dir",
    "link_path_package",
    "path_spoke_is_ancestor_cycle",
    "path_spoke_platform_dirs",
    "scoped_shader_includes_block",
)
load("//flutter/private:flutter_pub_path.bzl", "foreign_lock_path_error", "workspace_relative_lock_path")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_plugin_block")

def _tree_node(tree, rel):
    """The node at `rel` ("a/b") in a nested-dict tree, files are None or str."""
    node = tree
    if rel == "":
        return node
    for seg in rel.split("/"):
        if type(node) != "dict" or seg not in node:
            return "missing"
        node = node[seg]
    return node

def _make_mock_link_ctx(tree, path_value = "platform_assets", package_name = "platform_assets"):
    """Fake repository_ctx for `link_path_package` over an in-memory tree.

    Tree leaves: None is an empty file, a string is a file with that
    content, a dict is a real directory, and `struct(symlink_to = ...)` is
    a symlink node resolving to the given real path.

    Args:
        tree: Nested dicts relative to a fake `/workspace` root.
        path_value: Value for `ctx.attr.path`.
        package_name: Value for `ctx.attr.package_name`.

    Returns:
        struct(ctx, watched, linked): the fake ctx, the watched path
        strings, and the symlinked (link name, resolved target) pairs.
    """
    watched = []
    linked = []
    linked_names = {}

    def _make_path(rel):
        full = "/workspace/" + rel if rel else "/workspace"
        node = _tree_node(tree, rel)
        if type(node) == "struct":
            real = node.symlink_to
            exists = True
            is_dir = False
            content = ""
            children = []
        else:
            real = full
            exists = node != "missing"
            is_dir = type(node) == "dict"
            content = node if type(node) == "string" else ""
            children = sorted(node.keys()) if is_dir else []

        def _readdir():
            return [_make_path(rel + "/" + c if rel else c) for c in children]

        def _get_child(*segments):
            child_rel = rel
            for seg in segments:
                child_rel = child_rel + "/" + seg if child_rel else seg
            return _make_path(child_rel)

        return struct(
            path = full,
            basename = rel.split("/")[-1] if rel else "",
            exists = exists,
            is_dir = is_dir,
            realpath = real,
            content = content,
            readdir = _readdir,
            get_child = _get_child,
        )

    def _watch(path_obj):
        watched.append(path_obj.path)

    def _symlink(target, link_name):
        linked.append(struct(name = link_name, target = target.realpath))
        linked_names[link_name] = target.content

    def _repo_path(rel):
        return struct(exists = rel in linked_names, link_name = rel)

    def _read(path_obj):
        return linked_names.get(path_obj.link_name, "")

    return struct(
        ctx = struct(
            attr = struct(path = path_value, package_name = package_name),
            workspace_root = _make_path(""),
            watch = _watch,
            symlink = _symlink,
            path = _repo_path,
            read = _read,
        ),
        watched = watched,
        linked = linked,
    )

_SCOPED_PUBSPEC = """name: mypkg
flutter:
  assets:
    - assets/any.txt
    - assets/dir/
"""

# A package exercising every scoping rule: declared and undeclared assets, a
# nested user BUILD file, an example app with its own build output and
# `.plugin_symlinks` cycle, tool state, a dot-directory, an (undeclared,
# non-plugin) android tree, and an undeclared top-level file.
_SCOPED_CONTENTS = {
    "pubspec.yaml": _SCOPED_PUBSPEC,
    "lib": {
        "mypkg.dart": None,
    },
    "assets": {
        "any.txt": None,
        "other.txt": None,
        "dir": {
            "one.txt": None,
            "BUILD.bazel": None,
        },
        "icons": {},
    },
    "example": {
        "main.dart": None,
        "build": {
            "stale.txt": None,
        },
        ".plugin_symlinks": {
            "mypkg": struct(symlink_to = "/workspace/mypkg"),
        },
    },
    "build": {
        "output.txt": None,
    },
    ".dart_tool": {
        "package_config.json": None,
    },
    ".hidden": {
        "x.txt": None,
    },
    "android": {
        "settings.gradle": None,
    },
    "tool.sh": None,
}

_SCOPED_LINKED = [
    "assets/any.txt",
    "assets/dir/one.txt",
    "lib/mypkg.dart",
    "pubspec.yaml",
]

_SCOPED_WATCHED = [
    "/workspace/mypkg",
    "/workspace/mypkg/pubspec.yaml",
    "/workspace/mypkg/lib",
    "/workspace/mypkg/lib/mypkg.dart",
    "/workspace/mypkg/assets/any.txt",
    "/workspace/mypkg/assets/dir",
    "/workspace/mypkg/assets/dir/one.txt",
    "/workspace/mypkg/assets/dir/BUILD.bazel",
]

def _link_scopes_to_the_pubspec_plan_test_impl(ctx):
    """The spoke links the pubspec plan — nothing it does not read or expose.

    `example/` (with its `build/` output and `.plugin_symlinks` cycle),
    `build/`, `.dart_tool/`, dot-directories, undeclared files, the
    non-plugin `android/` tree, and user BUILD files stay out; skipped
    subtrees are not even watched, while the nested BUILD file is watched
    (appearing content refetches) but not linked.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({"mypkg": _SCOPED_CONTENTS}, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    asserts.equals(env, _SCOPED_LINKED, sorted([link.name for link in mock.linked]))
    asserts.equals(env, sorted(_SCOPED_WATCHED), sorted(mock.watched))
    for link in mock.linked:
        asserts.true(
            env,
            link.target.startswith("/workspace/mypkg/"),
            "link {} must point into the package, got {}".format(link.name, link.target),
        )
    return unittest.end(env)

link_scopes_to_the_pubspec_plan_test = unittest.make(_link_scopes_to_the_pubspec_plan_test_impl)

_PLUGIN_PUBSPEC = """name: mypkg
flutter:
  plugin:
    platforms:
      android:
        package: com.example.mypkg
        pluginClass: MyPlugin
"""

def _plugin_platform_dir_is_mirrored_not_symlinked_test_impl(ctx):
    """A declared platform dir mirrors file by file; the write stays in-spoke.

    The generator always emits `android/BUILD.bazel`, so linking `android/`
    as one directory symlink would carry that write into the user's tree
    (overwriting a user-owned file or creating a new main-repo package).
    Instead the spoke holds a real `android/` directory whose children are
    linked one by one; the generated file then replaces a file symlink (or
    is created) inside the spoke. The user's own BUILD file is watched but
    not linked, and the undeclared `ios/` tree stays out entirely.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": _PLUGIN_PUBSPEC,
            "lib": {"mypkg.dart": None},
            "android": {
                "BUILD.bazel": None,
                "settings.gradle": None,
                "src": {"main": {"Foo.kt": None}},
            },
            "ios": {"Runner.xcodeproj": None},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.false(env, "android" in names, "android/ must not be one dir symlink, got {}".format(names))
    asserts.true(env, "android/settings.gradle" in names, "android children must be linked one by one, got {}".format(names))
    asserts.true(env, "android/src/main/Foo.kt" in names, "nested android sources must be linked, got {}".format(names))
    asserts.false(env, "android/BUILD.bazel" in names, "the user BUILD file must not be linked, got {}".format(names))
    for link in mock.linked:
        asserts.false(
            env,
            link.name == "ios" or link.name.startswith("ios/"),
            "undeclared ios/ must stay out, got {}".format(names),
        )
        if link.name.startswith("android/"):
            asserts.true(
                env,
                link.target.startswith("/workspace/mypkg/android/"),
                "link {} must point into the package's android/, got {}".format(link.name, link.target),
            )
    asserts.true(env, "/workspace/mypkg/android/BUILD.bazel" in mock.watched, "the user BUILD file must still be watched, got {}".format(sorted(mock.watched)))
    asserts.true(env, "/workspace/mypkg/ios/Runner.xcodeproj" not in mock.watched, "undeclared ios/ must not be watched, got {}".format(sorted(mock.watched)))
    return unittest.end(env)

plugin_platform_dir_is_mirrored_not_symlinked_test = unittest.make(_plugin_platform_dir_is_mirrored_not_symlinked_test_impl)

def _non_plugin_package_links_no_android_test_impl(ctx):
    """Without a plugin block no platform directory is generator-read."""
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\n",
            "lib": {"mypkg.dart": None},
            "android": {"settings.gradle": None},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(env, ["lib/mypkg.dart", "pubspec.yaml"], names)
    for seen in mock.watched:
        asserts.false(env, "/android" in seen, "android/ must stay out, saw {}".format(seen))
    return unittest.end(env)

non_plugin_package_links_no_android_test = unittest.make(_non_plugin_package_links_no_android_test_impl)

def _outside_link_replicates_without_descending_test_impl(ctx):
    """A link leaving the package replicates as-is; its target stays outside."""
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": "name: mypkg\n",
            "lib": {
                "mypkg.dart": None,
                "ext.so": struct(symlink_to = "/usr/lib/ext.so"),
            },
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    by_name = {link.name: link.target for link in mock.linked}
    asserts.equals(env, "/usr/lib/ext.so", by_name.get("lib/ext.so", "missing"))
    asserts.true(env, "/workspace/mypkg/lib/ext.so" in mock.watched, "the replicated link must be watched, got {}".format(sorted(mock.watched)))
    for seen in mock.watched:
        asserts.false(env, seen.startswith("/usr/"), "the walk must never descend outside, saw {}".format(seen))
    return unittest.end(env)

outside_link_replicates_without_descending_test = unittest.make(_outside_link_replicates_without_descending_test_impl)

_OVERLAP_PUBSPEC = """name: mypkg
flutter:
  assets:
    - data/x.txt
    - data/
  shaders:
    - shaders/ripple.frag
"""

def _overlapping_entries_link_once_test_impl(ctx):
    """A file inside its own declared dir (or a shader in its dir) links once.

    The real fetch fails the second `ctx.symlink` to the same spoke path
    with "File exists", so the link set dedupes: the file entry wins, the
    directory mirror covers the rest.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({
        "mypkg": {
            "pubspec.yaml": _OVERLAP_PUBSPEC,
            "lib": {"m.dart": None},
            "data": {"x.txt": None, "y.txt": None},
            "shaders": {"ripple.frag": None, "include": {"common.glsl": None}},
        },
    }, path_value = "mypkg", package_name = "mypkg")
    link_path_package(mock.ctx)
    names = sorted([link.name for link in mock.linked])
    asserts.equals(
        env,
        ["data/x.txt", "data/y.txt", "lib/m.dart", "pubspec.yaml", "shaders/include/common.glsl", "shaders/ripple.frag"],
        names,
    )
    return unittest.end(env)

overlapping_entries_link_once_test = unittest.make(_overlapping_entries_link_once_test_impl)

def _ancestor_link_is_refused_test_impl(ctx):
    """A link to the package or an ancestor fails naming package and link.

    `link_path_package` itself `fail()`s on this shape (untestable here),
    so these pin the predicate and the message it fails with: self, parent,
    and root refuse; children, siblings, and prefix-lookalikes pass.
    """
    env = unittest.begin(ctx)
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg"))
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w"))
    asserts.true(env, path_spoke_is_ancestor_cycle("/w/pkg", "/"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg/lib/x"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/other"))
    asserts.false(env, path_spoke_is_ancestor_cycle("/w/pkg", "/w/pkg2"))
    message = ancestor_link_refusal("mypkg", "example/.plugin_symlinks/mypkg", "/workspace/mypkg")
    asserts.true(env, "mypkg" in message, "refusal must name the package: {}".format(message))
    asserts.true(env, "example/.plugin_symlinks/mypkg" in message, "refusal must name the link: {}".format(message))
    return unittest.end(env)

ancestor_link_is_refused_test = unittest.make(_ancestor_link_is_refused_test_impl)

def _path_spoke_platform_dirs_test_impl(ctx):
    """Only declared platforms resolve sources, so only they link."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], path_spoke_platform_dirs(parse_flutter_plugin_block("name: x\n")))
    asserts.equals(env, ["android"], path_spoke_platform_dirs(parse_flutter_plugin_block(_PLUGIN_PUBSPEC)))
    asserts.equals(
        env,
        ["darwin", "ios", "macos"],
        path_spoke_platform_dirs(parse_flutter_plugin_block("name: x\nflutter:\n  plugin:\n    platforms:\n      ios:\n        pluginClass: X\n")),
    )
    asserts.equals(
        env,
        ["android", "darwin", "ios", "linux", "macos", "windows"],
        path_spoke_platform_dirs(parse_flutter_plugin_block(
            "name: x\nflutter:\n  plugin:\n    platforms:\n      android:\n        package: a\n      ios:\n        pluginClass: X\n      macos:\n        pluginClass: X\n      linux:\n        pluginClass: X\n      windows:\n        pluginClass: X\n",
        )),
    )
    return unittest.end(env)

path_spoke_platform_dirs_test = unittest.make(_path_spoke_platform_dirs_test_impl)

def _scoped_shader_includes_block_test_impl(ctx):
    """Include globs cover the declared shaders' own dirs — never `**`."""
    env = unittest.begin(ctx)
    block = scoped_shader_includes_block(["shaders/glow.frag", "shaders/deep/ocean.vert", "ripple.frag"])
    asserts.true(env, "shader_includes = glob(" in block, block)
    asserts.true(env, '"shaders/**/*.glsl"' in block, block)
    asserts.true(env, '"shaders/**/*.frag"' in block, block)
    asserts.true(env, '"shaders/**/*.vert"' in block, block)
    asserts.true(env, '"shaders/deep/**/*.glsl"' in block, block)
    asserts.true(env, '"*.glsl"' in block, block)
    asserts.false(env, '"**/*.glsl"' in block, block)
    return unittest.end(env)

scoped_shader_includes_block_test = unittest.make(_scoped_shader_includes_block_test_impl)

def _skipped_dirs_test_impl(ctx):
    """Build output, tool state, the example app, and dot-dirs never link."""
    env = unittest.begin(ctx)
    for name in ["build", ".dart_tool", "example", ".hidden", ".plugin_symlinks"]:
        asserts.true(env, is_path_spoke_skipped_dir(name), name + " must be skipped")
    for name in ["lib", "assets", "shaders", "android", "hook"]:
        asserts.false(env, is_path_spoke_skipped_dir(name), name + " must link")
    return unittest.end(env)

skipped_dirs_test = unittest.make(_skipped_dirs_test_impl)

def _lock_path_joins_the_lock_dir_test_impl(ctx):
    """A root-module entry resolves against the lock file's directory."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/hello_world/platform_assets",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "platform_assets",
        ),
    )
    return unittest.end(env)

def _lock_path_stays_inside_the_workspace_test_impl(ctx):
    """`..` segments normalize lexically without leaving the workspace."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/shared/x",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "../shared/x",
        ),
    )
    return unittest.end(env)

def _lock_path_uses_the_lock_files_own_directory_test_impl(ctx):
    """A lock below the package root resolves entries against its own directory.

    Pub records a path dependency relative to the dependent package — the
    lock file's own directory, which is the label's package plus the dirname
    of its name. Ignoring the dirname links the wrong directory: with a root
    `localpkg/` decoy beside `app2/localpkg/`, the entry must still resolve
    to `app2/localpkg`.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "app2/localpkg",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//:app2/pubspec.lock"),
            "localpkg",
        ),
    )
    asserts.equals(
        env,
        "foo/app2/localpkg",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//foo:app2/pubspec.lock"),
            "localpkg",
        ),
    )
    asserts.equals(
        env,
        "shared/x",
        workspace_relative_lock_path(
            "deps",
            "localpkg",
            Label("//:app2/pubspec.lock"),
            "../shared/x",
        ),
    )
    return unittest.end(env)

lock_path_uses_the_lock_files_own_directory_test = unittest.make(_lock_path_uses_the_lock_files_own_directory_test_impl)

def _root_lock_needs_no_refusal_test_impl(ctx):
    """A main-repo lock (empty `workspace_name`) resolves path deps freely."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        foreign_lock_path_error(
            "deps",
            "platform_assets",
            struct(workspace_name = "", package = "e2e/hello_world"),
        ),
    )
    return unittest.end(env)

def _foreign_lock_path_dep_is_refused_test_impl(ctx):
    """A non-root lock's path dep is refused naming hub, package, and lock.

    Resolving it against the consumer workspace would link the wrong
    directory, silently. The message must carry everything the fix needs:
    declare the path dep in the root module's own lock instead.
    """
    env = unittest.begin(ctx)
    message = foreign_lock_path_error(
        "deps",
        "platform_assets",
        struct(workspace_name = "some_dep", package = ""),
    )
    asserts.true(env, message != None, "a foreign lock must be refused")
    asserts.true(env, "deps" in message, "refusal must name the hub")
    asserts.true(env, "platform_assets" in message, "refusal must name the package")
    return unittest.end(env)

root_lock_needs_no_refusal_test = unittest.make(_root_lock_needs_no_refusal_test_impl)
foreign_lock_path_dep_is_refused_test = unittest.make(_foreign_lock_path_dep_is_refused_test_impl)

lock_path_joins_the_lock_dir_test = unittest.make(_lock_path_joins_the_lock_dir_test_impl)
lock_path_stays_inside_the_workspace_test = unittest.make(_lock_path_stays_inside_the_workspace_test_impl)

def path_package_test_suite(name):
    """Declares the path-package spoke hermeticity unit tests.

    Args:
        name: Test suite name.
    """
    unittest.suite(
        name,
        ancestor_link_is_refused_test,
        foreign_lock_path_dep_is_refused_test,
        link_scopes_to_the_pubspec_plan_test,
        lock_path_joins_the_lock_dir_test,
        lock_path_stays_inside_the_workspace_test,
        lock_path_uses_the_lock_files_own_directory_test,
        non_plugin_package_links_no_android_test,
        outside_link_replicates_without_descending_test,
        overlapping_entries_link_once_test,
        path_spoke_platform_dirs_test,
        plugin_platform_dir_is_mirrored_not_symlinked_test,
        root_lock_needs_no_refusal_test,
        scoped_shader_includes_block_test,
        skipped_dirs_test,
    )
