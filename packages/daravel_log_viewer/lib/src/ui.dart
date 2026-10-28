import 'dart:convert';

import 'config.dart';

/// The log viewer's page: one HTML document with its CSS and script
/// inline (allowed by a per-response CSP nonce), no external assets. Log
/// text is only ever set as `textContent`, never parsed as HTML.
String logViewerPage({
  required String base,
  required String nonce,
  required LogViewerConfig config,
}) {
  final attr = const HtmlEscape(HtmlEscapeMode.attribute).convert(base);
  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Logs · Daravel</title>
<style nonce="$nonce">
:root{--bg:#f6f7f9;--panel:#fff;--fg:#1c2330;--muted:#677184;--line:#e1e4ea;--accent:#c2410c;--soft:#f1f3f6;
--emergency:#7f1d1d;--alert:#991b1b;--critical:#b91c1c;--error:#c2410c;--warning:#a16207;--notice:#0e7490;--info:#1d4ed8;--debug:#6b7280;--unknown:#6b7280;
--mono:ui-monospace,"Cascadia Mono","JetBrains Mono",Menlo,Consolas,monospace;--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#0f1318;--panel:#161b22;--fg:#e4e8ee;--muted:#8b95a6;--line:#262d38;--accent:#fb923c;--soft:#1d232c;
--emergency:#fca5a5;--alert:#fca5a5;--critical:#f87171;--error:#fb923c;--warning:#facc15;--notice:#67e8f9;--info:#93c5fd;--debug:#9ca3af;--unknown:#9ca3af}}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 var(--sans);display:grid;grid-template-rows:auto 1fr;grid-template-columns:minmax(0,1fr)}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel)}
header h1{font-size:15px;margin:0;font-weight:650;letter-spacing:.01em}
header .file{font-family:var(--mono);color:var(--muted);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1}
header .grow{flex:0}
main{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:0}
aside{border-right:1px solid var(--line);overflow:auto;background:var(--panel)}
aside h2,.toolbar label{font:600 11px/1 var(--sans);text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
aside h2{margin:14px 16px 8px}
.files button{display:grid;grid-template-columns:1fr auto;gap:2px 8px;width:100%;text-align:left;padding:8px 16px;border:0;border-left:3px solid transparent;background:none;color:inherit;cursor:pointer;font:inherit}
.files button:hover{background:var(--soft)}.files button[aria-current=true]{border-left-color:var(--accent);background:var(--soft)}
.files .name{font-family:var(--mono);font-size:12.5px;overflow:hidden;text-overflow:ellipsis}
.files .meta{grid-column:1/-1;color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
section{display:grid;grid-template-rows:auto 1fr;min-height:0;min-width:0}
#levels{display:flex;flex-wrap:wrap;gap:4px;min-width:0}
.toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel)}
.chip{border:1px solid var(--line);background:var(--panel);color:var(--muted);border-radius:999px;padding:3px 10px;font:600 12px/1.4 var(--sans);cursor:pointer}
.chip[aria-pressed=true]{color:var(--panel);border-color:transparent}
input[type=search]{flex:1;min-width:180px;border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:6px;padding:6px 10px;font:inherit}
.btn{border:1px solid var(--line);background:var(--panel);color:var(--fg);border-radius:6px;padding:5px 10px;font:inherit;cursor:pointer}
.btn:hover{background:var(--soft)}.btn.danger{color:var(--critical)}
.btn:focus-visible,.chip:focus-visible,.files button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.live[aria-pressed=true]{border-color:var(--accent);color:var(--accent)}
.live[aria-pressed=true]::before{content:"";display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--accent);margin-right:6px;vertical-align:1px;animation:pulse 1.4s infinite}
@keyframes pulse{50%{opacity:.25}}@media (prefers-reduced-motion:reduce){.live[aria-pressed=true]::before{animation:none}}
#list{overflow:auto;padding:8px 0}
.entry{border-bottom:1px solid var(--line);padding:6px 16px}
.entry summary{display:grid;grid-template-columns:auto auto minmax(0,1fr);gap:10px;align-items:baseline;cursor:pointer;list-style:none}
.entry summary::-webkit-details-marker{display:none}
.time{font-family:var(--mono);font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.level{font:700 10.5px/1 var(--sans);text-transform:uppercase;letter-spacing:.06em;padding:3px 6px;border-radius:4px;color:var(--panel);min-width:66px;text-align:center}
.msg{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.entry[open] .msg{white-space:normal;word-break:break-word}
.detail{margin:8px 0 6px;display:grid;gap:8px}
.detail h3{margin:0;font:600 11px/1 var(--sans);text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
pre{margin:0;padding:10px 12px;background:var(--soft);border-radius:6px;overflow:auto;font:12.5px/1.55 var(--mono);white-space:pre}
.frame.app{color:var(--fg);font-weight:600}.frame.vendor{color:var(--muted)}
.fresh{animation:fresh 1.6s ease-out}@keyframes fresh{from{background:color-mix(in srgb,var(--accent) 18%,transparent)}}
.empty,.more{padding:24px 16px;color:var(--muted);text-align:center}
.status{color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
@media (max-width:760px){main{grid-template-columns:minmax(0,1fr);grid-template-rows:auto 1fr}aside{max-height:24vh;border-right:0;border-bottom:1px solid var(--line)}.entry summary{grid-template-columns:auto minmax(0,1fr)}.entry .time{grid-column:1/-1}.toolbar{padding:10px 12px}input[type=search]{min-width:0;flex-basis:100%}}
</style>
</head>
<body data-base="$attr" data-download="${config.allowDownload}" data-delete="${config.allowDelete}">
<header><h1>Logs</h1><span class="file" id="current"></span><span class="grow"></span>
<button class="btn" id="download" hidden>Download</button><button class="btn danger" id="delete" hidden>Delete</button></header>
<main>
<aside><h2>Files</h2><nav class="files" id="files" aria-label="Log files"></nav></aside>
<section>
<div class="toolbar">
<div id="levels" role="group" aria-label="Levels"></div>
<input type="search" id="search" placeholder="Search messages, request ids, exceptions" aria-label="Search">
<button class="btn live" id="live" aria-pressed="false">Live</button>
<span class="status" id="status" aria-live="polite"></span>
</div>
<div id="list"></div>
</section>
</main>
<script nonce="$nonce">
(() => {
'use strict';
const base = document.body.dataset.base;
const levels = ['emergency','alert','critical','error','warning','notice','info','debug'];
const state = {file: new URLSearchParams(location.search).get('file'), next: null, levels: new Set(), search: '', source: null};
const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
const qs = (params) => new URLSearchParams(Object.entries(params).filter(([, v]) => v != null && v !== '')).toString();
const size = (n) => n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(1) + ' KB' : (n / 1048576).toFixed(1) + ' MB';
const byId = (id) => document.getElementById(id);

for (const level of levels) {
  const chip = el('button', 'chip', level);
  chip.setAttribute('aria-pressed', 'false');
  chip.addEventListener('click', () => {
    const on = !state.levels.has(level);
    on ? state.levels.add(level) : state.levels.delete(level);
    chip.setAttribute('aria-pressed', String(on));
    chip.style.background = on ? 'var(--' + level + ')' : '';
    reload();
  });
  byId('levels').append(chip);
}
let typing;
byId('search').addEventListener('input', (e) => { clearTimeout(typing); typing = setTimeout(() => { state.search = e.target.value.trim(); reload(); }, 300); });
byId('live').addEventListener('click', () => setLive(byId('live').getAttribute('aria-pressed') !== 'true'));
byId('download').addEventListener('click', () => { location.href = base + '/api/download?' + qs({file: state.file}); });
byId('delete').addEventListener('click', async () => {
  if (!state.file || !window.confirm('Delete ' + state.file + '?')) return;
  const r = await fetch(base + '/api/files?' + qs({file: state.file}), {method: 'DELETE'});
  if (r.ok) { state.file = null; loadFiles(); } else { status('Delete failed (' + r.status + ')'); }
});

function status(text) { byId('status').textContent = text; }

async function api(path) {
  const r = await fetch(base + path, {headers: {accept: 'application/json'}});
  if (!r.ok) throw new Error(r.status === 403 ? 'Not allowed (403)' : 'Request failed (' + r.status + ')');
  return r.json();
}

async function loadFiles() {
  try {
    const data = await api('/api/files');
    const nav = byId('files'); nav.replaceChildren();
    if (!data.files.length) { nav.append(el('p', 'empty', 'No log files yet.')); byId('list').replaceChildren(el('p', 'empty', 'Nothing logged yet.')); return; }
    for (const f of data.files) {
      const b = el('button');
      b.append(el('span', 'name', f.name), el('span', 'meta', size(f.size) + ' · ' + new Date(f.modified).toLocaleString()));
      b.addEventListener('click', () => select(f.name));
      b.dataset.name = f.name;
      nav.append(b);
    }
    byId('download').hidden = !data.allow_download;
    byId('delete').hidden = !data.allow_delete;
    select(state.file && data.files.some((f) => f.name === state.file) ? state.file : data.files[0].name);
  } catch (e) { status(e.message); }
}

function select(name) {
  state.file = name;
  byId('current').textContent = name;
  history.replaceState(null, '', '?' + qs({file: name}));
  for (const b of byId('files').querySelectorAll('button')) b.setAttribute('aria-current', String(b.dataset.name === name));
  reload();
}

async function reload() {
  state.next = null;
  byId('list').replaceChildren();
  await page();
  if (byId('live').getAttribute('aria-pressed') === 'true') setLive(true);
}

async function page() {
  status('Loading…');
  try {
    const data = await api('/api/entries?' + qs({file: state.file, before: state.next, levels: [...state.levels].join(','), search: state.search}));
    const list = byId('list');
    list.querySelector('.more')?.remove();
    for (const entry of data.entries) list.append(render(entry, false));
    if (!list.querySelector('.entry')) list.append(el('p', 'empty', 'No entries match.'));
    state.next = data.next;
    state.size = data.size;
    if (data.next != null) {
      const more = el('button', 'btn more', 'Older entries');
      more.addEventListener('click', page);
      const wrap = el('div', 'more'); wrap.append(more); list.append(wrap);
    }
    status(data.entries.length + (data.entries.length === 1 ? ' entry' : ' entries') + ' · ' + size(data.size));
  } catch (e) { status(e.message); }
}

function setLive(on) {
  byId('live').setAttribute('aria-pressed', String(on));
  state.source?.close(); state.source = null;
  if (!on || !state.file) return;
  const source = new EventSource(base + '/api/tail?' + qs({file: state.file, levels: [...state.levels].join(','), search: state.search}));
  source.addEventListener('entry', (e) => {
    const list = byId('list');
    list.querySelector('.empty')?.remove();
    list.prepend(render(JSON.parse(e.data), true));
  });
  source.onerror = () => status('Live tail reconnecting…');
  state.source = source;
}

function render(entry, fresh) {
  const d = el('details', 'entry' + (fresh ? ' fresh' : ''));
  const s = el('summary');
  const badge = el('span', 'level', entry.level);
  badge.style.background = 'var(--' + (levels.includes(entry.level) ? entry.level : 'unknown') + ')';
  s.append(el('span', 'time', entry.time || ''), badge, el('span', 'msg', entry.message || ''));
  d.append(s);
  d.addEventListener('toggle', () => {
    if (!d.open || d.querySelector('.detail')) return;
    const box = el('div', 'detail');
    if (entry.channel) box.append(el('h3', null, 'Channel ' + entry.channel));
    if (entry.context != null && !(typeof entry.context === 'object' && Object.keys(entry.context).length === 0)) {
      box.append(el('h3', null, 'Context'), el('pre', null, JSON.stringify(entry.context, null, 2)));
    }
    if (entry.error) box.append(el('h3', null, 'Error'), el('pre', null, entry.error));
    if (entry.trace) {
      const pre = el('pre');
      for (const line of entry.trace.split('\\n')) {
        const vendor = /(dart:|package:daravel[a-z_]*\\/|vendor\\/|<asynchronous suspension>)/.test(line);
        pre.append(el('div', 'frame ' + (vendor ? 'vendor' : 'app'), line));
      }
      box.append(el('h3', null, 'Stack trace'), pre);
    }
    d.append(box);
  });
  return d;
}

loadFiles();
})();
</script>
</body>
</html>
''';
}
