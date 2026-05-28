// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  timeout: 60000,
  use: {
    browserName: 'chromium',
    headless: true,
  },
});
