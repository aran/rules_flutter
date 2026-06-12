"""Flutter rules for web builds.

Two tiers of API:

    Tier 1 — flutter_web_app (self-contained, recommended):

        load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

        flutter_web_app(
            name = "my_web_app",
            deps = ["@deps//:flutter"],
            app_name = "My App",
        )

    Prerequisites: run `flutter create --platforms=web .` to generate
    the conventional `web/` directory with index.html, manifest.json,
    and icons.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:web.bzl",
            "flutter_web_bundle",
            "flutter_web_index_html_gen",
            "flutter_web_index_html_subst",
            "flutter_web_manifest_gen")

        # Substitute Flutter `$`-style placeholders ($FLUTTER_BASE_HREF,
        # $FLUTTER_STATIC_ASSETS_URL) in your own web/index.html. Use this
        # whenever you compose flutter_web_bundle by hand against a template
        # produced by `flutter create`; flutter_web_bundle copies the file
        # verbatim and does not substitute on its own.
        flutter_web_index_html_subst(
            name = "my_index",
            src = "web/index.html",
            base_href = "/myapp/",
        )

        # Or, generate a default index.html (substitution happens internally).
        # flutter_web_index_html_gen(name = "my_index", app_name = "My App")

        flutter_web_manifest_gen(name = "my_manifest", app_name = "My App")

        flutter_web_bundle(
            name = "my_web_app",
            main = "lib/main.dart",
            deps = ["@deps//:flutter"],
            index_html = ":my_index",
            manifest_json = ":my_manifest",
            web_assets = glob(["web/favicon.png", "web/icons/**"]),
        )

Unlike other platform rules, web rules take `main` + `deps` (Dart source)
directly — NOT a `flutter_application` target. This is because web compilation
uses dart2wasm/dart2js which consume Dart source directly, so the compilation
pipeline is structurally different from AOT platforms.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("//flutter/private:flutter_web_application.bzl", _flutter_web_bundle_rule = "flutter_web_bundle")

# -- Gen helpers (Tier 2) -----------------------------------------------------

_SERVICE_WORKER_REGISTRATION = """\
  <script>
    if ("serviceWorker" in navigator) {
      window.addEventListener("load", function() {
        navigator.serviceWorker.register("flutter_service_worker.js");
      });
    }
  </script>
"""

def flutter_web_index_html_gen(name, app_name, base_href = "/", pwa = True, **kwargs):
    """Generates a web index.html from the default Bazel template.

    The output is a deployment-ready HTML file with all placeholders
    substituted (including Flutter's `$FLUTTER_BASE_HREF`), suitable for
    passing directly to `flutter_web_bundle` via `index_html`.

    Args:
        name: Target name.
        app_name: Application name substituted into the HTML title and meta tags.
        base_href: Value substituted for `$FLUTTER_BASE_HREF` (default "/").
            Must start and end with "/".
        pwa: If True (default), include service worker registration script.
            If False, omit the registration script.
        **kwargs: Additional arguments (e.g. tags, visibility).
    """
    if not base_href.startswith("/") or not base_href.endswith("/"):
        fail("flutter_web_index_html_gen(name = %r): base_href must start and end with '/', got %r" % (name, base_href))

    sw_script = _SERVICE_WORKER_REGISTRATION if pwa else ""
    expand_template(
        name = name,
        out = name + ".html",
        template = Label("//flutter/private/runners/web:index.html"),
        substitutions = {
            "$FLUTTER_BASE_HREF": base_href,
            "{APP_NAME}": app_name,
            "{SERVICE_WORKER_SCRIPT}": sw_script,
        },
        **kwargs
    )

def flutter_web_manifest_gen(name, app_name, **kwargs):
    """Generates a manifest.json from the default Bazel template.

    Args:
        name: Target name.
        app_name: Application name substituted into the manifest fields.
        **kwargs: Additional arguments (e.g. tags, visibility).
    """
    expand_template(
        name = name,
        out = name + ".json",
        template = Label("//flutter/private/runners/web:manifest.json"),
        substitutions = {"{APP_NAME}": app_name},
        **kwargs
    )

def flutter_web_index_html_subst(
        name,
        src,
        base_href = "/",
        static_assets_url = None,
        **kwargs):
    """Substitutes Flutter `$`-style placeholders in a web/index.html template.

    Replaces the placeholders that `flutter build web` substitutes during a
    normal Flutter web build:

        $FLUTTER_BASE_HREF       -> `base_href`
        $FLUTTER_STATIC_ASSETS_URL -> `static_assets_url` (only when set)

    Use this on a `web/index.html` produced by `flutter create` (or any
    template you author yourself) before passing it to `flutter_web_bundle`
    via `index_html`. The Tier 1 `flutter_web_app` macro invokes this
    automatically; call it directly only when composing `flutter_web_bundle`
    by hand.

    Args:
        name: Target name.
        src: Source HTML template label.
        base_href: Value substituted for `$FLUTTER_BASE_HREF`. Must start and
            end with `/` (matching `flutter build web --base-href` validation).
            Defaults to `/`.
        static_assets_url: Value substituted for `$FLUTTER_STATIC_ASSETS_URL`.
            When None (default), the placeholder is left untouched so source
            templates that don't reference it round-trip unchanged.
        **kwargs: Additional arguments (e.g. tags, visibility).
    """
    if not base_href.startswith("/") or not base_href.endswith("/"):
        fail("flutter_web_index_html_subst(name = %r): base_href must start and end with '/', got %r" % (name, base_href))

    substitutions = {"$FLUTTER_BASE_HREF": base_href}
    if static_assets_url != None:
        substitutions["$FLUTTER_STATIC_ASSETS_URL"] = static_assets_url

    expand_template(
        name = name,
        out = name + ".html",
        template = src,
        substitutions = substitutions,
        **kwargs
    )

# -- Low-level assembler (Tier 2) --------------------------------------------

def flutter_web_bundle(name, web_sdk = None, **kwargs):
    """Builds a Flutter web application (WASM or JS) with all deployment artifacts.

    This is the low-level assembler rule. For most projects, prefer
    flutter_web_app which auto-discovers runner files.

    Args:
        name: Target name.
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
            Defaults to "@flutter_web_sdk".
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    if web_sdk:
        repo = web_sdk.lstrip("@")
        kwargs["_dart2wasm_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2wasm_platform.dill" % repo)
        kwargs["_dart2js_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2js_platform.dill" % repo)
        kwargs["_web_sdk"] = Label("@%s//:web_sdk" % repo)

    _flutter_web_bundle_rule(
        name = name,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_web_app(
        name,
        package_name,
        deps,
        main = "lib/main.dart",
        app_name = None,
        base_href = "/",
        static_assets_url = None,
        web_sdk = None,
        **kwargs):
    """Builds a Flutter web application, auto-discovering runner files.

    Discovers runner files from the conventional `web/` directory
    (as generated by `flutter create --platforms=web .`) and wires up
    index.html, manifest.json, and web assets automatically.

    If no `web/index.html` exists, generates one from the built-in template.
    If no `web/manifest.json` exists, generates one from the built-in template.

    When `web/index.html` is discovered, it is processed by
    flutter_web_index_html_subst before being copied into the bundle, so
    Flutter's `$FLUTTER_BASE_HREF` and `$FLUTTER_STATIC_ASSETS_URL`
    placeholders are substituted (matching `flutter build web` behavior).
    Raw `flutter create` output works unchanged.

    This macro always uses dart2wasm + skwasm (modern defaults). For dart2js
    or canvaskit, use flutter_web_bundle directly.

    PWA support:
        By default (pwa=True), a built-in caching service worker is generated.
        For custom PWA support, provide your own `web/index.html` (with your own
        service worker registration script) and your own service worker JS file
        in the `web/` directory. These are auto-discovered via web_assets glob.
        The `pwa` attr only controls the built-in service worker; user-provided
        files are always included regardless.

    Args:
        name: Target name.
        package_name: Dart package name (same value as `pubspec.yaml`'s `name:`).
            Required: keys the web bootstrap's `package:` URI for `main` and
            anchors codegen sibling co-location.
        deps: dart_library or flutter_library dependencies.
        main: The main .dart entry point (default "lib/main.dart").
        app_name: Application name for generated HTML/manifest (defaults to name).
        base_href: Value substituted for `$FLUTTER_BASE_HREF` in
            web/index.html (default "/"). Must start and end with "/".
        static_assets_url: Value substituted for `$FLUTTER_STATIC_ASSETS_URL`
            in web/index.html. When None (default), the placeholder is left
            untouched.
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
        **kwargs: Additional arguments forwarded to flutter_web_bundle
            (e.g. assets, shaders, defines, pwa, tags, visibility).
            `extra_web_assets` is accepted here: additional web asset
            targets — typically generated files, which the `web/` glob
            cannot see — copied into the bundle root alongside the
            auto-discovered `web/` contents (the additive counterpart of
            `flutter_macos_app`'s `additional_contents`).
    """
    pwa = kwargs.pop("pwa", True)
    extra_web_assets = kwargs.pop("extra_web_assets", [])
    tags = kwargs.pop("tags", [])
    effective_app_name = app_name or name

    # Discover user-provided index.html or generate from default template.
    # User-provided templates may contain Flutter `$`-style placeholders, so
    # they go through flutter_web_index_html_subst. The generated default
    # already substitutes `$FLUTTER_BASE_HREF` itself via flutter_web_index_html_gen.
    user_index = native.glob(["web/index.html"], allow_empty = True)
    if user_index:
        flutter_web_index_html_subst(
            name = "__%s_index_html" % name,
            src = "web/index.html",
            base_href = base_href,
            static_assets_url = static_assets_url,
            tags = tags,
        )
    else:
        flutter_web_index_html_gen(
            name = "__%s_index_html" % name,
            app_name = effective_app_name,
            base_href = base_href,
            pwa = pwa,
            tags = tags,
        )
    index_html = "__%s_index_html" % name

    # Discover user-provided manifest.json or generate from template.
    user_manifest = native.glob(["web/manifest.json"], allow_empty = True)
    if user_manifest:
        manifest_json = "web/manifest.json"
    else:
        flutter_web_manifest_gen(
            name = "__%s_manifest" % name,
            app_name = effective_app_name,
            tags = tags,
        )
        manifest_json = "__%s_manifest" % name

    # Discover web assets (excluding index.html and manifest.json).
    web_assets = native.glob(
        ["web/**"],
        exclude = ["web/index.html", "web/manifest.json"],
        allow_empty = True,
    ) + extra_web_assets

    flutter_web_bundle(
        name = name,
        package_name = package_name,
        main = main,
        deps = deps,
        index_html = index_html,
        manifest_json = manifest_json,
        web_assets = web_assets,
        web_sdk = web_sdk,
        pwa = pwa,
        tags = tags,
        **kwargs
    )
