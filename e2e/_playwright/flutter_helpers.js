// @ts-check
const http = require('http');
const fs = require('fs');
const path = require('path');

const MIME_TYPES = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.png': 'image/png',
  '.otf': 'font/otf',
  '.bin': 'application/octet-stream',
};

/**
 * Create a static file server for Flutter web output with WASM CORS headers.
 * @param {string} webDir - Path to the built web output directory.
 * @returns {Promise<{server: http.Server, url: string}>}
 */
function createFlutterServer(webDir) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(webDir)) {
      reject(new Error(`Web build not found at ${webDir}. Build with bazel first.`));
      return;
    }

    const server = http.createServer((req, res) => {
      // Strip query string + fragment so cache-busting params (e.g.
      // `version.json?cachebuster=123456` from package_info_plus_web) don't
      // confuse the file lookup.
      const requestPath = req.url.split('?')[0].split('#')[0];
      let filePath = path.join(webDir, requestPath === '/' ? '/index.html' : requestPath);

      // CORS headers required for WASM SharedArrayBuffer.
      res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
      res.setHeader('Cross-Origin-Embedder-Policy', 'credentialless');

      if (!fs.existsSync(filePath)) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }

      const stat = fs.statSync(filePath);
      if (stat.isDirectory()) {
        filePath = path.join(filePath, 'index.html');
      }

      const ext = path.extname(filePath);
      const mime = MIME_TYPES[ext] || 'application/octet-stream';
      const content = fs.readFileSync(filePath);
      res.writeHead(200, { 'Content-Type': mime });
      res.end(content);
    });

    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      resolve({ server, url: `http://127.0.0.1:${port}` });
    });
  });
}

/**
 * Wait for Flutter engine to fully initialize in the page.
 *
 * Checks multiple signals that prove the engine loaded and the app started:
 * 1. `window._flutter.loader` exists (flutter.js loaded)
 * 2. Flutter accessibility elements exist (flt-semantics-placeholder or
 *    flt-announcement-host) — created after the Dart VM boots
 * 3. OR: flutter-view shadow DOM with canvas (older Flutter versions)
 *
 * Note: SkWasm uses OffscreenCanvas, so a visible `<canvas>` in the DOM is
 * not guaranteed in headless Chromium. The accessibility elements prove the
 * Dart app is running and has rendered its widget tree.
 *
 * @param {import('@playwright/test').Page} page
 * @param {number} [timeout=30000]
 */
async function waitForFlutterReady(page, timeout = 30000) {
  await page.waitForFunction(() => {
    // Check that Flutter's loader resolved.
    if (!window._flutter || !window._flutter.loader) return false;

    // Flutter creates accessibility scaffolding after the widget tree renders.
    const hasSemantics = document.querySelector('flt-semantics-placeholder') !== null;
    const hasAnnouncements = document.querySelector('flt-announcement-host') !== null;

    // Older Flutter versions: flutter-view > shadow > flt-glass-pane > shadow > canvas.
    const flutterView = document.querySelector('flutter-view');
    const hasFlutterView = flutterView && flutterView.shadowRoot &&
      flutterView.shadowRoot.querySelector('flt-glass-pane') !== null;

    return (hasSemantics || hasAnnouncements || hasFlutterView);
  }, { timeout });
}

/**
 * Collect all console messages from a page.
 * Returns an object with a messages array and helpers.
 * @param {import('@playwright/test').Page} page
 * @returns {{ messages: string[], hasUnexpectedErrors: () => boolean }}
 */
function collectConsoleMessages(page) {
  const messages = [];
  page.on('console', msg => messages.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', err => messages.push(`[pageerror] ${err.message}`));

  return {
    messages,
    /**
     * Check for unexpected errors. Filters out known Flutter WASM init traces.
     */
    hasUnexpectedErrors() {
      return messages.some(m => {
        if (!m.startsWith('[error]') && !m.startsWith('[pageerror]')) return false;
        // Flutter's normal WASM init emits bare "Error" — ignore it.
        if (m === '[error] Error' || m === '[pageerror] Error') return false;
        // CompileError during WASM fallback to JS is expected.
        if (m.includes('CompileError')) return false;
        return true;
      });
    },
  };
}

module.exports = { createFlutterServer, waitForFlutterReady, collectConsoleMessages };
