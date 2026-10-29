import 'dart:convert';

/// The dashboard: one HTML document with its CSS and script inline
/// (allowed by a per-response CSP nonce), no external assets. Recorded
/// text (SQL, exception messages, traces) is only ever set as
/// `textContent`, never parsed as HTML.
String pulsePage({required String base, required String nonce}) {
  final attr = const HtmlEscape(HtmlEscapeMode.attribute).convert(base);
  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Pulse · Daravel</title>
<style nonce="$nonce">
:root{--bg:#f6f7f9;--panel:#fff;--fg:#1c2330;--muted:#677184;--line:#e1e4ea;--soft:#f1f3f6;--accent:#c2410c;--bar:#94a3b8;--err:#b91c1c;--slow:#a16207;--ok:#15803d;
--mono:ui-monospace,"Cascadia Mono","JetBrains Mono",Menlo,Consolas,monospace;--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#0f1318;--panel:#161b22;--fg:#e4e8ee;--muted:#8b95a6;--line:#262d38;--soft:#1d232c;--accent:#fb923c;--bar:#64748b;--err:#f87171;--slow:#facc15;--ok:#4ade80}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 var(--sans)}
header{display:flex;flex-wrap:wrap;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel);position:sticky;top:0;z-index:1}
header h1{font-size:15px;margin:0;font-weight:650}
.grow{flex:1}.status{color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
.periods{display:flex;gap:4px}
.chip{border:1px solid var(--line);background:var(--panel);color:var(--muted);border-radius:999px;padding:3px 10px;font:600 12px/1.4 var(--sans);cursor:pointer}
.chip[aria-pressed=true]{color:var(--panel);background:var(--accent);border-color:transparent}
.chip:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
main{display:grid;gap:16px;padding:16px;grid-template-columns:repeat(12,minmax(0,1fr));max-width:1400px;margin:0 auto}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px;min-width:0;grid-column:span 6}
.card.wide{grid-column:1/-1}.card.third{grid-column:span 4}
.card h2{margin:0 0 10px;font:600 11px/1 var(--sans);text-transform:uppercase;letter-spacing:.07em;color:var(--muted);display:flex;gap:8px}
.card h2 .note{text-transform:none;letter-spacing:0;font-weight:400}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px}
.stat .v{font-size:24px;font-weight:650;font-variant-numeric:tabular-nums;line-height:1.2}
.stat .l{color:var(--muted);font-size:12px}
.stat.err .v{color:var(--err)}.stat.slow .v{color:var(--slow)}
svg.chart{width:100%;height:120px;display:block;margin-top:12px}
svg .req{fill:var(--bar)}svg .e{fill:var(--err)}
table{width:100%;border-collapse:collapse;font-size:13px}
th{font:600 11px/1 var(--sans);text-transform:uppercase;letter-spacing:.06em;color:var(--muted);text-align:left;padding:6px 8px;border-bottom:1px solid var(--line)}
td{padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.code{font-family:var(--mono);font-size:12.5px;word-break:break-word}
.sub{color:var(--muted);font-size:12px}
.badge{font:700 10.5px/1 var(--sans);padding:3px 6px;border-radius:4px;background:var(--soft);color:var(--muted)}
.badge.err{color:var(--err)}
details summary{cursor:pointer;list-style:none}details summary::-webkit-details-marker{display:none}
pre{margin:8px 0 0;padding:10px 12px;background:var(--soft);border-radius:6px;overflow:auto;font:12px/1.55 var(--mono);white-space:pre}
.empty{color:var(--muted);padding:12px 0;text-align:center}
@media (max-width:900px){.card,.card.third{grid-column:1/-1}main{padding:12px}}
</style>
</head>
<body data-base="$attr">
<header><h1>Pulse</h1>
<div class="periods" role="group" aria-label="Period">
<button class="chip" data-period="1h" aria-pressed="true">1 hour</button>
<button class="chip" data-period="6h" aria-pressed="false">6 hours</button>
<button class="chip" data-period="24h" aria-pressed="false">24 hours</button>
</div><span class="grow"></span><span class="status" id="status" aria-live="polite"></span></header>
<main>
<section class="card wide"><h2>Requests</h2><div class="stats" id="overview"></div><svg class="chart" id="chart" viewBox="0 0 600 120" preserveAspectRatio="none" role="img" aria-label="Requests over time"></svg></section>
<section class="card"><h2>Slow requests <span class="note" id="t-requests"></span></h2><div id="requests"></div></section>
<section class="card"><h2>Slow queries <span class="note" id="t-queries"></span></h2><div id="queries"></div></section>
<section class="card wide"><h2>Exceptions</h2><div id="exceptions"></div></section>
<section class="card third"><h2>Queues</h2><div id="queues"></div></section>
<section class="card third"><h2>Slow and failed jobs <span class="note" id="t-jobs"></span></h2><div id="jobs"></div></section>
<section class="card third"><h2>Failed jobs</h2><div id="failed"></div></section>
<section class="card wide"><h2>Workers</h2><div id="workers"></div></section>
</main>
<script nonce="$nonce">
(()=>{
const base=document.body.dataset.base;let period='1h';let timer=null;
const el=(tag,cls,text)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=String(text);return e;};
const fmt=n=>n==null?'–':Number(n).toLocaleString();
const ms=n=>n==null?'–':(n>=1000?(n/1000).toFixed(2)+' s':Math.round(n)+' ms');
const ago=t=>{const s=Math.max(0,Math.round((Date.now()-t)/1000));return s<60?s+' s ago':s<3600?Math.round(s/60)+' min ago':Math.round(s/3600)+' h ago';};
const bytes=b=>b==null?'–':(b/1048576).toFixed(0)+' MB';
function table(target,cols,rows,empty){const box=document.getElementById(target);box.replaceChildren();
if(!rows.length){box.append(el('div','empty',empty));return;}
const t=el('table'),h=el('tr');for(const c of cols){h.append(el('th',c.n?'n':'',c.label));}const hd=el('thead');hd.append(h);t.append(hd);
const b=el('tbody');for(const r of rows){const tr=el('tr');for(const c of cols){const td=el('td',c.n?'n':'');const v=c.cell(r);if(v instanceof Node)td.append(v);else td.textContent=v;tr.append(td);}b.append(tr);}t.append(b);box.append(t);}
function two(main,sub,code){const d=el('div');d.append(el('div',code?'code':'',main));if(sub)d.append(el('div','sub',sub));return d;}
function chart(series){const svg=document.getElementById('chart');svg.replaceChildren();const max=Math.max(1,...series.map(p=>p[1]));const w=600/series.length;
const ns='http://www.w3.org/2000/svg';series.forEach((p,i)=>{const h=p[1]/max*116;const r=document.createElementNS(ns,'rect');r.setAttribute('class','req');r.setAttribute('x',i*w+1);r.setAttribute('width',w-2);r.setAttribute('y',120-h);r.setAttribute('height',h);
const t=document.createElementNS(ns,'title');t.textContent=new Date(p[0]).toLocaleTimeString()+': '+p[1]+' requests, '+p[2]+' errors, '+p[3]+' slow';r.append(t);svg.append(r);
if(p[2]){const eh=p[2]/max*116;const e=document.createElementNS(ns,'rect');e.setAttribute('class','e');e.setAttribute('x',i*w+1);e.setAttribute('width',w-2);e.setAttribute('y',120-eh);e.setAttribute('height',eh);svg.append(e);}});}
function render(d){const r=d.requests;const o=document.getElementById('overview');o.replaceChildren();
for(const [v,l,c] of [[fmt(r.total),'requests',''],[fmt(r.errors),'server errors','err'],[fmt(r.slow),'slow','slow'],[ms(r.avg_ms),'average',''],[bytes(d.memory_bytes),'memory',''],[fmt(d.workers.length),d.workers.length===1?'isolate':'isolates','']]){const s=el('div','stat '+c);s.append(el('div','v',v),el('div','l',l));o.append(s);}
chart(r.series);
const th=d.thresholds;for(const k of ['requests','queries','jobs'])document.getElementById('t-'+k).textContent='≥ '+ms(th[k+'_ms']);
table('requests',[{label:'Route',cell:x=>two(x.route,x.method+' · last '+ago(x.last_at),true)},{label:'Count',n:1,cell:x=>fmt(x.count)},{label:'Slowest',n:1,cell:x=>ms(x.max_ms)}],d.slow_requests,'No slow requests.');
table('queries',[{label:'Query',cell:x=>two(x.sql,x.connection+' · last '+ago(x.last_at),true)},{label:'Count',n:1,cell:x=>fmt(x.count)},{label:'Slowest',n:1,cell:x=>ms(x.max_ms)}],d.slow_queries,'No slow queries.');
table('exceptions',[{label:'Exception',cell:x=>{const det=el('details'),s=el('summary');s.append(two(x.class+': '+x.message,x.location+' · last '+ago(x.last_at),false));det.append(s,el('pre','',x.trace));return det;}},{label:'Count',n:1,cell:x=>fmt(x.count)}],d.exceptions,'No exceptions.');
table('queues',[{label:'Queue',cell:x=>two(x.queue,x.connection)},{label:'Pending',n:1,cell:x=>fmt(x.size)}],d.queues,'No queues.');
table('jobs',[{label:'Job',cell:x=>{const d2=two(x.job,x.queue+' · last '+ago(x.last_at),true);if(x.failed){d2.append(el('span','badge err',x.failed+' failed'));}return d2;}},{label:'Slowest',n:1,cell:x=>ms(x.max_ms)}],d.jobs,'No slow or failed jobs.');
const f=d.failed_jobs;table('failed',[{label:(f.count==null?'?':f.count)+' in period',cell:x=>two(x.job,x.queue+' · '+ago(x.failed_at)+' · '+x.exception,false)}],f.recent,f.count==null?'failed_jobs could not be read.':'No failed jobs.');
table('workers',[{label:'Isolate',cell:x=>two(x.name,'up since '+new Date(x.started_at).toLocaleString(),true)},{label:'Requests',n:1,cell:x=>fmt(x.requests_total)},{label:'In flight',n:1,cell:x=>fmt(x.in_flight)},{label:'Reported',n:1,cell:x=>ago(x.reported_at)}],d.workers,'No isolates reported yet.');}
async function load(){const status=document.getElementById('status');
try{const res=await fetch(base+'/api/stats?period='+encodeURIComponent(period),{headers:{accept:'application/json'},credentials:'same-origin'});
if(!res.ok)throw new Error('HTTP '+res.status);render(await res.json());status.textContent='Updated '+new Date().toLocaleTimeString();}
catch(e){status.textContent='Could not load: '+e.message;}
clearTimeout(timer);timer=setTimeout(load,document.hidden?30000:5000);}
document.querySelectorAll('[data-period]').forEach(b=>b.addEventListener('click',()=>{period=b.dataset.period;document.querySelectorAll('[data-period]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));load();}));
document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
load();
})();
</script>
</body>
</html>
''';
}
