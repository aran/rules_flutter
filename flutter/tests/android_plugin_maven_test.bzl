"""Unit tests for android_plugin_maven.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:android_plugin_maven.bzl",
    "annotated_requirements",
    "artifacts_report",
    "compare_maven_versions",
    "format_maven_failure",
    "maven_check_message",
    "maven_labels",
    "maven_problems",
    "maven_target_name",
    "maven_warning_message",
    "merge_plugin_requirements",
    "parse_gradle_maven_dependencies",
    "unread_lines",
)

# shared_preferences_android's dependencies block (trimmed).
_SHARED_PREFERENCES_KTS = """
buildscript {
    dependencies {
        classpath("com.android.tools.build:gradle:8.1.0")
    }
}
android {
    namespace = "io.flutter.plugins.sharedpreferences"
    dependencies {
        implementation("androidx.datastore:datastore:1.1.7")
        implementation("androidx.datastore:datastore-preferences:1.1.7")
        implementation("androidx.preference:preference:1.2.1")
        implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.0") // provided
        testImplementation("org.jetbrains.kotlin:kotlin-test")
        testImplementation("io.mockk:mockk:1.13.5")
        androidTestImplementation("androidx.test:core:1.5.0")
        lintChecks("x:y:1")
    }
}
"""

def _parsed(d):
    return (d.kind, d.group + ":" + d.artifact, d.version)

def _shared_preferences_test_impl(ctx):
    env = unittest.begin(ctx)
    r = parse_gradle_maven_dependencies(_SHARED_PREFERENCES_KTS)
    asserts.equals(env, [], r.unread)

    # `android { dependencies { } }` declares the project's own dependencies.
    asserts.equals(env, [True, True, True], [d.checked for d in r.deps])
    asserts.equals(env, [
        ("deps", "androidx.datastore:datastore", "1.1.7"),
        ("deps", "androidx.datastore:datastore-preferences", "1.1.7"),
        ("deps", "androidx.preference:preference", "1.2.1"),
    ], [_parsed(d) for d in r.deps])
    return unittest.end(env)

shared_preferences_test = unittest.make(_shared_preferences_test_impl)

def _groovy_and_variables_test_impl(ctx):
    env = unittest.begin(ctx)
    r = parse_gradle_maven_dependencies("""
def exoplayer_version = "1.5.1"
val exoplayerVersion = "1.9.2"
ext.other = '2.0.0'
ext["bracket"] = "3.0.0"
dependencies {
    implementation 'androidx.annotation:annotation:1.9.1'
    implementation "androidx.media3:media3-exoplayer:$exoplayer_version"
    api("androidx.media3:media3-ui:${exoplayerVersion}")
    implementation "a:b:$other"
    implementation("c:d:${bracket}@aar")
    implementation "e:f:$nope"
    implementation "g:h:1.+"
    implementation "i:j:[1.0,2.0)"
    implementation "k:l:latest.release"
    implementation "m:n:1.0:sources"
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8:$kotlin_version")
    implementation "io.flutter:flutter_embedding_debug:1.0"
    compileOnly "o:p:1.0"
    provided "q:r:1.0"
    runtimeOnly "s:t:1.0"
}
""")
    asserts.equals(env, [], r.unread)
    asserts.equals(env, [
        ("deps", "androidx.annotation:annotation", "1.9.1"),
        ("deps", "androidx.media3:media3-exoplayer", "1.5.1"),
        ("deps", "androidx.media3:media3-ui", "1.9.2"),
        ("deps", "a:b", "2.0.0"),
        ("deps", "c:d", "3.0.0"),
        ("deps", "e:f", None),
        ("deps", "g:h", None),
        ("deps", "i:j", None),
        ("deps", "k:l", None),
        ("deps", "m:n", "1.0"),
        ("compile_only", "o:p", "1.0"),
        ("compile_only", "q:r", "1.0"),
        ("runtime", "s:t", "1.0"),
    ], [_parsed(d) for d in r.deps])
    return unittest.end(env)

groovy_and_variables_test = unittest.make(_groovy_and_variables_test_impl)

def _unsupported_forms_test_impl(ctx):
    env = unittest.begin(ctx)
    lines = [
        "implementation(libs.foo)",
        'implementation(project(":x"))',
        'implementation(platform("a:b:1"))',
        'implementation("a:b")',
        "implementation files('x.jar')",
        "implementation group: 'a', name: 'b', version: '1'",
        'implementation("a:b:1") { exclude(group = "x") }',
        'kapt("a:b:1")',
        'ksp "a:b:1"',
        'annotationProcessor "a:b:1"',
        'coreLibraryDesugaring("a:b:1")',
        'debugImplementation("a:b:1")',
        'releaseCompileOnly "a:b:1"',
        "implementation 'a:b:1', 'c:d:2'",
    ]
    r = parse_gradle_maven_dependencies("dependencies {\n" + "\n".join(["  " + line for line in lines]) + "\n}\n")
    asserts.equals(env, [], r.deps)
    asserts.equals(env, lines, [u.line for u in r.unread])
    asserts.equals(env, ["form"] * len(lines), [u.why for u in r.unread])

    # Each is named by its line in the file.
    asserts.equals(env, list(range(2, 2 + len(lines))), [u.line_number for u in r.unread])

    # Configuration blocks and unrelated lines are not dependencies.
    r = parse_gradle_maven_dependencies("""
kapt { correctErrorTypes = true }
// implementation(libs.foo)
compileSdk = 34
compileOptions { sourceCompatibility = 1 }
""")
    asserts.equals(env, ([], []), (r.deps, r.unread))
    return unittest.end(env)

unsupported_forms_test = unittest.make(_unsupported_forms_test_impl)

def _conditional_declarations_test_impl(ctx):
    """A declaration inside a condition is read, linked if present, and not checked.

    Gradle may run it or not, so the reader cannot say whether the plugin
    needs it; only one directly in `dependencies { }` is a requirement.
    """
    env = unittest.begin(ctx)
    r = parse_gradle_maven_dependencies("""\
dependencies {
    implementation "a:always:1.0"
    if (project.hasProperty("x")) {
        implementation "a:if:1.0"
    } else {
        implementation "a:else:1.0"
    }
}
afterEvaluate {
    dependencies {
        implementation "a:later:1.0"
    }
}
dependencies { if (flag) { api 'a:one_line:1.0' } }
""")
    asserts.equals(
        env,
        [
            ("a:always", True),
            ("a:if", False),
            ("a:else", False),
            ("a:later", False),
            ("a:one_line", False),
        ],
        [(d.group + ":" + d.artifact, d.checked) for d in r.deps],
    )
    asserts.equals(
        env,
        [(4, "conditional"), (6, "conditional"), (11, "conditional"), (14, "conditional")],
        [(u.line_number, u.why) for u in r.unread],
    )
    return unittest.end(env)

conditional_declarations_test = unittest.make(_conditional_declarations_test_impl)

def _versions_test_impl(ctx):
    env = unittest.begin(ctx)
    for lower, higher in [
        ("1.9.1", "1.10.0"),
        ("1.0.0-alpha06", "1.0.0-alpha07"),
        ("1.0.0-alpha06", "1.0.0-beta01"),
        ("1.0.0-beta01", "1.0.0-rc01"),
        ("1.2.0-rc01", "1.2.0"),
        ("1.0.0-SNAPSHOT", "1.0.0"),
        ("1.0.0", "1.0.0-sp1"),
        ("1.0.0", "1.0.1"),
        ("1.0", "1.0.0.1"),
        ("2.9.0", "2.48.0"),
        ("1.0.0-rc01", "1.0.0-vendor"),
        ("1.0.0-vendora", "1.0.0-vendorb"),
        ("1.0-alpha", "1.0-1"),
    ]:
        asserts.equals(env, -1, compare_maven_versions(lower, higher), lower + " < " + higher)
        asserts.equals(env, 1, compare_maven_versions(higher, lower), higher + " > " + lower)
    for a, b in [
        ("1.0", "1.0.0"),
        ("1.2.0", "1.2"),
        ("1.0.0-ga", "1.0.0"),
        ("1.0.0-final", "1.0"),
        ("1.0.0-rc1", "1.0.0-cr1"),
        ("1.0.0-RC1", "1.0.0-rc01"),
    ]:
        asserts.equals(env, 0, compare_maven_versions(a, b), a + " == " + b)
    return unittest.end(env)

versions_test = unittest.make(_versions_test_impl)

def _escape_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "androidx_datastore_datastore_preferences",
        maven_target_name("androidx.datastore", "datastore-preferences"),
    )
    asserts.equals(env, "a_b_c_d_e_f", maven_target_name("a.b", "c/d+e$f"))
    return unittest.end(env)

escape_test = unittest.make(_escape_test_impl)

def _dep(coordinate, version, kind = "deps", checked = True):
    return {"kind": kind, "coordinate": coordinate, "version": version, "line": "", "checked": checked}

def _pkg(name, version, deps, unread = []):
    return {
        "package": name,
        "version": version,
        "script": "android/build.gradle",
        "deps": deps,
        "unread": unread,
    }

def _unread(line_number, line, why = "form"):
    return {"line": line, "line_number": line_number, "why": why}

def _labels_test_impl(ctx):
    env = unittest.begin(ctx)
    r = maven_labels([
        _dep("androidx.annotation:annotation", "1.9.1"),
        _dep("androidx.annotation:annotation", "1.9.1"),
        _dep("androidx.core:core", None, "compile_only"),
        _dep("x:y", None, "runtime"),
    ])
    asserts.equals(env, ["@rules_flutter_maven//:androidx_annotation_annotation"], r.deps)
    asserts.equals(env, ["@rules_flutter_maven//:androidx_core_core"], r.compile_only)
    asserts.equals(env, ["@rules_flutter_maven//:x_y"], r.runtime_deps)
    return unittest.end(env)

labels_test = unittest.make(_labels_test_impl)

def _labels_leave_out_what_was_not_resolved_test_impl(ctx):
    """An artifact `@rules_flutter_maven` lacks has no target, so a library names none.

    The application that links the plugin reports it, by name, with the rest.
    """
    env = unittest.begin(ctx)
    r = maven_labels(
        [_dep("a:present", None), _dep("b:absent", None), _dep("c:absent", None, "runtime")],
        {"a:present": "1.0"},
    )
    asserts.equals(env, ["@rules_flutter_maven//:a_present"], r.deps)
    asserts.equals(env, [], r.runtime_deps)
    return unittest.end(env)

labels_leave_out_what_was_not_resolved_test = unittest.make(_labels_leave_out_what_was_not_resolved_test_impl)

def _check_names_only_what_the_linked_plugins_need_test_impl(ctx):
    """An app's Maven check names the artifacts of the plugins it links, and no others.

    A plugin the lock lists and the app does not link may declare artifacts
    nobody installed; they are no concern of the app.
    """
    env = unittest.begin(ctx)
    data = {
        "resolved": {"g:have": "1.0"},
        "packages": [
            _pkg("a", "1.0", [_dep("g:needed_by_a", "2.0"), _dep("g:have", "1.0")]),
            _pkg("b", "1.0", [_dep("g:needed_by_b", "3.0")], [_unread(3, "implementation(libs.b)")]),
            _pkg("c", "1.0", [_dep("g:needed_by_c", None)]),
        ],
    }

    only_a = maven_check_message(data, {"a": True})
    asserts.true(env, '"g:needed_by_a:2.0",  # declared by package:a 1.0; missing' in only_a, only_a)
    for absent in ["needed_by_b", "needed_by_c", "libs.b", "g:have"]:
        asserts.false(env, absent in only_a, absent + " in:\n" + only_a)

    a_and_b = maven_check_message(data, {"a": True, "b": True})
    asserts.true(env, "g:needed_by_a" in a_and_b and "g:needed_by_b" in a_and_b, a_and_b)
    asserts.false(env, "needed_by_c" in a_and_b, a_and_b)

    # A line the reader cannot read is no failure: it warns.
    asserts.false(env, "libs.b" in a_and_b, a_and_b)
    asserts.equals(env, "", maven_warning_message(data, {"a": True}, "//:app"))
    warning = maven_warning_message(data, {"a": True, "b": True}, "//:app")
    asserts.true(
        env,
        "    package:b 1.0, android/build.gradle\n        3: implementation(libs.b)" in warning,
        warning,
    )

    # A package the hub records nothing for (no Android library of a pub
    # plugin's kind) needs nothing, and an app that links none is satisfied.
    asserts.equals(env, "", maven_check_message(data, {"other": True}))
    asserts.equals(env, "", maven_check_message(data, {}))
    return unittest.end(env)

check_names_only_what_the_linked_plugins_need_test = unittest.make(_check_names_only_what_the_linked_plugins_need_test_impl)

def _merge_test_impl(ctx):
    env = unittest.begin(ctx)
    req = merge_plugin_requirements([
        _pkg("a", "1.2", [_dep("g:x", "1.0"), _dep("g:only_a", "2.0")]),
        _pkg("b", "3.4", [_dep("g:x", "1.10"), _dep("g:presence", None)]),
        _pkg("c", "5.0", [_dep("g:presence", None), _dep("g:x", "1.9")]),
    ])
    asserts.equals(env, "1.10", req["g:x"]["version"])
    asserts.equals(
        env,
        ["package:a 1.2", "package:b 3.4", "package:c 5.0"],
        req["g:x"]["declared_by"],
    )
    asserts.equals(env, None, req["g:presence"]["version"])
    asserts.equals(env, ["package:b 3.4", "package:c 5.0"], req["g:presence"]["declared_by"])
    asserts.equals(env, "2.0", req["g:only_a"]["version"])
    return unittest.end(env)

merge_test = unittest.make(_merge_test_impl)

def _problems_test_impl(ctx):
    env = unittest.begin(ctx)
    req = merge_plugin_requirements([
        _pkg("a", "1.2", [_dep("g:missing", "1.0"), _dep("g:old", "1.0"), _dep("g:fine", "1.0")]),
        _pkg("b", "3.4", [_dep("g:old", "1.2"), _dep("g:novers", None), _dep("g:nomatch", None)]),
    ])
    problems = maven_problems(req, {
        "g:old": "1.1",
        "g:fine": "2.0",
        "g:novers": "7",
    })
    asserts.equals(
        env,
        [
            ("g:missing", "missing"),
            ("g:nomatch", "missing"),
            ("g:old", "resolves 1.1"),
        ],
        [(p["coordinate"], p["reason"]) for p in problems],
    )
    asserts.equals(env, "1.2", problems[2]["version"])
    asserts.equals(env, ["package:a 1.2", "package:b 3.4"], problems[2]["declared_by"])
    asserts.equals(env, [], maven_problems(req, {
        "g:missing": "1.0",
        "g:nomatch": "0",
        "g:old": "1.2",
        "g:fine": "1.0",
        "g:novers": "1",
    }))
    return unittest.end(env)

problems_test = unittest.make(_problems_test_impl)

def _failure_message_test_impl(ctx):
    env = unittest.begin(ctx)
    req = merge_plugin_requirements([
        _pkg("a", "1.2", [_dep("g:old", "1.0")]),
        _pkg("b", "3.4", [_dep("g:old", "1.2"), _dep("g:gone", None)]),
    ])
    problems = maven_problems(req, {"g:old": "1.1"})
    message = format_maven_failure(problems)
    for needle in [
        '"g:gone:<version>",  # declared by package:b 3.4; missing',
        '"g:old:1.2",  # declared by package:a 1.2, package:b 3.4; resolves 1.1',
        "REPIN=1 bazel run @rules_flutter_maven//:pin",
        "bazel run @<hub>//android:maven_artifacts",
    ]:
        asserts.true(env, needle in message, needle + " missing from:\n" + message)
    asserts.equals(env, "", format_maven_failure([]))
    return unittest.end(env)

failure_message_test = unittest.make(_failure_message_test_impl)

def _warning_message_test_impl(ctx):
    env = unittest.begin(ctx)
    data = {
        "resolved": {},
        "packages": [
            _pkg("c", "5.0", [], [
                _unread(12, "implementation(libs.x)"),
                _unread(13, "kapt(\"a:b:1\")"),
            ]),
            _pkg("d", "1.0", [_dep("g:maybe", "1.0", checked = False)], [
                _unread(7, "api(project(\":p\"))"),
                _unread(9, "implementation \"g:maybe:1.0\"", "conditional"),
            ]),
        ],
    }
    message = maven_warning_message(data, {"c": True, "d": True}, "//:app")
    for needle in [
        "//:app links Android plugins",
        "    package:c 5.0, android/build.gradle\n        12: implementation(libs.x)\n        13: kapt(\"a:b:1\")",
        "    package:d 1.0, android/build.gradle\n        7: api(project(\":p\"))",
        "    package:d 1.0, android/build.gradle\n        9: implementation \"g:maybe:1.0\"",
        '    flutter_pub.annotation(package = "c", android_deps = ["@rules_flutter_maven//:<artifact target>"])',
        'maven.install(name = "rules_flutter_maven"',
    ]:
        asserts.true(env, needle in message, needle + " missing from:\n" + message)

    # An unchecked declaration is no requirement.
    asserts.equals(env, "", maven_check_message(data, {"c": True, "d": True}))
    return unittest.end(env)

warning_message_test = unittest.make(_warning_message_test_impl)

def _annotated_test_impl(ctx):
    env = unittest.begin(ctx)
    resolved = {"androidx.browser:browser": "1.9.0", "g:other": "1.0"}
    label = {"label": "@@x//:androidx_browser_browser", "name": "androidx_browser_browser"}
    pkg = _pkg("a", "1.0", [], [_unread(3, "implementation(platform(\"g:bom:1\"))")])
    pkg["annotated"] = [label]

    # The artifact joins the plugin's declarations, so it is checked, reported
    # and linked as a Gradle-declared one is.
    result = annotated_requirements([pkg], resolved)
    asserts.equals(env, [], result.errors)
    asserts.equals(env, ["androidx.browser:browser"], [d["coordinate"] for d in result.packages[0]["deps"]])
    req = merge_plugin_requirements(result.packages)
    asserts.equals(env, ["package:a 1.0"], req["androidx.browser:browser"]["declared_by"])
    asserts.equals(env, [], maven_problems(req, resolved))

    # What the install lacks is named with the package, not a missing target.
    result = annotated_requirements([pkg], {"g:other": "1.0"})
    asserts.equals(env, 1, len(result.errors))
    for needle in ['package = "a"', "@@x//:androidx_browser_browser", "maven.install"]:
        asserts.true(env, needle in result.errors[0], result.errors[0])

    # The root stated this plugin's dependencies: no warning about its unread forms.
    data = {"resolved": resolved, "packages": [pkg]}
    asserts.equals(env, "", maven_warning_message(data, {"a": True}, "//:app"))
    return unittest.end(env)

annotated_test = unittest.make(_annotated_test_impl)

def _report_test_impl(ctx):
    env = unittest.begin(ctx)
    req = merge_plugin_requirements([
        _pkg("a", "1.2", [_dep("g:old", "1.2"), _dep("g:fine", "1.0")]),
    ])
    report = json.decode(artifacts_report(
        req,
        {"g:old": "1.1", "g:fine": "1.0"},
        ["https://maven.google.com"],
        "//:app",
    ))
    asserts.equals(env, {
        "app": "//:app",
        "repositories": ["https://maven.google.com"],
        "requirements": {
            "g:fine": {"version": "1.0", "declared_by": ["package:a 1.2"]},
            "g:old": {"version": "1.2", "declared_by": ["package:a 1.2"]},
        },
        "resolved": {"g:old": "1.1", "g:fine": "1.0"},
        "unread": [],
    }, report)

    # The lines the reader cannot read go into the report, so that its reader
    # is told the plugins may need more than its paste block. A plugin the
    # root annotated, and a declaration inside a condition, are left out, as
    # the link-time warning leaves them out.
    unread = unread_lines([
        _pkg("b", "2.0", [], [
            _unread(69, 'implementation platform("g:bom:${v}")'),
            _unread(70, "implementation 'g:versionless'"),
            _unread(80, "implementation 'g:c:1.0'", why = "conditional"),
        ]),
        dict(_pkg("c", "1.0", [], [_unread(3, "implementation(libs.c)")]), annotated = ["@x//:c"]),
    ])
    asserts.equals(env, [
        {"package": "package:b 2.0", "script": "android/build.gradle", "line_number": 69, "line": 'implementation platform("g:bom:${v}")'},
        {"package": "package:b 2.0", "script": "android/build.gradle", "line_number": 70, "line": "implementation 'g:versionless'"},
    ], unread)
    report = json.decode(artifacts_report({}, {}, [], unread = unread))
    asserts.equals(env, unread, report["unread"])
    return unittest.end(env)

report_test = unittest.make(_report_test_impl)

def _group_and_configuration_test_impl(ctx):
    env = unittest.begin(ctx)
    r = parse_gradle_maven_dependencies("""
group = "io.flutter.plugins.example"
version = "1.0"
android {
    defaultConfig { group "not.the.project" }
}
dependencies {
    api "a:b:1.0"
    implementation("c:d:2.0")
    runtimeOnly "e:f:3.0"
    add("api", "g:h:4.0")
}
""")
    asserts.equals(env, "io.flutter.plugins.example", r.group)
    asserts.equals(
        env,
        [("api", "a:b"), ("implementation", "c:d"), ("runtimeOnly", "e:f"), ("api", "g:h")],
        [(d.configuration, d.group + ":" + d.artifact) for d in r.deps],
    )

    # Groovy's call without `=`, and none at all.
    asserts.equals(env, "com.example.x", parse_gradle_maven_dependencies("group 'com.example.x'\n").group)
    asserts.equals(env, None, parse_gradle_maven_dependencies("version = '1.0'\n").group)

    # A group that is not a literal is not read.
    asserts.equals(env, None, parse_gradle_maven_dependencies("group = rootProject.group\n").group)
    return unittest.end(env)

group_and_configuration_test = unittest.make(_group_and_configuration_test_impl)

def android_plugin_maven_test_suite(name):
    unittest.suite(
        name,
        shared_preferences_test,
        group_and_configuration_test,
        groovy_and_variables_test,
        unsupported_forms_test,
        conditional_declarations_test,
        versions_test,
        escape_test,
        labels_test,
        labels_leave_out_what_was_not_resolved_test,
        check_names_only_what_the_linked_plugins_need_test,
        merge_test,
        problems_test,
        failure_message_test,
        warning_message_test,
        annotated_test,
        report_test,
    )
