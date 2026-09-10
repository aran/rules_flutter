// A user-supplied bootstrap, the customization point `flutter create`'s
// index.html comment points at. It must receive this target's build config
// and service worker version from the build, exactly as upstream's own
// default bootstrap template does.
// rules_flutter_custom_bootstrap_marker
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load({
      serviceWorkerSettings: {
        serviceWorkerVersion: {{flutter_service_worker_version}}
      }
    });
  });
  document.head.appendChild(script);
}
