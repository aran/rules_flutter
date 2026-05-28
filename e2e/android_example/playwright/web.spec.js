// @ts-check
const { test, expect } = require('@playwright/test');
const path = require('path');
const { createFlutterServer, waitForFlutterReady, collectConsoleMessages } = require('../../_playwright/flutter_helpers');

const WEB_DIR = path.resolve(__dirname, '../bazel-bin/app_web_web');
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
  expect(title).toContain('Android Example');
});
