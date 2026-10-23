import 'dart:convert';

/// Inline brand mark (also used as favicon). Source: docs/logo.svg
const String logoSvg =
    '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" role="img" aria-label="Daravel logo"> <defs> <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1"> <stop offset="0" stop-color="#0f172a"/> <stop offset="1" stop-color="#1e293b"/> </linearGradient> <linearGradient id="dart" x1="0" y1="0" x2="1" y2="1"> <stop offset="0" stop-color="#13b9fd"/> <stop offset="1" stop-color="#0175c2"/> </linearGradient> <linearGradient id="laravel" x1="0" y1="0" x2="1" y2="1"> <stop offset="0" stop-color="#ff6a5c"/> <stop offset="1" stop-color="#ff2d20"/> </linearGradient> </defs> <rect width="64" height="64" rx="14" fill="url(#tile)"/> <path d="M11 21 L23 15 L23 35 L36 41.5 L36 50 L11 37.5 Z" fill="url(#laravel)"/> <path d="M23 15 L29.5 18.3 L29.5 38.2 L23 35 Z" fill="#b9170e"/> <path d="M11 21 L23 27 L23 35 L11 29 Z" fill="#d9231a"/> <path d="M16 45 L30 40.5 L27.5 49.5 Z" fill="#0175c2"/> <path d="M19 49 L29 43.5 L29.5 51 Z" fill="#13b9fd" opacity=".85"/> <ellipse cx="37" cy="37" rx="13" ry="10.5" fill="url(#dart)"/> <ellipse cx="39.5" cy="41" rx="6.5" ry="4" fill="#ffffff" opacity=".22"/> <circle cx="45.5" cy="24.5" r="8.2" fill="#13b9fd"/> <path d="M52 22.5 L63 19.5 L53 27.2 Z" fill="url(#laravel)"/> <circle cx="47.6" cy="23.6" r="2.5" fill="#ffffff"/> <circle cx="48.2" cy="23.8" r="1.25" fill="#0f172a"/> <path d="M40.5 18.5 L43.5 13 L45.5 17.5 Z" fill="#0175c2"/> </svg>''';

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
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,${Uri.encodeComponent(logoSvg)}">
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
  .mark svg { width: 40px; height: 40px; border-radius: 11px; box-shadow: 0 6px 18px rgba(1,117,194,.25); }
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
    <div class="brand"><div class="mark">$logoSvg</div>$name</div>
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
    <a class="card" href="https://github.com/teoprayoga/daravel/blob/main/BLUEPRINT_V2.md">
      <h2>Blueprints</h2>
      <p>Architecture, ADRs and the slice-by-slice roadmap from Tier 0 to 1.0.</p>
    </a>
    <a class="card" href="https://github.com/teoprayoga/daravel#laravel--daravel-at-a-glance">
      <h2>Laravel &harr; Daravel</h2>
      <p>Side-by-side comparison of routing, validation, migrations and tests.</p>
    </a>
    <a class="card" href="https://github.com/teoprayoga/daravel">
      <h2>Source on GitHub</h2>
      <p>Framework core, <code>dartisan</code> CLI, testing toolkit and this starter.</p>
    </a>
  </div>

  <div class="term">
<span class="c"># next steps</span><br>
dart run bin/dartisan.dart route:list<br>
dart run bin/dartisan.dart migrate<br>
dart compile exe bin/server.dart -o build/server<span class="c"> &nbsp;# ship a native binary</span>
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
String escape(String value) => const HtmlEscape(
  HtmlEscapeMode.element,
).convert(value).replaceAll('"', '&quot;').replaceAll("'", '&#39;');
