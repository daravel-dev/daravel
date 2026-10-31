import { defineConfig, devices } from '@playwright/test';

// The application under test: APP_URL (a DDEV site, staging), or the
// server that START_SERVER=1 starts from the project on E2E_PORT.
const port = process.env.E2E_PORT ?? '8000';
const baseURL = process.env.APP_URL ?? `http://127.0.0.1:${port}`;
// START_SERVER wipes this SQLite file, never the project's own database.
// DB_URL, set here, wins over any DB_URL or DB_* in the project's .env.
const database = process.env.E2E_DATABASE ?? 'database/e2e.sqlite';

export default defineConfig({
  testDir: './specs',
  // One worker: the specs share one server, its database and its rate
  // limits (5 registrations a minute per IP in the starter).
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { outputFolder: 'report', open: 'never' }]],
  use: {
    baseURL,
    // DDEV and other local TLS certificates.
    ignoreHTTPSErrors: true,
    extraHTTPHeaders: { Accept: 'application/json' },
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'api', testMatch: /.*\.api\.spec\.ts/ },
    {
      name: 'chromium',
      testIgnore: /.*\.api\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: process.env.START_SERVER
    ? {
        // From the project root: a fresh database, then the server.
        command:
          'dart run bin/dartisan.dart migrate:fresh --seed && dart run bin/dartisan.dart serve',
        cwd: '../..',
        url: `${baseURL}/up`,
        env: {
          ...(process.env as Record<string, string>),
          APP_ENV: 'local',
          APP_PORT: port,
          DB_CONNECTION: 'sqlite',
          DB_URL: `sqlite:${database}`,
        },
        reuseExistingServer: !process.env.CI,
        timeout: 180_000,
      }
    : undefined,
});
