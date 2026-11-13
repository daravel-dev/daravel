import 'package:daravel/html.dart';

/// The tabs of the dashboard (Blueprint #134 §3.7), as `GET /horizon/{tab}`.
const List<String> horizonTabs = [
  'dashboard',
  'monitoring',
  'metrics',
  'workload',
  'pending',
  'completed',
  'silenced',
  'failed',
];

/// The dashboard page under [base]: markup from `package:daravel/html.dart`,
/// its style and script inline with the response's CSP [nonce], and every
/// value from the API written as text (`textContent`), never as markup.
HtmlDocument horizonPage({
  required String base,
  required String nonce,
  String tab = 'dashboard',
}) => document(
  title: 'Horizon',
  head: [
    meta(name: 'robots', content: 'noindex, nofollow'),
    style(_css, nonce: nonce),
  ],
  bodyAttributes: {'data-base': base, 'data-tab': tab},
  [
    header([
      strong(['Horizon']),
      nav([
        for (final name in horizonTabs)
          a(
            [name[0].toUpperCase() + name.substring(1)],
            href: '$base/$name',
            attributes: {'data-tab': name},
          ),
      ]),
      span([], id: 'status', classes: 'status'),
    ]),
    mainEl([
      for (final name in horizonTabs)
        section(
          [
            h2([name[0].toUpperCase() + name.substring(1)]),
            if (name == 'monitoring')
              form(
                [
                  input(
                    name: 'tag',
                    attributes: {
                      'placeholder': 'Tag to monitor (App\\Models\\User:1)',
                      'aria-label': 'Tag',
                      'required': true,
                    },
                  ),
                  button(['Monitor'], attributes: {'type': 'submit'}),
                ],
                action: '$base/api/monitoring',
                id: 'monitor-form',
              ),
            if (name == 'failed')
              button(['Retry all'], id: 'retry-all', classes: 'secondary'),
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
:root{--bg:#f6f7f9;--panel:#fff;--ink:#14171c;--muted:#5d6675;--line:#e3e6eb;--accent:#c4472f;--ok:#2f7d4f;--err:#b3261e;--sans:system-ui,-apple-system,"Segoe UI",sans-serif;--mono:ui-monospace,"Cascadia Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#111318;--panel:#191c22;--ink:#e8eaee;--muted:#9aa3b1;--line:#2a2f38}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 var(--sans)}
header{display:flex;gap:16px;align-items:center;padding:10px 20px;background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap}
header strong{color:var(--accent)}nav{display:flex;gap:4px;flex-wrap:wrap}
nav a{color:var(--muted);text-decoration:none;padding:4px 10px;border-radius:6px}nav a[aria-current]{background:var(--bg);color:var(--ink)}
.status{margin-left:auto;color:var(--muted);font-size:12px}
main{max-width:1200px;margin:0 auto;padding:20px}
.tab h2{margin:0 0 12px;font-size:12px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted)}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}.stat{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 14px;min-width:140px}
.stat .v{font-size:22px;font-weight:600}.stat .l{color:var(--muted);font-size:12px}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:8px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:500;font-size:12px}
td.n,th.n{text-align:right}.code{font-family:var(--mono);font-size:12px;word-break:break-all}.sub{color:var(--muted);font-size:12px}
pre{white-space:pre-wrap;word-break:break-all;font:12px/1.4 var(--mono);background:var(--bg);padding:8px;border-radius:6px;max-height:320px;overflow:auto}
button{font:inherit;border:1px solid var(--accent);background:var(--accent);color:#fff;border-radius:6px;padding:4px 10px;cursor:pointer}
button.secondary{background:transparent;color:var(--accent);margin-bottom:12px}
form{display:flex;gap:8px;margin-bottom:12px}input{font:inherit;padding:4px 8px;border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--ink);min-width:280px}
.empty{color:var(--muted);padding:12px}.tag{display:inline-block;background:var(--bg);border-radius:4px;padding:0 6px;margin:2px 4px 0 0;font-size:12px}
''';

/// The page's script: every value is set with `textContent`.
const String _js = r'''
(()=>{
const base=document.body.dataset.base;let tab=document.body.dataset.tab;let source=null,poll=null;
const el=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=String(x);return e;};
const fmt=n=>n==null?'-':Number(n).toLocaleString();
const ms=n=>n==null?'-':(n>=1000?(n/1000).toFixed(2)+' s':Math.round(n)+' ms');
const ago=t=>{if(t==null)return'-';const s=Math.max(0,Math.round((Date.now()-t)/1000));return s<60?s+' s ago':s<3600?Math.round(s/60)+' min ago':Math.round(s/3600)+' h ago';};
const status=t=>{document.getElementById('status').textContent=t;};
function xsrf(){const m=document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]*)/);return m?{'X-XSRF-TOKEN':decodeURIComponent(m[1])}:{};}
async function api(path,opts){const r=await fetch(base+'/api'+path,Object.assign({credentials:'same-origin',headers:Object.assign({accept:'application/json','content-type':'application/json'},xsrf())},opts||{}));
if(!r.ok)throw new Error('HTTP '+r.status);return r.status===204?null:r.json();}
function table(box,cols,rows,empty){box.replaceChildren();if(!rows||!rows.length){box.append(el('div','empty',empty));return;}
const t=el('table'),h=el('tr');for(const c of cols)h.append(el('th',c.n?'n':'',c.label));const hd=el('thead');hd.append(h);t.append(hd);
const b=el('tbody');for(const r of rows){const tr=el('tr');for(const c of cols){const td=el('td',c.n?'n':'');const v=c.cell(r);if(v instanceof Node)td.append(v);else td.textContent=v==null?'':String(v);tr.append(td);}b.append(tr);}t.append(b);box.append(t);}
function two(main,sub,code){const d=el('div');d.append(el('div',code?'code':'',main));if(sub)d.append(el('div','sub',sub));return d;}
function tags(list){const d=el('div');for(const t of list||[])d.append(el('span','tag',t));return d;}
function stats(s){const box=document.getElementById('view-dashboard');const st=el('div','stats');
for(const [v,l] of [[s.status,'status'],[fmt(s.jobsPerMinute),'jobs / minute'],[fmt(s.recentJobs),'jobs past hour'],[fmt(s.failedJobs),'failed past week'],[fmt(s.processes),'processes']]){const c=el('div','stat');c.append(el('div','v',v),el('div','l',l));st.append(c);}
const w=el('div');box.replaceChildren(st,w);return w;}
function workload(rows,box){table(box,[{label:'Queue',cell:x=>two(x.name,x.connection+' · '+x.supervisor,true)},{label:'Jobs',n:1,cell:x=>fmt(x.length)},{label:'Processes',n:1,cell:x=>fmt(x.processes)},{label:'Wait',n:1,cell:x=>x.wait==null?'-':x.wait+' s'}],rows,'No queues.');}
function live(d){if(tab==='dashboard')workload(d.workload,stats(d.stats));if(tab==='workload')workload(d.workload,document.getElementById('view-workload'));}
async function poll1(){try{live({stats:await api('/stats'),workload:await api('/workload')});status('Updated '+new Date().toLocaleTimeString());}catch(e){status('Could not load: '+e.message);}}
function stream(){stopLive();if(!window.EventSource){poll=setInterval(poll1,5000);poll1();return;}
source=new EventSource(base+'/api/stream');source.addEventListener('update',e=>{live(JSON.parse(e.data));status('Live '+new Date().toLocaleTimeString());});
source.onerror=()=>{if(source){source.close();source=null;}if(!poll){poll=setInterval(poll1,5000);poll1();}};}
function stopLive(){if(source){source.close();source=null;}if(poll){clearInterval(poll);poll=null;}}
function jobRows(box,jobs,failed){table(box,[{label:'Job',cell:x=>{const d=two(x.name||x.display_name||x.job_name,(x.queue||'')+' · '+(x.uuid||''),true);d.append(tags(x.tags));
if(failed){const det=el('details'),s=el('summary','sub','Details');det.append(s);det.addEventListener('toggle',async()=>{if(!det.open||det.dataset.loaded)return;det.dataset.loaded='1';
try{const j=await api('/jobs/failed/'+encodeURIComponent(x.uuid));det.append(el('div','sub','Exception'),el('pre','',j.exception||x.error||''),el('div','sub','Payload'),el('pre','',j.payload||''));}catch(e){det.append(el('div','sub',e.message));}});d.append(det);}return d;}},
{label:failed?'Failed':'When',cell:x=>ago(x.at||(x.pushed_at?x.pushed_at*1000:null))},{label:'Runtime',n:1,cell:x=>ms(x.duration_ms)},
...(failed?[{label:'',cell:x=>{const b=el('button','','Retry');b.addEventListener('click',async()=>{b.disabled=true;try{await api('/jobs/retry/'+encodeURIComponent(x.uuid),{method:'POST'});b.textContent='Retried';}catch(e){b.textContent=e.message;}});return b;}}]:[])],jobs,'No jobs.');}
async function show(name){tab=name;stopLive();for(const s of document.querySelectorAll('.tab'))s.hidden=s.id!=='tab-'+name;
for(const a of document.querySelectorAll('nav a'))a.toggleAttribute('aria-current',a.dataset.tab===name);
const box=document.getElementById('view-'+name);
try{if(name==='dashboard'||name==='workload'){stream();return;}
if(name==='pending')jobRows(box,(await api('/jobs/pending')).jobs);
if(name==='completed'||name==='silenced')jobRows(box,(await api('/jobs/'+name)).jobs);
if(name==='failed')jobRows(box,(await api('/jobs/failed')).jobs,true);
if(name==='monitoring'){const list=await api('/monitoring');box.replaceChildren();table(box,[{label:'Tag',cell:x=>two(x.tag,null,true)},{label:'Jobs',n:1,cell:x=>fmt(x.count)},{label:'',cell:x=>{const b=el('button','secondary','Stop monitoring');b.addEventListener('click',async()=>{await api('/monitoring/'+encodeURIComponent(x.tag),{method:'DELETE'});show('monitoring');});return b;}}],list,'No monitored tags.');}
if(name==='metrics'){const jobs=await api('/metrics/jobs'),queues=await api('/metrics/queues');box.replaceChildren();
for(const [kind,names] of [['jobs',jobs],['queues',queues]]){const part=el('div');box.append(el('h2','',kind),part);
const rows=[];for(const n of names){const snaps=await api('/metrics/'+kind+'/'+encodeURIComponent(n));const last=snaps[snaps.length-1]||{};rows.push({name:n,count:last.count,avg:last.avg_ms,n:snaps.length});}
table(part,[{label:kind==='jobs'?'Job':'Queue',cell:x=>two(x.name,null,true)},{label:'Last snapshot',n:1,cell:x=>fmt(x.count)},{label:'Average',n:1,cell:x=>ms(x.avg)},{label:'Snapshots',n:1,cell:x=>fmt(x.n)}],rows,'No snapshots yet (dartisan horizon:snapshot).');}}
status('Updated '+new Date().toLocaleTimeString());}catch(e){status('Could not load: '+e.message);}}
for(const a of document.querySelectorAll('nav a'))a.addEventListener('click',e=>{e.preventDefault();history.pushState(null,'',a.href);show(a.dataset.tab);});
window.addEventListener('popstate',()=>{const n=location.pathname.split('/').pop();show(n&&n!=='horizon'&&document.getElementById('tab-'+n)?n:'dashboard');});
document.getElementById('monitor-form').addEventListener('submit',async e=>{e.preventDefault();const f=e.target;try{await api('/monitoring',{method:'POST',body:JSON.stringify({tag:f.tag.value})});f.reset();show('monitoring');}catch(x){status(x.message);}});
document.getElementById('retry-all').addEventListener('click',async()=>{try{let q='',done=0,skipped=0;for(;;){const r=await api('/jobs/retry-all'+q,{method:'POST'});done+=r.retried;skipped+=r.skipped_count;status('Retried '+done+(skipped?', '+skipped+' unreadable left in failed_jobs':'')+(r.remaining?', '+r.remaining+' to go':''));if(!r.remaining||r.up_to===null)break;q='?after='+r.after+'&up_to='+r.up_to;}show('failed');}catch(x){status(x.message);}});
show(tab);
})();
''';
