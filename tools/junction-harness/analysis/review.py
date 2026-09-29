# A review page for EVERY junction: an overview map, then one card each with its picture, what the
# tool and the map read, and answer boxes (kind + main road + note) prefilled from truth_types.txt.
# "Copy answers" puts the answers on the clipboard in truth_types.txt's format.
#   GRAPH=<network .lua> SPLINES=<roadSplines.xml> python analysis/review.py compare.txt tooltypes.txt out.html
# Run from tools/junction-harness. Self-contained: the pictures are inlined.
import html, json, math, os, re, subprocess, sys, tempfile

LUA = os.environ.get("LUA", r"C:\Program Files (x86)\Lua\5.1\lua.exe")
comp, tt, out = sys.argv[1], sys.argv[2], sys.argv[3]
KINDS = ["", "T square", "T skew", "Y merge", "Y", "4W square", "4W skew", "4W very skew", "4W offset",
         "two T's close together", "not a junction", "other"]
DIRS = ["", "N", "NE", "E", "SE", "S", "SW", "W", "NW"]

rx = re.compile(r"(DISAGREE|MAP UNSURE|TOOL NO READ|NO MAP ROAD|agree)\s+j(\d+)\s+\(\s*(-?[\d.]+),\s*(-?[\d.]+)\)\s+"
                r"tool: (.*?)\s{2,}map: (.*?)\s+\(wider circle: (.*?)\)")
rows = {}
for line in open(comp, encoding="utf8"):
    m = rx.match(line)
    if m:
        v, n, x, z, tool, mp, wide = m.groups()
        rows[int(n)] = dict(v=v, x=float(x), z=float(z), tool=tool, map=mp, wide=wide)
# "# skip: 67 68" in truth_types.txt: junctions never to show (test leftovers on the map)
skip = set()
if os.path.exists("truth_types.txt"):
    for line in open("truth_types.txt", encoding="utf8"):
        m = re.match(r"#\s*skip:\s*(.*)", line.strip())
        if m: skip |= {int(v) for v in m.group(1).split()}
for n in skip: rows.pop(n, None)
mains, branch = {}, {}
for line in open(tt, encoding="utf8"):
    mb = re.match(r"(\d+) .*\| branch (\d+)", line.strip())
    if mb: branch[int(mb.group(1))] = int(mb.group(2))
    m = re.match(r"(\d+) .*\| main (.*)$", line.strip())
    if m: mains[int(m.group(1))] = m.group(2)

def compass_word(deg):
    return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][int((deg + 22.5) // 45) % 8]
def main_words(s):
    if not s or s == "none": return "none"
    parts = []
    for p in s.split(","):
        if p.startswith("far"): continue   # the card names the way the road leaves
        a, b = (int(v) for v in p.split("/"))
        parts.append("%s-%s" % (compass_word(a), compass_word(b)))
    return ", ".join(dict.fromkeys(parts))

truth = {}
if os.path.exists("truth_types.txt"):
    for line in open("truth_types.txt", encoding="utf8"):
        note = line.split("#", 1)[1].strip() if "#" in line else ""
        body = line.split("#")[0].strip()
        if not body: continue
        n, k = body.split(None, 1)
        mm = re.search(r"main=(\w+)-(\w+)", k)
        kind = re.sub(r"\s*main=\S+", "", k).strip()
        unsure = kind.endswith("?")
        truth[int(n)] = dict(kind=kind.rstrip("?").strip(), unsure=unsure,
                             a=mm.group(1) if mm else "", b=mm.group(2) if mm else "", note=note)

# ---- pictures
tmp = tempfile.mkdtemp()
env = dict(os.environ, RIG_TRAILER=os.environ.get("RIG_TRAILER", "11"))
pics = {}
for n in sorted(rows):
    r = rows[n]
    p = os.path.join(tmp, "j%d.svg" % n)
    subprocess.run([LUA, "dbgroutes_svg.lua", str(r["x"]), str(r["z"]), p, "60"], env=env, capture_output=True)
    s = open(p, encoding="utf8").read() if os.path.exists(p) else "<p>(no picture)</p>"
    pics[n] = re.sub(r'<svg ([^>]*?)width="\d+" height="\d+"', r'<svg \1', s, count=1)
    print("drawn j%d" % n, flush=True)

# ---- overview map (north up: FS25 z grows southward)
xs = [r["x"] for r in rows.values()]; zs = [r["z"] for r in rows.values()]
minx, maxx, minz, maxz = min(xs) - 60, max(xs) + 60, min(zs) - 60, max(zs) + 60
W = 1000; sc = W / max(maxx - minx, maxz - minz); H = int((maxz - minz) * sc)
net = []
g = os.environ.get("GRAPH")
if g and os.path.exists(g):
    pts = {}
    txt = open(g, encoding="utf8").read()
    for m in re.finditer(r"\{id=(\d+),x=(-?[\d.]+),y=[^,]+,z=(-?[\d.]+),flags=\d+,out=\{([^}]*)\}", txt):
        pts[int(m.group(1))] = (float(m.group(2)), float(m.group(3)), m.group(4))
    seen = set()
    for i, (x, z, o) in pts.items():
        for t in o.split(","):
            t = t.strip()
            if t and int(t) in pts and (int(t), i) not in seen:
                seen.add((i, int(t)))
                x2, z2, _ = pts[int(t)]
                net.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/>' % (
                    (x - minx) * sc, (z - minz) * sc, (x2 - minx) * sc, (z2 - minz) * sc))
COL = {"agree": "#1e8e3e", "DISAGREE": "#d93025", "MAP UNSURE": "#f29900", "TOOL NO READ": "#5f6368", "NO MAP ROAD": "#1a73e8"}
dots = []
for n, r in sorted(rows.items()):
    cx, cy = (r["x"] - minx) * sc, (r["z"] - minz) * sc
    dots.append('<a href="#j%d"><circle cx="%.1f" cy="%.1f" r="9" fill="%s" stroke="#fff" stroke-width="1.5"/>'
                '<text x="%.1f" y="%.1f">%d</text></a>' % (n, cx, cy, COL[r["v"]], cx, cy + 3.5, n))
overview = ('<svg viewBox="0 0 %d %d" class="ov"><g class="net">%s</g>%s</svg>' % (W, H, "".join(net), "".join(dots)))

# The browser keeps answers under a key tied to the answer key's content: once answers are folded
# into truth_types.txt the page starts from them again, instead of reloading stale ones over them.
import hashlib
keyver = hashlib.sha1(open("truth_types.txt", "rb").read()).hexdigest()[:10] if os.path.exists("truth_types.txt") else "none"

# ---- cards
LAB = {"agree": ("tool and map agree", "ag"), "DISAGREE": ("tool and map disagree", "dis"),
       "MAP UNSURE": ("map reading unsure", "uns"), "TOOL NO READ": ("tool found nothing", "no"),
       "NO MAP ROAD": ("map reader sees no junction", "nm")}
def opts(values, sel):
    return "".join('<option%s>%s</option>' % (" selected" if v == sel else "", html.escape(v)) for v in values)
cards = []
for n, r in sorted(rows.items()):
    t = truth.get(n, {})
    lab, cls = LAB[r["v"]]
    kind = t.get("kind", "")
    if kind and kind not in KINDS: KINDS.append(kind)
    cards.append(f'''<figure id="j{n}" data-n="{n}" data-status="{cls}" class="{'done' if t else ''}">
<figcaption><b>Junction {n}</b> <span class="tag {cls}">{lab}</span>{' <span class="tag you">answered</span>' if t else ''}<br>
<span class="k">Tool:</span> {html.escape('nothing' if r['tool'] == 'nil' else r['tool'])}
&nbsp; <span class="k">main road:</span> {html.escape(main_words(mains.get(n, '')))}
{f'&nbsp; <span class="k">side road meets at</span> <b>{branch[n]}&deg;</b>' if n in branch else ''}<br>
<span class="k">Map:</span> {html.escape(r['map'])} <span class="c">(wider: {html.escape(r['wide'])})</span><br>
<span class="c">at {r['x']:.0f}, {r['z']:.0f}</span></figcaption>
<div class="pic">{pics[n]}</div>
<div class="ans"><label>Kind <select class="kind">{opts(KINDS, kind)}</select></label>
<label><input type="checkbox" class="unsure"{' checked' if t.get('unsure') else ''}> not sure</label>
<label>Main road <select class="ma">{opts(DIRS, t.get('a', ''))}</select> to <select class="mb">{opts(DIRS, t.get('b', ''))}</select></label>
<input class="note" placeholder="note" value="{html.escape(t.get('note', ''))}"></div></figure>''')

counts = {}
for r in rows.values(): counts[r["v"]] = counts.get(r["v"], 0) + 1
legend = " ".join('<span class="dot" style="background:%s"></span>%s %d' % (COL[k], LAB[k][0], counts.get(k, 0)) for k in COL)
page = f'''<!doctype html><html><head><meta charset="utf-8"><title>Junction review</title><style>
:root{{--bg:#f6f5f2;--card:#fff;--ink:#1f1f1f;--mute:#666;--line:#ddd}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--ink);font:14px system-ui,sans-serif}}
h1{{font-size:20px;margin:0 0 4px}} p{{margin:0 0 10px;color:var(--mute);max-width:80ch}}
.bar{{position:sticky;top:0;z-index:5;background:var(--bg);padding:8px 0;display:flex;gap:10px;flex-wrap:wrap;align-items:center;border-bottom:1px solid var(--line);margin-bottom:12px}}
button,select,input{{font:inherit}} button{{padding:5px 12px;border:1px solid #bbb;border-radius:6px;background:#fff;cursor:pointer}}
.ov{{width:100%;max-width:900px;height:auto;background:#fff;border:1px solid var(--line);border-radius:8px;display:block;margin-bottom:14px}}
.ov .net line{{stroke:#c9d2cc;stroke-width:1}} .ov text{{font-size:9px;font-weight:700;fill:#fff;text-anchor:middle;pointer-events:none}}
.dot{{display:inline-block;width:10px;height:10px;border-radius:50%;margin:0 4px 0 10px;vertical-align:-1px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(400px,1fr));gap:14px}}
figure{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden;scroll-margin-top:60px}}
figure.done{{border-color:#9ccc9c}} figcaption{{padding:10px 12px;line-height:1.5}} .k{{color:var(--mute)}} .c{{color:var(--mute);font-size:12px}}
.tag{{font-size:11px;padding:1px 7px;border-radius:9px;margin-left:6px}}
.ag{{background:#e6f4ea;color:#137333}} .dis{{background:#fde2e1;color:#a50e0e}} .uns{{background:#fef3d6;color:#7a5200}}
.no{{background:#e8eaed;color:#3c4043}} .nm{{background:#e8f0fe;color:#174ea6}} .you{{background:#d7f0d7;color:#1b5e20}}
.pic{{border-top:1px solid var(--line);border-bottom:1px solid var(--line);cursor:zoom-in}} .pic svg{{width:100%;height:auto;display:block}}
.ans{{padding:10px 12px;display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center}} .ans .note{{flex:1 1 100%;padding:4px 6px;border:1px solid #ccc;border-radius:5px}}
#big{{position:fixed;inset:0;background:rgba(0,0,0,.75);display:none;align-items:center;justify-content:center;z-index:9;cursor:zoom-out}}
#big svg{{height:96vh;width:auto;max-width:96vw;background:#fff;border-radius:6px}}
#msg{{color:#137333}}
</style></head><body><h1>Junction review - all {len(rows)} junctions</h1>
<p>North is up. In each picture: wide pale orange = the map's own roads, black = what the tool reads as the main road,
coloured = side roads, dashed blue = loose pieces. Click a picture to enlarge (Esc closes). Click a number on the map to jump to it.
Your answers are kept in this browser as you go; "Copy answers" puts them on the clipboard to paste back.</p>
<div>{legend}</div>{overview}
<div class="bar"><button id="copy">Copy answers</button>
<label>Show <select id="filter"><option value="">all</option><option value="dis">tool and map disagree</option>
<option value="uns">map unsure</option><option value="no">tool found nothing</option><option value="nm">no map road</option>
<option value="ag">agree</option><option value="todo">not answered yet</option></select></label><span id="msg"></span></div>
<div class="grid">{"".join(cards)}</div><div id="big"></div>
<script>
const KEY='junction-review-answers-{keyver}';   // changes whenever the answer key does, so old browser answers never override it
let saved={{}}; try{{saved=JSON.parse(localStorage.getItem(KEY)||'{{}}')}}catch(e){{}}
const figs=[...document.querySelectorAll('figure[data-n]')];
function read(f){{return {{kind:f.querySelector('.kind').value,unsure:f.querySelector('.unsure').checked,
  a:f.querySelector('.ma').value,b:f.querySelector('.mb').value,note:f.querySelector('.note').value.trim()}}}}
function apply(f,v){{f.querySelector('.kind').value=v.kind;f.querySelector('.unsure').checked=v.unsure;
  f.querySelector('.ma').value=v.a;f.querySelector('.mb').value=v.b;f.querySelector('.note').value=v.note}}
figs.forEach(f=>{{const n=f.dataset.n;if(saved[n])apply(f,saved[n]);
  f.querySelectorAll('select,input').forEach(el=>el.addEventListener('change',()=>{{
    saved[n]=read(f);try{{localStorage.setItem(KEY,JSON.stringify(saved))}}catch(e){{}};
    f.classList.toggle('done',!!saved[n].kind)}}))}});
document.getElementById('copy').onclick=async()=>{{
  const lines=[];figs.forEach(f=>{{const v=read(f);if(!v.kind)return;
    let s=f.dataset.n.padEnd(4)+v.kind+(v.unsure?' ?':'');if(v.a&&v.b)s+='  main='+v.a+'-'+v.b;if(v.note)s+='   # '+v.note;lines.push(s)}});
  const txt=lines.join('\\n');
  try{{await navigator.clipboard.writeText(txt);document.getElementById('msg').textContent='Copied '+lines.length+' answer(s).'}}
  catch(e){{prompt('Copy these answers:',txt)}}}};
document.getElementById('filter').onchange=e=>{{const v=e.target.value;figs.forEach(f=>{{
  const show=!v||(v==='todo'?!read(f).kind:f.dataset.status===v);f.style.display=show?'':'none'}})}};
const b=document.getElementById('big');
document.querySelectorAll('.pic').forEach(p=>p.onclick=()=>{{b.innerHTML=p.innerHTML;b.style.display='flex'}});
b.onclick=()=>{{b.style.display='none';b.innerHTML=''}};addEventListener('keydown',e=>{{if(e.key==='Escape')b.onclick()}});
</script></body></html>'''
open(out, "w", encoding="utf8").write(page)
print("wrote %s: %d junctions, %d answered" % (out, len(rows), len(truth)))
