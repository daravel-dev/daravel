import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';

/// Where the Playwright suite lives in a project.
const String e2eDirectory = 'tests/e2e';

/// The files `e2e:install` writes under [e2eDirectory] (Blueprint #46).
/// [auth] adds the token specs, for projects with `/api/auth/*` routes.
Map<String, String> e2eTemplates({bool auth = true}) => {
  'package.json': _packageJson,
  'playwright.config.ts': _config,
  '.gitignore': 'node_modules/\nreport/\ntest-results/\n',
  'specs/api/health.api.spec.ts': _healthSpec,
  if (auth) 'specs/api/auth.api.spec.ts': _authSpec,
  'specs/web/welcome.spec.ts': _welcomeSpec,
};

/// A new spec named after [name] (`AuthFlow` → `auth_flow`): an API spec
/// (`specs/api/<name>.api.spec.ts`, no browser) or a browser one.
(String path, String source) e2eSpec(String name, {required bool api}) {
  final file = Naming.snake(name);
  final title = file.replaceAll('_', ' ');
  return api
      ? (
          'specs/api/$file.api.spec.ts',
          '''import { test, expect } from '@playwright/test';

// Runs in the "api" project: HTTP only, no browser.
test.describe('$title', () => {
  test('answers', async ({ request }) => {
    const res = await request.get('/api/ping');
    expect(res.status()).toBe(200);
  });
});
''',
        )
      : (
          'specs/web/$file.spec.ts',
          '''import { test, expect } from '@playwright/test';

test.describe('$title', () => {
  test('the page loads', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('h1')).toBeVisible();
  });
});
''',
        );
}

const String _packageJson = '''{
  "name": "e2e",
  "private": true,
  "scripts": {
    "test": "playwright test",
    "test:api": "playwright test --project=api",
    "report": "playwright show-report report"
  },
  "devDependencies": {
    "@playwright/test": "^1.48.0"
  }
}
''';

const String _config =
    r"""import { defineConfig, devices } from '@playwright/test';

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
""";

const String _healthSpec = r"""import { test, expect } from '@playwright/test';

test('the health check answers', async ({ request }) => {
  expect((await request.get('/up')).status()).toBe(200);
});

test('an API route answers JSON', async ({ request }) => {
  const res = await request.get('/api/ping');
  expect(res.status()).toBe(200);
  expect(await res.json()).toMatchObject({ message: 'pong' });
});

test("an unknown route answers Laravel's 404 body", async ({ request }) => {
  const res = await request.get('/api/no-such-route');
  expect(res.status()).toBe(404);
  expect(await res.json()).toHaveProperty('message');
});
""";

const String _authSpec = r"""import { test, expect } from '@playwright/test';

// Unique per run: the database outlives a run when the server is reused.
const user = {
  name: 'E2E Tester',
  email: `e2e_${Date.now()}@example.test`,
  password: 'Secret-pass-123',
  password_confirmation: 'Secret-pass-123',
};

test.describe.serial('token authentication', () => {
  let token = '';

  test('register returns the user and a token', async ({ request }) => {
    const res = await request.post('/api/auth/register', { data: user });
    expect(res.status()).toBe(201);
    const body = await res.json();
    expect(body.user.email).toBe(user.email);
    expect(body.token_type).toBe('Bearer');
    token = body.token;
  });

  test('the token opens /api/auth/me, until logout', async ({ request }) => {
    const auth = { Authorization: `Bearer ${token}` };
    const me = await request.get('/api/auth/me', { headers: auth });
    expect(me.status()).toBe(200);
    expect((await me.json()).data.email).toBe(user.email);

    const logout = await request.post('/api/auth/logout', { headers: auth });
    expect(logout.status()).toBe(204);

    const after = await request.get('/api/auth/me', { headers: auth });
    expect(after.status()).toBe(401);
  });

  test('login with the password returns a new token', async ({ request }) => {
    const res = await request.post('/api/auth/login', {
      data: { email: user.email, password: user.password },
    });
    expect(res.status()).toBe(200);
    expect((await res.json()).token).toBeTruthy();
  });
});

test("an invalid form answers Laravel's 422 body", async ({ request }) => {
  const res = await request.post('/api/auth/register', { data: {} });
  expect(res.status()).toBe(422);
  const body = await res.json();
  expect(body.message).toBeTruthy();
  expect(Object.keys(body.errors)).toEqual(
    expect.arrayContaining(['name', 'email', 'password']),
  );
});

test('login is rate limited per email', async ({ request }) => {
  const data = {
    email: `nobody_${Date.now()}@example.test`,
    password: 'wrong-password',
  };
  const statuses: number[] = [];
  for (let i = 0; i < 6; i++) {
    statuses.push((await request.post('/api/auth/login', { data })).status());
  }
  expect(statuses.slice(0, 5)).toEqual([422, 422, 422, 422, 422]);
  expect(statuses[5]).toBe(429);
});
""";

const String _welcomeSpec = r"""import { test, expect } from '@playwright/test';

test('the welcome page renders without console errors', async ({ page }) => {
  const errors: string[] = [];
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(message.text());
  });
  page.on('pageerror', (error) => errors.push(error.message));

  const response = await page.goto('/');
  expect(response?.status()).toBe(200);
  await expect(page.locator('h1')).toBeVisible();
  expect(await page.title()).not.toBe('');
  expect(errors).toEqual([]);
});

test('HTML responses carry the security headers', async ({ page }) => {
  const response = await page.goto('/');
  const headers = response!.headers();
  expect(headers['x-content-type-options']).toBe('nosniff');
  expect(headers['x-frame-options']).toBe('DENY');
  expect(headers['referrer-policy']).toBeTruthy();
});
""";

/// The project's root, the folder with `pubspec.yaml`.
String _root() => ProjectPaths.locate().root;

/// `e2e:install [--force]`: writes the Playwright suite to `tests/e2e`.
final class E2eInstallCommand extends Command<int> {
  E2eInstallCommand() {
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Overwrite files that exist.',
    );
  }

  @override
  String get name => 'e2e:install';

  @override
  String get description =>
      'Add a Playwright end-to-end suite in tests/e2e (needs Node.js).';

  @override
  Future<int> run() async {
    final root = _root();
    final routes = File(p.join(root, 'routes', 'api.dart'));
    final auth =
        routes.existsSync() &&
        routes.readAsStringSync().contains("'/auth/register'");
    final force = argResults!['force'] == true;
    var written = 0;
    for (final MapEntry(key: path, value: content) in e2eTemplates(
      auth: auth,
    ).entries) {
      final file = File(p.join(root, e2eDirectory, path));
      if (file.existsSync() && !force) {
        stdout.writeln('Kept $e2eDirectory/$path (exists; --force replaces)');
        continue;
      }
      file
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
      stdout.writeln('Created $e2eDirectory/$path');
      written++;
    }
    if (written > 0) {
      stdout.writeln(
        '\nInstall Playwright once (Node.js 20+):\n'
        '  cd $e2eDirectory && npm install && npx playwright install chromium\n'
        'Then: dartisan test:e2e --serve',
      );
    }
    return 0;
  }
}

/// `make:e2e <Name> [--api]`: a new spec in `tests/e2e/specs`.
final class MakeE2eCommand extends Command<int> {
  MakeE2eCommand() {
    argParser.addFlag(
      'api',
      negatable: false,
      help: 'An API spec (HTTP only, no browser).',
    );
  }

  @override
  String get name => 'make:e2e';

  @override
  String get description => 'Create a Playwright spec in tests/e2e/specs.';

  @override
  String get invocation => 'dartisan make:e2e <Name> [--api]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Give the spec a name: dartisan make:e2e AuthFlow');
    }
    final (path, source) = e2eSpec(rest.first, api: argResults!['api'] == true);
    final file = File(p.join(_root(), e2eDirectory, path));
    if (file.existsSync()) {
      stderr.writeln('$e2eDirectory/$path exists.');
      return 1;
    }
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
    stdout.writeln('Created $e2eDirectory/$path');
    return 0;
  }
}

/// `test:e2e [--api] [--ui] [--serve] [--url] [-- playwright args]`:
/// runs the Playwright suite.
final class TestE2eCommand extends Command<int> {
  TestE2eCommand() {
    argParser
      ..addFlag(
        'api',
        negatable: false,
        help: 'Only the API specs (*.api.spec.ts), without a browser.',
      )
      ..addFlag('ui', negatable: false, help: "Playwright's UI mode.")
      ..addFlag(
        'serve',
        negatable: false,
        help:
            'Start the application first (migrate:fresh --seed on '
            'database/e2e.sqlite, then serve); reuses one already running.',
      )
      ..addOption(
        'url',
        help: 'The application to test (APP_URL), e.g. a DDEV site.',
      )
      ..addOption(
        'port',
        defaultsTo: '8000',
        help: 'The port --serve starts the application on.',
      );
  }

  @override
  String get name => 'test:e2e';

  @override
  String get description => 'Run the Playwright end-to-end suite.';

  @override
  String get invocation => 'dartisan test:e2e [options] [-- playwright args]';

  /// The `npx` arguments for the parsed options.
  static List<String> playwrightArgs({
    bool api = false,
    bool ui = false,
    List<String> rest = const [],
  }) => [
    'playwright',
    'test',
    if (api) '--project=api',
    if (ui) '--ui',
    ...rest,
  ];

  @override
  Future<int> run() async {
    final directory = p.join(_root(), e2eDirectory);
    if (!File(p.join(directory, 'playwright.config.ts')).existsSync()) {
      stderr.writeln('No $e2eDirectory/playwright.config.ts: run e2e:install.');
      return 1;
    }
    if (!Directory(p.join(directory, 'node_modules')).existsSync()) {
      stderr.writeln(
        'Playwright is not installed. Once, with Node.js 20+:\n'
        '  cd $e2eDirectory && npm install && npx playwright install chromium',
      );
      return 1;
    }
    final r = argResults!;
    final args = playwrightArgs(
      api: r['api'] as bool,
      ui: r['ui'] as bool,
      rest: r.rest,
    );
    final url = r['url'] as String?;
    stdout.writeln('npx ${args.join(' ')}');
    try {
      final process = await Process.start(
        Platform.isWindows ? 'npx.cmd' : 'npx',
        args,
        workingDirectory: directory,
        environment: {
          'APP_URL': ?url,
          if (r['serve'] == true) 'START_SERVER': '1',
          'E2E_PORT': r['port'] as String,
        },
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows,
      );
      return await process.exitCode;
    } on ProcessException {
      stderr.writeln('npx was not found: install Node.js 20+.');
      return 1;
    }
  }
}
