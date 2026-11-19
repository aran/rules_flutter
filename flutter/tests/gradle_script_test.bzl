"""Unit tests for the static evaluation of Gradle script values (gradle_script.bzl)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:gradle_script.bzl",
    "gradle_scope",
    "gradle_string",
    "gradle_tokens",
    "parse_gradle_properties",
    "strip_comments",
)

# firebase_core 5.1.0's `android/build.gradle`, lines 31-35, and the
# declaration of its line 69.
_FIREBASE_CORE_FUNCTION = """\
def getRootProjectExtOrDefaultProperty(name) {
    if (!rootProject.ext.has("FlutterFire")) return project.properties[name]
    if (!rootProject.ext.get("FlutterFire")[name]) return project.properties[name]
    return rootProject.ext.get("FlutterFire").get(name)
}
"""
_FIREBASE_CORE_BOM = '"com.google.firebase:firebase-bom:${getRootProjectExtOrDefaultProperty("FirebaseSDKVersion")}"'

# cloud_firestore 7.2.0's `android/build.gradle`, lines 22-33, and the
# declaration of its line 63.
_CLOUD_FIRESTORE_FUNCTION = """\
def firebaseCoreProject = findProject(':firebase_core')
if (firebaseCoreProject == null) {
    throw new GradleException('Could not find the firebase_core FlutterFire plugin, have you added it as a dependency in your pubspec?')
} else if (!firebaseCoreProject.properties['FirebaseSDKVersion']) {
    throw new GradleException('A newer version of the firebase_core FlutterFire plugin is required, please update your firebase_core pubspec dependency.')
}

def getRootProjectExtOrCoreProperty(name, firebaseCoreProject) {
    if (!rootProject.ext.has('FlutterFire')) return firebaseCoreProject.properties[name]
    if (!rootProject.ext.get('FlutterFire')[name]) return firebaseCoreProject.properties[name]
    return rootProject.ext.get('FlutterFire').get(name)
}
"""
_CLOUD_FIRESTORE_BOM = '"com.google.firebase:firebase-bom:${getRootProjectExtOrCoreProperty("FirebaseSDKVersion", firebaseCoreProject)}"'

def _evaluate(script, expression, properties = {}):
    return gradle_string(expression, gradle_scope(gradle_tokens(script), properties))

def _firebase_test_impl(ctx):
    env = unittest.begin(ctx)

    # A plugin's own property, through its function: the root project sets
    # no `FlutterFire`, so the function returns the default.
    asserts.equals(
        env,
        ["com.google.firebase:firebase-bom:35.1.0"],
        _evaluate(_FIREBASE_CORE_FUNCTION, _FIREBASE_CORE_BOM, {"FirebaseSDKVersion": "35.1.0"}),
    )

    # Without the property the function returns null, which is no version.
    asserts.equals(
        env,
        ["com.google.firebase:firebase-bom:", None],
        _evaluate(_FIREBASE_CORE_FUNCTION, _FIREBASE_CORE_BOM),
    )

    # Another plugin's property, which only the hub knows.
    asserts.equals(
        env,
        ["com.google.firebase:firebase-bom:", {"package": "firebase_core", "property": "FirebaseSDKVersion"}],
        _evaluate(_CLOUD_FIRESTORE_FUNCTION, _CLOUD_FIRESTORE_BOM),
    )
    return unittest.end(env)

firebase_test = unittest.make(_firebase_test_impl)

def _values_test_impl(ctx):
    env = unittest.begin(ctx)
    script = """\
def literal = "1.0"
val kotlin: String = '2.0'
ext.dotted = "3.0"
ext["bracketed"] = "4.0"
ext {
    block = '5.0'
    number = 34
}
def computed = someCall()
def f(a) {
    return a
}
def g(a) {
    if (project.hasProperty("missing")) return "no"
    return project.findProperty(a)
}
def reassigned = "1.0"
if (flag) {
    reassigned = compute()
}
def withBlock(a) {
    if (a) {
        return a
    }
}
"""
    properties = {"fromProperties": "6.0"}
    for expression, parts in [
        ("'single $literal'", ["single $literal"]),
        ('"$literal"', ["1.0"]),
        ('"${kotlin}"', ["2.0"]),
        ('"$dotted-$bracketed"', ["3.0-4.0"]),
        ('"${block}.${number}"', ["5.0.34"]),
        ('"$fromProperties"', ["6.0"]),
        ('"${project.properties["fromProperties"]}"', ["6.0"]),
        ('"${project.properties.fromProperties}"', ["6.0"]),
        ('"${project.ext.dotted}"', ["3.0"]),
        ('"${ext.has("dotted")}"', [None]),
        ('"${f("x")}"', ["x"]),
        ('"${g("fromProperties")}"', ["6.0"]),
        ('"${rootProject.ext.has("x")}"', [None]),
        ('"\\${literal}"', ["${literal}"]),
        ('"a:b:$unknown"', ["a:b:", None]),
        ('"a:b:$computed"', ["a:b:", None]),
        ('"a:b:$reassigned"', ["a:b:", None]),
        ('"a:b:${withBlock("x")}"', ["a:b:", None]),
        ('"${findProject(":other").properties["v"]}"', [{"package": "other", "property": "v"}]),
        ('"${project(":other").findProperty("v")}"', [{"package": "other", "property": "v"}]),
        ("literal", ["1.0"]),
        ("f('y')", ["y"]),
        ("someCall()", None),
        ("'a' + 'b'", None),
    ]:
        asserts.equals(env, parts, _evaluate(script, expression, properties), expression)
    return unittest.end(env)

values_test = unittest.make(_values_test_impl)

def _properties_test_impl(ctx):
    env = unittest.begin(ctx)

    # firebase_core 5.1.0's `android/gradle.properties`, and other forms.
    asserts.equals(
        env,
        {"FirebaseSDKVersion": "35.1.0", "a": "1", "b": "2", "c": "3", "empty": ""},
        parse_gradle_properties("""\
# https://firebase.google.com/support/release-notes/android
FirebaseSDKVersion=35.1.0
! a comment
a = 1
b: 2
c 3
empty=
"""),
    )
    return unittest.end(env)

properties_test = unittest.make(_properties_test_impl)

def _comments_test_impl(ctx):
    env = unittest.begin(ctx)

    # A block comment spanning lines is removed with its newlines kept, as
    # are `//` comments; neither is a comment inside a string.
    asserts.equals(
        env,
        "a\n\nb \n'/* not */' \"// not\" \"${x('/*')}\"\nc d\n",
        strip_comments("a/* one\ntwo */\nb // gone\n'/* not */' \"// not\" \"${x('/*')}\"\nc/* x */ d\n"),
    )

    # A quote no line closes does not hide what follows; an unclosed block
    # comment runs to the end.
    asserts.equals(env, "x 'it\ny \n\n", strip_comments("x 'it\ny /* z\n\n"))
    asserts.equals(env, "don't\nz \n", strip_comments("don't\nz // '\n"))

    # The tokens of a script with block comments: none of its declarations
    # is read, and the statements after them keep their line numbers.
    tokens = gradle_tokens("""\
dependencies {
    /* implementation 'a:commented:1'
       implementation 'b:commented:1' */
    implementation 'c:kept:1' /* trailing */
    /** api 'd:doc:1' */ api 'e:kept:1'
}
""")
    asserts.equals(
        env,
        [
            ("open", "dependencies", 1),
            ("statement", "implementation 'c:kept:1'", 4),
            ("statement", "api 'e:kept:1'", 5),
            ("close", "", 6),
        ],
        [(t.kind, t.text, t.line) for t in tokens],
    )
    return unittest.end(env)

comments_test = unittest.make(_comments_test_impl)

def gradle_script_test_suite(name):
    unittest.suite(
        name,
        firebase_test,
        values_test,
        properties_test,
        comments_test,
    )
