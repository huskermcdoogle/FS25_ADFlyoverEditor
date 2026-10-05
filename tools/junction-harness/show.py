# ONE PICTURE PAGE FOR ANY JUNCTIONS: before and after a clear, both through modes, north up, with
# the card's check lines under each picture. Built on dump_site.lua + plot.py, so every page looks
# the same and nobody writes drawing code again.
#   GRAPH=<network .lua> python show.py out.html 39 26 "24.5,1.3" [--modes 1|0|10] [--span 45]
# Junction numbers come from REG (default savegame6's ADFlyoverEditor_junctions.xml). Unless REGDIR
# is set, a private copy of that file names split parts (j39se) as in game. FE_SRC, TERRAIN and the
# other harness switches pass through.
import base64, html, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

LUA = os.environ.get("LUA", r"C:/Program Files (x86)/Lua/5.1/lua.exe")
HERE = os.path.dirname(os.path.abspath(__file__))
REG = os.environ.get("REG", os.path.expanduser(
    "~/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml"))

args = sys.argv[1:]
if len(args) < 2 or "GRAPH" not in os.environ:
    sys.exit("usage: GRAPH=<network .lua> python show.py out.html 39 26 \"x,z\" [--modes 10] [--span 45]")
out = args.pop(0)
modes, span = "10", "45"
if "--modes" in args:
    i = args.index("--modes"); modes = args[i + 1]; del args[i:i + 2]
if "--span" in args:
    i = args.index("--span"); span = args[i + 1]; del args[i:i + 2]

regtxt = open(REG, encoding="utf8").read()
sites = []
for a in args:
    if "," in a:
        x, z = a.split(",")
        sites.append(("(%s, %s)" % (x, z), x, z))
    else:
        m = re.search(r'n="%s" x="(-?[\d.]+)" z="(-?[\d.]+)"' % re.escape(a), regtxt)
        if not m:
            print("j%s: not in %s" % (a, REG)); continue
        sites.append(("j" + a, m.group(1), m.group(2)))

tmp = tempfile.mkdtemp()
env = dict(os.environ, RIG_TRAILER=os.environ.get("RIG_TRAILER", "11"))
if not env.get("REGDIR"):
    os.makedirs(os.path.join(tmp, "reg"))
    shutil.copy(REG, os.path.join(tmp, "reg", "ADFlyoverEditor_junctions.xml"))
    env["REGDIR"] = os.path.join(tmp, "reg")

def job(k, site, mode):
    label, x, z = site
    d = os.path.join(tmp, "j%d_%s" % (k, mode)); os.makedirs(d)
    e = dict(env); shutil.copytree(env["REGDIR"], os.path.join(d, "reg")); e["REGDIR"] = os.path.join(d, "reg")
    dump = os.path.join(d, "site.txt"); png = os.path.join(d, "site.png")
    subprocess.run([LUA, "dump_site.lua", x, z, "12", "on" if mode == "1" else "off", dump, span],
                   cwd=HERE, env=e, capture_output=True)
    ok = os.path.exists(dump) and os.path.getsize(dump) > 0
    if ok:
        subprocess.run([sys.executable, "plot.py", dump, png], cwd=HERE, capture_output=True)
    e2 = dict(e, LEAVE=mode, ALL="1"); shutil.rmtree(e["REGDIR"]); shutil.copytree(env["REGDIR"], e["REGDIR"])
    r = subprocess.run([LUA, "dbgcheck.lua", x, z], cwd=HERE, env=e2, capture_output=True, text=True, errors="replace")
    o = r.stdout + r.stderr
    name = (re.search(r"^NAME (.*)$", o, re.M) or [None, label])[1]
    took = re.search(r"took \d+ point\(s\) in all, the farthest \d+ m", o)
    refused = re.search(r"^REFUSED: (.*)$", o, re.M)
    card = re.findall(r"^CARD (.*)$", o, re.M)
    lines = [re.sub(r"^.*junction - check", "check", l) for l in o.splitlines()
             if "junction - check: " in l or "junction - check (" in l]
    errs = len(re.findall(r"attempt to|stack traceback", o))
    img = base64.b64encode(open(png, "rb").read()).decode() if ok and os.path.exists(png) else None
    return dict(label=label, name=name, mode=mode, took=took.group(0) if took else None,
                refused=refused.group(1) if refused else None, card=card, lines=lines, errs=errs, img=img)

jobs = [(k, s, m) for k, s in enumerate(sites) for m in modes]
with ThreadPoolExecutor(max_workers=int(os.environ.get("PAR", "16"))) as ex:
    res = list(ex.map(lambda j: job(*j), jobs))
shutil.rmtree(tmp, ignore_errors=True)

LEGEND = [("#000", "dot", "a road point"), ("#c80078", "dot", "a road point with a high number (mostly added later)"), ("#3c3cc8", "line", "one-way link (arrow shows the way)"),
          ("#787878", "line", "two-way link"), ("#ff0000", "ring", "point the clear takes (left picture)"),
          ("#ff7800", "ring", "point the box sweep takes"), ("#e6c800", "line", "edge line the lanes are cut back to"),
          ("#00b400", "ring", "a new lane end (stub)"), ("#00a000", "thin", "a kept through road's middle line"),
          ("#ff0000", "x", "the locked centre"), ("#008c00", "plus", "the box centre")]
def sw(c, kind):
    return '<span class="sw %s" style="--c:%s"></span>' % (kind, c)
h = ['<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
     '<title>Junction pictures</title><style>',
     ':root{--bg:#f4f5f2;--card:#fff;--ink:#1d2124;--mute:#5b6268;--line:#d9dcd6}',
     '@media (prefers-color-scheme:dark){:root{--bg:#16191b;--card:#1f2326;--ink:#e7e9e6;--mute:#a3aaa8;--line:#343a3e}}',
     'body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,sans-serif;padding:16px}',
     '.w{max-width:1200px;margin:auto}h1{font-size:22px;margin:0 0 4px}.sub{color:var(--mute);margin:0 0 12px}',
     '.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px;background:var(--card);border:1px solid var(--line);border-radius:6px;padding:10px 12px}',
     '.sw{display:inline-block;width:18px;height:10px;margin-right:6px;vertical-align:middle}.sw.dot{width:8px;height:8px;border-radius:50%;background:var(--c)}',
     '.sw.line{height:3px;background:var(--c)}.sw.thin{height:1px;background:var(--c)}.sw.ring{width:10px;height:10px;border:2px solid var(--c);border-radius:50%}',
     '.sw.x{background:linear-gradient(45deg,transparent 42%,var(--c) 42% 58%,transparent 58%),linear-gradient(-45deg,transparent 42%,var(--c) 42% 58%,transparent 58%)}',
     '.sw.plus{background:linear-gradient(transparent 42%,var(--c) 42% 58%,transparent 58%),linear-gradient(90deg,transparent 42%,var(--c) 42% 58%,transparent 58%)}',
     'section{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin-top:16px}',
     'h2{margin:0 0 8px;font-size:19px}h3{margin:12px 0 4px;font-size:15px}img{width:100%;height:auto;border:1px solid var(--line);background:#fff;cursor:zoom-in}',
     '.cap{font-size:12px;color:var(--mute);display:flex;justify-content:space-between}.card{font-weight:700}.ln{font-size:13px;color:var(--mute);margin:2px 0 0 12px}',
     '.err{color:#c0392b;font-weight:700}#big{position:fixed;inset:0;background:rgba(0,0,0,.85);display:none;align-items:center;justify-content:center;cursor:zoom-out}#big img{max-width:98vw;max-height:96vh;width:auto}',
     '</style></head><body><div class="w">',
     '<h1>Junction pictures</h1><p class="sub">North up, 10 m grid. Left: before the clear. Right: after it. Click a picture to enlarge.</p>',
     '<div class="legend">' + "".join("<span>%s%s</span>" % (sw(c, k), html.escape(t)) for c, k, t in LEGEND) + '</div>']
for k, s in enumerate(sites):
    rs = [r for r in res if r["label"] == s[0]]
    h.append('<section><h2>%s</h2>' % html.escape(s[0] if rs[0]["name"] in (None, s[0]) else "%s (locked as %s)" % (s[0], rs[0]["name"])))
    for r in rs:
        h.append('<h3>%s</h3>' % ("Through roads kept" if r["mode"] == "1" else "Through roads off"))
        if r["refused"]:
            h.append('<p>Refused: %s</p>' % html.escape(r["refused"])); continue
        if r["img"]:
            h.append('<div class="cap"><span>before</span><span>after</span></div><img alt="before and after" src="data:image/png;base64,%s">' % r["img"])
        if r["took"]:
            h.append('<p>%s</p>' % html.escape(r["took"]))
        for c in r["card"]:
            h.append('<p class="card">%s</p>' % html.escape(c))
        for l in r["lines"]:
            h.append('<p class="ln">%s</p>' % html.escape(l))
        if r["errs"]:
            h.append('<p class="err">%d Lua error line(s)</p>' % r["errs"])
    h.append('</section>')
h.append('</div><div id="big"></div><script>const b=document.getElementById("big");'
         'document.querySelectorAll("section img").forEach(i=>i.onclick=()=>{b.innerHTML="";b.appendChild(i.cloneNode());b.style.display="flex"});'
         'b.onclick=()=>{b.style.display="none"};addEventListener("keydown",e=>{if(e.key==="Escape")b.onclick()});</script></body></html>')
open(out, "w", encoding="utf8").write("\n".join(h))
print("wrote %s (%d junction(s), %d picture(s))" % (out, len(sites), sum(1 for r in res if r["img"])))
