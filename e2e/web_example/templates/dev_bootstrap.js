// A user-supplied bootstrap whose `web_defines` value has to reach the page.
//
// Lives outside `web/` on purpose: the `web/` glob of this package feeds every
// Tier 1 target in it, so a `web/flutter_bootstrap.js` here would silently
// become the bootstrap of all of them. Only `:app_dev_boot` names this file.
//
// `rulesFlutterApiUrl` is what a `-d chrome` run is asserted on. It reaches the
// browser only if the dev loop serves this template, substituted — a dev loop
// that writes a bootstrap of its own leaves the global undefined while the
// built bundle carries the value, which is exactly the split this target
// exists to catch.
window.rulesFlutterApiUrl = "{{API_URL}}";

{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function () {
    _flutter.loader.load({
      serviceWorkerSettings: {
        serviceWorkerVersion: {{flutter_service_worker_version}}
      }
    });
  });
  document.head.appendChild(script);
}
