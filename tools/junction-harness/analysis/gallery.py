# One self-contained page of junction pictures, from mapcompare.py's output: every junction whose
# verdict is in KEEP, drawn by dbgroutes_svg.lua with the map's roads underneath.
#   GRAPH=<network .lua> SPLINES=<roadSplines.xml> python analysis/gallery.py compare.txt out.html
# Run from tools/junction-harness. Pictures are inlined, so the page is one file that opens anywhere.
import html, os, re, subprocess, sys, tempfile

KEEP = ("DISAGREE", "MAP UNSURE", "TOOL NO READ")
LABEL = {"DISAGREE": ("disagree", "dis"), "MAP UNSURE": ("map unsure", "uns"), "TOOL NO READ": ("tool found nothing", "no")}
LUA = os.environ.get("LUA", r"C:\Program Files (x86)\Lua\5.1\lua.exe")
src, out = sys.argv[1], sys.argv[2]
rx = re.compile(r"(DISAGREE|MAP UNSURE|TOOL NO READ|NO MAP ROAD|agree)\s+j(\d+)\s+\(\s*(-?[\d.]+),\s*(-?[\d.]+)\)\s+"
                r"tool: (.*?)\s{2,}map: (.*?)\s+\(wider circle: (.*?)\)")
cards, tmp = [], tempfile.mkdtemp()
env = dict(os.environ, RIG_TRAILER=os.environ.get("RIG_TRAILER", "11"))
for line in open(src, encoding="utf8"):
    m = rx.match(line)
    if not m or m.group(1) not in KEEP: continue
    v, n, x, z, tool, mp, wide = m.groups()
    svgp = os.path.join(tmp, f"j{n}.svg")
    subprocess.run([LUA, "dbgroutes_svg.lua", x, z, svgp, "60"], env=env, capture_output=True)
    svg = open(svgp, encoding="utf8").read() if os.path.exists(svgp) else "<p>(no picture)</p>"
    svg = re.sub(r'<svg ([^>]*?)width="\d+" height="\d+"', r'<svg \1', svg, count=1)
    lab, cls = LABEL[v]
    cards.append(f'''<figure><figcaption><b>Junction {n}</b> <span class="tag {cls}">{lab}</span><br>
<span class="k">Tool:</span> {html.escape('nothing' if tool == 'nil' else tool)} &nbsp; <span class="k">Map:</span> {html.escape(mp)}
<span class="k">(wider: {html.escape(wide)})</span><br><span class="c">at {float(x):.0f}, {float(z):.0f}</span></figcaption>
<div class="pic">{svg}</div></figure>''')
page = f'''<!doctype html><html><head><meta charset="utf-8"><title>Junctions: tool vs map</title><style>
:root{{--bg:#f6f5f2;--card:#fff;--ink:#1f1f1f;--mute:#666;--line:#ddd}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--ink);font:14px system-ui,sans-serif}}
h1{{font-size:20px;margin:0 0 4px}} p{{margin:0 0 14px;color:var(--mute);max-width:75ch}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(400px,1fr));gap:14px}}
figure{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}}
figcaption{{padding:10px 12px;line-height:1.5}} .k{{color:var(--mute)}} .c{{color:var(--mute);font-size:12px}}
.tag{{font-size:11px;padding:1px 7px;border-radius:9px;margin-left:6px}}
.dis{{background:#fde2e1;color:#a50e0e}} .uns{{background:#fef3d6;color:#7a5200}} .no{{background:#e8eaed;color:#3c4043}}
.pic{{border-top:1px solid var(--line);cursor:zoom-in}} .pic svg{{width:100%;height:auto;display:block}}
#big{{position:fixed;inset:0;background:rgba(0,0,0,.75);display:none;align-items:center;justify-content:center;z-index:9;cursor:zoom-out}}
#big svg{{height:96vh;width:auto;max-width:96vw;background:#fff;border-radius:6px}}
</style></head><body><h1>Junctions to check: tool vs map</h1>
<p>North is up. Wide pale orange = the map's own roads. Black = roads the tool reads as running straight through.
Coloured = what it reads as side roads. Dashed blue = loose pieces. Click a picture to enlarge; Esc or click to close.</p>
<div class="grid">{"".join(cards)}</div><div id="big"></div><script>const b=document.getElementById('big');
document.querySelectorAll('.pic').forEach(p=>p.onclick=()=>{{b.innerHTML=p.innerHTML;b.style.display='flex'}});
b.onclick=()=>{{b.style.display='none';b.innerHTML=''}};addEventListener('keydown',e=>{{if(e.key==='Escape')b.onclick()}});</script></body></html>'''
open(out, "w", encoding="utf8").write(page)
print(f"wrote {out}: {len(cards)} junction(s)")
