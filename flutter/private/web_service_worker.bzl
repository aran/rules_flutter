"""The service worker a Flutter web bundle ships, and how it gets registered.

Flutter deprecated its caching service worker (flutter/flutter#156910). What
`flutter build web` writes today is a worker that caches nothing: it installs,
skips waiting, unregisters itself, and reloads the windows it controls. Its
only job is to tear down a *previously* installed caching worker — a visitor
who loaded an older build of the app is holding one, and nothing a new deploy
does can dislodge it except a worker that replaces and then removes it.

We ship the same thing, for the same reason: an app migrated onto these rules
from `flutter build web` has real visitors carrying Flutter's old caching
worker, and the teardown worker is what frees them.

Registration goes through `flutter.js`'s loader rather than a hand-written
`<script>` block in index.html. Passing `serviceWorkerSettings` gets three
behaviors we would otherwise have to reimplement: the registration itself,
waiting for the new worker to reach `activated`, and a timeout that gives up
and boots the app anyway. It also gates correctly — with only
`serviceWorkerVersion` set, the loader registers *only when a registration
already exists*, so a first-time visitor never gets a worker at all and the
teardown is confined to the upgrade path it exists for.
"""

def service_worker_version_for(worker_js):
    """The `?v=` value flutter.js appends to the worker's URL.

    Derived from the worker's own source, because that is the only thing the
    value is ever compared against: flutter.js asks
    `registration.active.scriptURL.endsWith(version)` to decide whether the
    worker a visitor already holds is the one this build ships.

    Upstream randomizes the version per build
    (`build_system/targets/web.dart`, `Random().nextInt(1 << 32)`), which a
    Bazel action cannot do and would not want to — an action that writes
    different bytes each run is uncacheable. Upstream needs a fresh value every
    build because its historical worker embedded the bundle's resource list, so
    the worker's content genuinely changed whenever anything did. Ours does not.

    Being honest about how much this value carries: almost nothing. The worker
    unregisters itself on activate, so a returning visitor usually has no
    registration at all and flutter.js's gate resolves before the version is
    read; and `navigator.serviceWorker.register()` revalidates the script and
    installs a byte-different worker whether or not the URL changed. The reason
    to derive it rather than hardcode it is not that the value is load-bearing
    — it is that a hardcoded one came with an instruction for a human to
    remember to bump it, and an invariant maintained by vigilance is the kind
    this codebase does not keep.

    Args:
        worker_js: The service worker source the bundle ships.

    Returns:
        A suffix-safe literal: a fixed prefix plus decimal digits. The fixed
        prefix also means no version can be a proper suffix of another, which
        `endsWith` would otherwise read as a match.
    """
    digest = hash(worker_js)
    return "rules_flutter_%d" % (digest if digest >= 0 else -digest)

# Byte-for-byte upstream's
# packages/flutter_tools/lib/src/web/file_generators/js/flutter_service_worker.js.
#
# `clients.matchAll` returns only the clients this worker controls, and a
# freshly installed worker controls none — so on a first registration the
# navigate loop is empty and nothing reloads. On an upgrade it inherits the
# clients the old caching worker held, and those are exactly the ones that need
# a reload to escape the old cache. That asymmetry is what keeps this from
# becoming a reload loop.
SERVICE_WORKER_JS = """\
'use strict';

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      try {
        await self.registration.unregister();
      } catch (e) {
        console.warn('Failed to unregister the service worker:', e);
      }

      try {
        const clients = await self.clients.matchAll({
          type: 'window',
        });
        // Reload clients to ensure they are not using the old service worker.
        clients.forEach((client) => {
          if (client.url && 'navigate' in client) {
            client.navigate(client.url);
          }
        });
      } catch (e) {
        console.warn('Failed to navigate some service worker clients:', e);
      }
    })()
  );
});
"""

SERVICE_WORKER_VERSION = service_worker_version_for(SERVICE_WORKER_JS)

def service_worker_load_args(pwa):
    """The argument `flutter_bootstrap.js` passes to `_flutter.loader.load`.

    Args:
        pwa: Whether the bundle ships a service worker.

    Returns:
        A JS object literal, or the empty string when no worker is shipped.

        The version is left as the `{{flutter_service_worker_version}}`
        placeholder for the templating pass to fill — the same built-in a
        user-supplied `web/flutter_bootstrap.js` references — so the generated
        default takes the path a copied upstream bootstrap takes rather than a
        private shortcut around it.

        Deliberately omits `serviceWorkerUrl`: setting it takes flutter.js's
        branch that both registers unconditionally — defeating the
        existing-registration gate — and logs a deprecation warning to every
        visitor's console.
    """
    if not pwa:
        return ""
    return """{
      serviceWorkerSettings: {
        serviceWorkerVersion: {{flutter_service_worker_version}}
      }
    }"""
