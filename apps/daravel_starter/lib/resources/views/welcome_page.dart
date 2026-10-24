import 'dart:convert';

import 'logo_data.dart';

/// Renders the welcome landing page served at `/`.
///
/// Views are plain Dart until the Blade-compatible compiler lands (ADR-018).
/// Every dynamic value passes through [escape] so the page is XSS-safe.
String welcomePage({
  required String appName,
  required String environment,
  required String dartVersion,
  required String frameworkVersion,
  required String requestId,
}) {
  final name = escape(appName);
  return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name</title>
<link rel="icon" type="image/png" href="$faviconDataUri">
<style>
  :root {
    --bg: #0b0d12; --panel: #12151c; --panel-2: #171b24; --line: #232936;
    --text: #e6e8ee; --muted: #9aa3b5; --accent: #ff2d20; --accent-2: #ff6a5c;
    --ok: #22c55e; --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg: #f7f7f8; --panel: #ffffff; --panel-2: #f1f2f5; --line: #e4e6ea;
            --text: #16181d; --muted: #5f6675; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 16px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  .glow { position: fixed; inset: -40% -20% auto; height: 70vh; pointer-events: none;
          background: radial-gradient(60% 60% at 50% 40%, rgba(255,45,32,.18), transparent 70%); }
  main { position: relative; max-width: 1040px; margin: 0 auto; padding: 72px 24px 48px; }
  header { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  .brand { display: flex; align-items: center; gap: 12px; font-weight: 700; font-size: 20px; letter-spacing: .2px; }
  .mark { width: 40px; height: 40px; display: grid; place-items: center; }
  .mark img { width: 40px; height: 40px; border-radius: 9px; box-shadow: 0 6px 18px rgba(1,117,194,.25); }
  .env { font-family: var(--mono); font-size: 12px; color: var(--muted); border: 1px solid var(--line);
         border-radius: 999px; padding: 6px 12px; display: inline-flex; gap: 8px; align-items: center; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); box-shadow: 0 0 0 4px rgba(34,197,94,.15); }
  h1 { font-size: clamp(36px, 6vw, 60px); line-height: 1.05; margin: 64px 0 16px; letter-spacing: -.02em; }
  h1 span { background: linear-gradient(90deg, var(--accent), var(--accent-2)); -webkit-background-clip: text; background-clip: text; color: transparent; }
  .lead { color: var(--muted); font-size: 18px; max-width: 640px; margin: 0 0 40px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
  a.card { display: block; text-decoration: none; color: inherit; background: var(--panel);
           border: 1px solid var(--line); border-radius: 16px; padding: 22px;
           transition: transform .15s ease, border-color .15s ease; }
  a.card:hover { transform: translateY(-2px); border-color: var(--accent); }
  .card h2 { font-size: 17px; margin: 0 0 6px; }
  .card p { margin: 0; color: var(--muted); font-size: 14px; }
  .card code { font-family: var(--mono); font-size: 13px; color: var(--accent-2); }
  .term { margin-top: 32px; background: var(--panel-2); border: 1px solid var(--line); border-radius: 16px;
          padding: 18px 22px; font-family: var(--mono); font-size: 13.5px; overflow-x: auto; }
  .term .c { color: var(--muted); }
  footer { margin-top: 40px; display: flex; flex-wrap: wrap; gap: 8px 24px; color: var(--muted);
           font-size: 13px; font-family: var(--mono); }
</style>
</head>
<body>
<div class="glow"></div>
<main>
  <header>
    <div class="brand"><div class="mark"><img src="$logoDataUri" alt="Daravel logo" width="40" height="40"></div>$name</div>
    <div class="env"><span class="dot"></span>${escape(environment)} &middot; request ${escape(requestId)}</div>
  </header>

  <h1>The Laravel experience,<br><span>compiled to native Dart.</span></h1>
  <p class="lead">Your application is up and serving from a single AOT binary. Start by exploring the
  API, reading the blueprints, or scaffolding your first endpoint with <code>dartisan</code>.</p>

  <div class="grid">
    <a class="card" href="/api/ping">
      <h2>API playground</h2>
      <p>Hit <code>GET /api/ping</code> and <code>GET /up</code> to see JSON responses with request ids.</p>
    </a>
    <a class="card" href="https://github.com/daravel-dev/daravel/blob/main/docs/guide/index.md">
      <h2>Documentation</h2>
      <p>Guides for routing, validation, the ORM, auth, queues, testing and deployment.</p>
    </a>
    <a class="card" href="https://github.com/daravel-dev/daravel/blob/main/docs/guide/parity.md">
      <h2>Laravel &harr; Daravel</h2>
      <p>Side-by-side comparison of routing, validation, migrations and tests.</p>
    </a>
    <a class="card" href="https://github.com/daravel-dev/daravel">
      <h2>Source on GitHub</h2>
      <p>Framework core, <code>dartisan</code> CLI, testing toolkit and this starter.</p>
    </a>
  </div>

  <div class="term">
<span class="c"># next steps</span><br>
dart run bin/dartisan.dart route:list<br>
dart run bin/dartisan.dart migrate<br>
dart run bin/dartisan.dart build<span class="c"> &nbsp;# ship a native bundle</span>
  </div>

  <footer>
    <span>Daravel ${escape(frameworkVersion)}</span>
    <span>Dart ${escape(dartVersion)}</span>
    <span>APP_ENV=${escape(environment)}</span>
  </footer>
</main>
</body>
</html>
''';
}

/// HTML-escapes [value] (same character set as Laravel's `e()` helper).
String escape(String value) =>
    const HtmlEscape(HtmlEscapeMode.element)
        .convert(value)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
