// @ts-check
const { test, expect } = require('@playwright/test');
const path = require('path');
const { createFlutterServer, waitForFlutterReady, collectConsoleMessages } = require('../../_playwright/flutter_helpers');

const WEB_DIR = path.resolve(__dirname, '../bazel-bin/plugin_web_web');
let server;
let serverUrl;

test.beforeAll(async () => {
  const result = await createFlutterServer(WEB_DIR);
  server = result.server;
  serverUrl = result.url;
});

test.afterAll(async () => {
  if (server) server.close();
});

test('Flutter engine initializes and renders', async ({ page }) => {
  const console_ = collectConsoleMessages(page);
  await page.goto(serverUrl, { waitUntil: 'networkidle' });

  try {
    await waitForFlutterReady(page);
  } catch (e) {
    console.log('Console messages:', console_.messages.join('\n'));
    console.log('Page HTML:', (await page.content()).substring(0, 2000));
    throw e;
  }

  console.log('Console messages:', console_.messages.join('\n'));
  expect(console_.hasUnexpectedErrors()).toBe(false);
});

test('Page title is set correctly', async ({ page }) => {
  await page.goto(serverUrl, { waitUntil: 'networkidle' });
  const title = await page.title();
  expect(title).toContain('Plugin Example');
});

test('Plugin results render correctly', async ({ page }) => {
  const console_ = collectConsoleMessages(page);
  await page.goto(serverUrl, { waitUntil: 'networkidle' });
  await waitForFlutterReady(page);

  // The app emits exactly one line containing all four plugin results once
  // its FutureBuilder resolves. Wait for the line to appear in console; the
  // resolution is async (it awaits PackageInfo.fromPlatform, getApplication-
  // DocumentsDirectory, etc.) so polling is needed.
  const deadline = Date.now() + 30_000;
  let summary;
  while (Date.now() < deadline) {
    summary = console_.messages.find((m) => m.includes('plugin_example_results'));
    if (summary) break;
    await page.waitForTimeout(250);
  }

  if (!summary) {
    console.log('Console messages:', console_.messages.join('\n'));
    throw new Error('plugin_example_results summary never emitted');
  }

  // appName comes from PackageInfo.fromPlatform — fails loudly if the web
  // pluginClass for package_info_plus didn't register. The web plugin reads
  // version.json for the app_name field; we set package_name = "plugin_example"
  // on the flutter_web_bundle, which feeds the generated version.json.
  expect(summary).toContain('appName=plugin_example');

  // documentsPath / tempPath are kIsWeb-guarded — web shows the documented
  // fallback string. If the guard's path leaks through (e.g. an error from
  // an attempt to actually call getApplicationDocumentsDirectory), the
  // assertion fails.
  expect(summary).toContain('documentsPath=web: not supported');
  expect(summary).toContain('tempPath=web: not supported');

  // launchOk comes from canLaunchUrl — fails loudly if url_launcher_web's
  // pluginClass didn't register.
  expect(summary).toContain('launchOk=launch ok');

  // greeting comes from the hand-written //greeting_plugin (regression case
  // for pure-Bazel-deps plugins). Should resolve to the message its
  // registerWith sets.
  expect(summary).toContain('greeting=Hello from GreetingPlugin!');

  // audio_session has no web implementation — the kIsWeb guard surfaces a
  // sentinel. Also ensures the dart-side import resolves cleanly on web
  // even though the macOS / iOS pipeline is what exercises the SwiftPM
  // include-path wiring.
  expect(summary).toContain('audioSession=web: not supported');
});
