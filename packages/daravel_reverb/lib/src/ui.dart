import 'package:daravel/html.dart';

/// The tabs of the dashboard, as `GET /reverb/{tab}`.
const List<String> reverbTabs = ['overview', 'limits', 'apps', 'workers'];

/// The dashboard page under [base]: markup from `package:daravel/html.dart`,
/// its style and script inline with the response's CSP [nonce], and every
/// value from the API written as text (`textContent`), never as markup.
HtmlDocument reverbPage({
  required String base,
  required String nonce,
  String tab = 'overview',
}) => document(
  title: 'Reverb',
  head: [
    meta(name: 'robots', content: 'noindex, nofollow'),
    style(_css, nonce: nonce),
  ],
  bodyAttributes: {'data-base': base, 'data-tab': tab},
  [
    header([
      strong(['Reverb']),
      nav([
        for (final name in reverbTabs)
          a(
            [name[0].toUpperCase() + name.substring(1)],
            href: '$base/$name',
            attributes: {'data-tab': name},
          ),
      ]),
      span([], id: 'status', classes: 'status'),
      button(['Restart servers'], id: 'restart', classes: 'secondary'),
    ]),
    mainEl([
      for (final name in reverbTabs)
        section(
          [
            h2([name[0].toUpperCase() + name.substring(1)]),
            div([], id: 'view-$name'),
          ],
          id: 'tab-$name',
          classes: 'tab',
          attributes: {'hidden': name != tab},
        ),
    ]),
    script(content: _js, nonce: nonce),
  ],
);

const String _css = '''
:root{--bg:#f6f7f9;--panel:#fff;--ink:#14171c;--muted:#5d6675;--line:#e3e6eb;--accent:#6b4bd6;--err:#b3261e;--sans:system-ui,-apple-system,"Segoe UI",sans-serif;--mono:ui-monospace,"Cascadia Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#111318;--panel:#191c22;--ink:#e8eaee;--muted:#9aa3b1;--line:#2a2f38}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 var(--sans)}
header{display:flex;gap:16px;align-items:center;padding:10px 20px;background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap}
header strong{color:var(--accent)}nav{display:flex;gap:4px;flex-wrap:wrap}
nav a{color:var(--muted);text-decoration:none;padding:4px 10px;border-radius:6px}nav a[aria-current]{background:var(--bg);color:var(--ink)}
.status{margin-left:auto;color:var(--muted);font-size:12px}
main{max-width:1200px;margin:0 auto;padding:20px}
.tab h2{margin:0 0 12px;font-size:12px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}.stat{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 14px;min-width:140px}
.stat .v{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}.stat .l{color:var(--muted);font-size:12px}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:8px;margin-bottom:16px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:500;font-size:12px}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}.code{font-family:var(--mono);font-size:12px;word-break:break-all}.sub{color:var(--muted);font-size:12px}
button{font:inherit;border:1px solid var(--accent);background:var(--accent);color:#fff;border-radius:6px;padding:4px 10px;cursor:pointer}
button.secondary{background:transparent;color:var(--accent)}button.danger{border-color:var(--err);background:var(--err);color:#fff}
.empty{color:var(--muted);padding:12px}.tag{display:inline-block;background:var(--bg);border-radius:4px;padding:0 6px;margin:2px 4px 0 0;font-size:12px}
''';

/// The page's script: every value is set with `textContent`; messages per
/// second come from the difference between two updates.
const String _js = r'''
(()=>{
const base=document.body.dataset.base;let tab=document.body.dataset.tab;let source=null,poll=null,last=null;
const el=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=String(x);return e;};
const fmt=n=>n==null?'-':Number(n).toLocaleString();
const ms=n=>n==null?'-':(n<1?n.toFixed(2):Math.round(n))+' ms';
const status=t=>{document.getElementById('status').textContent=t;};
function xsrf(){const m=document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]*)/);return m?{'X-XSRF-TOKEN':decodeURIComponent(m[1])}:{};}
async function api(path,opts){const r=await fetch(base+'/api'+path,Object.assign({credentials:'same-origin',headers:Object.assign({accept:'application/json','content-type':'application/json'},xsrf())},opts||{}));
const body=await r.json().catch(()=>null);if(!r.ok)throw new Error((body&&body.message)||('HTTP '+r.status));return body;}
function table(box,cols,rows,empty){const t=el('table');if(!rows||!rows.length){box.append(el('div','empty',empty));return;}
const h=el('tr');for(const c of cols)h.append(el('th',c.n?'n':'',c.label));const hd=el('thead');hd.append(h);t.append(hd);
const b=el('tbody');for(const r of rows){const tr=el('tr');for(const c of cols){const td=el('td',c.n?'n':'');const v=c.cell(r);if(v instanceof Node)td.append(v);else td.textContent=v==null?'':String(v);tr.append(td);}b.append(tr);}t.append(b);box.append(t);}
function cards(box,list){const st=el('div','stats');for(const [v,l] of list){const c=el('div','stat');c.append(el('div','v',v),el('div','l',l));st.append(c);}box.append(st);}
function kinds(m){const d=el('div');for(const [k,v] of Object.entries(m||{}))d.append(el('span','tag',k+' '+fmt(v)));if(!d.childNodes.length)d.textContent='-';return d;}
function rate(s,at){const out={};if(last){const dt=(at-last.at)/1000;for(const [id,a] of Object.entries(s.apps||{})){const p=(last.s.apps||{})[id];if(p&&dt>0)out[id]={in:Math.max(0,(a.messages_in-p.messages_in)/dt),out:Math.max(0,(a.messages_out-p.messages_out)/dt)};}}last={s,at};return out;}
function render(s,at){if(s.error){status(s.error);return;}const r=rate(s,at);const apps=Object.entries(s.apps||{});
const sum=f=>apps.reduce((n,[id,a])=>n+f(id,a),0);
const o=document.getElementById('view-overview');o.replaceChildren();
cards(o,[[fmt(sum((i,a)=>a.connections)),'connections'],[fmt(apps.length),'applications'],[fmt(Object.keys(s.workers||{}).length),'worker isolates'],
[(sum(i=>(r[i]||{}).in||0)).toFixed(1),'messages in / s'],[(sum(i=>(r[i]||{}).out||0)).toFixed(1),'messages out / s']]);
table(o,[{label:'App',cell:x=>el('span','code',x[0])},{label:'Connections',n:1,cell:x=>fmt(x[1].connections)},{label:'Channels',cell:x=>kinds(x[1].channels)},
{label:'In / s',n:1,cell:x=>r[x[0]]?r[x[0]].in.toFixed(1):'-'},{label:'Out / s',n:1,cell:x=>r[x[0]]?r[x[0]].out.toFixed(1):'-'},
{label:'Fan-out p50',n:1,cell:x=>x[1].fanout?ms(x[1].fanout.p50_ms):'-'},{label:'p95',n:1,cell:x=>x[1].fanout?ms(x[1].fanout.p95_ms):'-'}],apps,'No Pusher connections.');
const l=document.getElementById('view-limits');l.replaceChildren();
cards(l,[[fmt(s.slow_clients),'slow consumers closed (4100)'],[fmt(sum((i,a)=>a.rate_limited||0)),'rate limited (4301)'],[fmt(Object.values(s.rejected||{}).reduce((a,b)=>a+b,0)),'refused']]);
table(l,[{label:'Reason',cell:x=>el('span','code',x[0])},{label:'Refused',n:1,cell:x=>fmt(x[1])}],Object.entries(s.rejected||{}),'Nothing refused.');
table(l,[{label:'App',cell:x=>el('span','code',x[0])},{label:'Rate limited',n:1,cell:x=>fmt(x[1].rate_limited||0)}],apps.filter(x=>x[1].rate_limited),'No message rate limited.');
const w=document.getElementById('view-workers');w.replaceChildren();
table(w,[{label:'Worker isolate',cell:x=>el('span','code',x[0])},{label:'Connections',n:1,cell:x=>fmt(x[1])},
{label:'By app',cell:x=>{const d=el('div');for(const [id,a] of apps){const n=(a.workers||{})[x[0]];if(n)d.append(el('span','tag',id+' '+fmt(n)));}return d;}}],Object.entries(s.workers||{}).sort(),'No worker isolate holds a connection.');}
async function poll1(){try{render(await api('/stats'),Date.now());status('Updated '+new Date().toLocaleTimeString());}catch(e){status('Could not load: '+e.message);}}
function stream(){stopLive();if(!window.EventSource){poll=setInterval(poll1,5000);poll1();return;}
source=new EventSource(base+'/api/stream');source.addEventListener('update',e=>{const d=JSON.parse(e.data);render(d.stats,d.at);status('Live '+new Date().toLocaleTimeString());});
source.onerror=()=>{if(source){source.close();source=null;}if(!poll){poll=setInterval(poll1,5000);poll1();}};}
function stopLive(){if(source){source.close();source=null;}if(poll){clearInterval(poll);poll=null;}}
async function showApps(){const box=document.getElementById('view-apps');box.replaceChildren();try{const d=await api('/apps');box.append(el('div','sub','Provider: '+d.provider));
table(box,[{label:'App',cell:x=>{const c=el('div');c.append(el('div','code',x.id));if(x.settings)c.append(el('div','sub','REVERB_APP_*'));return c;}},{label:'Key',cell:x=>el('span','code',x.key)},
{label:'Origins',cell:x=>{const c=el('div');for(const o of x.allowed_origins||[])c.append(el('span','tag',o));return c;}},{label:'Max connections',n:1,cell:x=>x.max_connections?fmt(x.max_connections):'none'},
{label:'Max message',n:1,cell:x=>fmt(x.max_message_size)+' B'},{label:'Ping',n:1,cell:x=>x.activity_timeout+' s'},{label:'Rate limiting',cell:x=>x.rate_limiting?'on':'off'}],d.apps,'No application.');}catch(e){status('Could not load: '+e.message);}}
function show(name){tab=name;for(const s of document.querySelectorAll('.tab'))s.hidden=s.id!=='tab-'+name;
for(const a of document.querySelectorAll('nav a'))a.toggleAttribute('aria-current',a.dataset.tab===name);if(name==='apps')showApps();}
for(const a of document.querySelectorAll('nav a'))a.addEventListener('click',e=>{e.preventDefault();history.pushState(null,'',a.href);show(a.dataset.tab);});
window.addEventListener('popstate',()=>{const n=location.pathname.split('/').pop();show(document.getElementById('tab-'+n)?n:'overview');});
const rb=document.getElementById('restart');let armed=null;rb.addEventListener('click',async()=>{if(!armed){rb.textContent='Confirm restart';rb.className='danger';armed=setTimeout(()=>{armed=null;rb.textContent='Restart servers';rb.className='secondary';},4000);return;}
clearTimeout(armed);armed=null;rb.disabled=true;try{await api('/restart',{method:'POST'});status('Restart signal sent; connections drain over REVERB_DRAIN_SPREAD.');}catch(e){status(e.message);}rb.disabled=false;rb.textContent='Restart servers';rb.className='secondary';});
stream();show(tab);
})();
''';
