# Turn bench.lua output into a pan/zoom HTML page (pure stdlib).
#   python view.py out/bench.txt [out.html] [more bench files...]
# Several bench files make one page with a picker. North is up (small z at the top).
import sys, zlib, struct, base64, html, os

KIND_RGB = {"0": (52, 66, 40), "1": (110, 82, 50), "2": (150, 132, 100), "3": (92, 94, 98)}


def png(w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def pts(tokens, ix0, iz0):
    out = []
    for t in tokens:
        x, z = t.split(",")
        out.append("%.1f,%.1f" % (float(x) - ix0, float(z) - iz0))
    return " ".join(out)


def page_for(path):
    ix0 = iz0 = W = H = 0
    rows, svg, info = [], [], []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "window":
            ix0, iz0, W, H = map(int, p[1:5])
        elif p[0] in ("timing", "lanegap"):
            info.append(" ".join(p))
        elif p[0] == "k":
            rows.append([c for ch in p[1] for c in KIND_RGB[ch]])
    ad, edges, nodes, stretches, lanes, walks = [], [], [], [], [], []
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "ad":
            ax, az, bx, bz = map(float, p[1:5])
            ad.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/>' % (ax - ix0, az - iz0, bx - ix0, bz - iz0))
        elif p[0] == "edge":
            col = "#29d3ff" if p[1] == "paved" else "#ff9a3c"
            edges.append('<polyline class="e" stroke="%s" points="%s"><title>%s kind %s width %s</title></polyline>'
                         % (col, pts(p[4:], ix0, iz0), p[1], p[2], p[3]))
        elif p[0] == "node":
            x, z, tag = float(p[1]) - ix0, float(p[2]) - iz0, p[3]
            col = {"fork": "#ffffff", "end": "#ff4d4d", "edge": "#888", "wide": "#c77dff", "ring": "#0f0"}.get(tag, "#ff0")
            nodes.append('<circle cx="%.1f" cy="%.1f" r="2.2" fill="%s" stroke="#000" stroke-width="0.4"><title>%s deg %s</title></circle>'
                         % (x, z, col, tag, p[4]))
        elif p[0] == "stretch":
            stretches.append('<polyline class="s" points="%s"><title>stretch %s %s kind %s w %s len %s %s-%s</title></polyline>'
                             % (pts(p[8:], ix0, iz0), p[1], p[2], p[3], p[4], p[5], p[6], p[7]))
        elif p[0] == "raw":
            walks.append('<polyline class="wr" points="%s"/>' % pts(p[2:], ix0, iz0))
        elif p[0] == "walk":
            walks.append('<polyline class="wk" points="%s"><title>walk %s %s..%s w %s</title></polyline>' % (pts(p[5:], ix0, iz0), p[1], p[2], p[3], p[4]))
        elif p[0] == "lane":
            cls = "l2" if p[2] == "2" else "l1"
            lanes.append('<polyline class="%s" points="%s"/>' % (cls, pts(p[3:], ix0, iz0)))
            for t in p[3:]:
                x, z = t.split(",")
                lanes.append('<circle cx="%.1f" cy="%.1f" r="0.6" fill="#4db3ff"/>' % (float(x) - ix0, float(z) - iz0))
    img = base64.b64encode(png(W, H, rows)).decode()
    body = ('<image href="data:image/png;base64,%s" x="0" y="0" width="%d" height="%d" style="image-rendering:pixelated"/>'
            '<g class="ad">%s</g><g class="st">%s</g><g class="ed">%s</g><g class="ln">%s</g><g class="wa">%s</g><g>%s</g>'
            % (img, W, H, "".join(ad), "".join(stretches), "".join(edges), "".join(lanes), "".join(walks), "".join(nodes)))
    return os.path.basename(path), ix0, iz0, W, H, body, info


def main():
    srcs = [a for a in sys.argv[1:] if a.endswith(".txt")]
    outs = [a for a in sys.argv[1:] if a.endswith(".html")]
    out = outs[0] if outs else os.path.splitext(srcs[0])[0] + ".html"
    pages = [page_for(s) for s in srcs]
    opts = "".join('<option value="%d">%s (x %d..%d, z %d..%d)</option>' % (i, html.escape(n), x, x + w, z, z + h)
                   for i, (n, x, z, w, h, _, _) in enumerate(pages))
    svgs = "".join('<svg class="v" data-i="%d" viewBox="0 0 %d %d" style="display:%s">%s</svg>'
                   % (i, w, h, "block" if i == 0 else "none", body) for i, (_, _, _, w, h, body, _) in enumerate(pages))
    infos = "".join('<div class="info" data-i="%d" style="display:%s">%s - window origin (%d, %d): add to picture x/y for world x/z</div>'
                    % (i, "block" if i == 0 else "none", html.escape(" | ".join(inf)), x, z)
                    for i, (_, x, z, _, _, _, inf) in enumerate(pages))
    doc = """<!doctype html><meta charset="utf-8"><title>Road finder bench</title>
<style>
body{margin:0;background:#15181c;color:#dfe3e8;font:13px sans-serif}
#bar{padding:6px 10px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
#wrap{height:calc(100vh - 70px);overflow:hidden;cursor:grab}
svg.v{width:100%%;height:100%%}
.ad line{stroke:#fff;stroke-width:0.5;opacity:.75}
.e{fill:none;stroke-width:0.8}
.s{fill:none;stroke:#ffd34d;stroke-width:5;opacity:.45;stroke-linecap:round}
.l1{fill:none;stroke:#4db3ff;stroke-width:0.7}
.l2{fill:none;stroke:#7dffb0;stroke-width:0.9}
.wr{fill:none;stroke:#ff4d4d;stroke-width:0.4}
.wk{fill:none;stroke:#ff4dff;stroke-width:1.2}
label{user-select:none}
</style>
<div id="bar"><select id="pick">%s</select>
<label><input type="checkbox" data-g="ad" checked> AutoDrive</label>
<label><input type="checkbox" data-g="ed" checked> centre lines</label>
<label><input type="checkbox" data-g="st" checked> stretches (no path)</label>
<label><input type="checkbox" data-g="ln" checked> lanes</label>
<label><input type="checkbox" data-g="wa" checked> walker (pink; red = as walked)</label>
<span>ground: grey paved, tan gravel, brown dirt. lines: cyan paved, orange track. dots: white fork, red end, grey window edge, purple yard</span></div>
%s
<div id="wrap">%s</div>
<script>
const wrap=document.getElementById('wrap');let cur=0;
function svg(){return document.querySelector('svg.v[data-i="'+cur+'"]')}
document.getElementById('pick').onchange=e=>{cur=+e.target.value;document.querySelectorAll('svg.v,.info').forEach(s=>s.style.display=(+s.dataset.i===cur)?'block':'none')};
document.querySelectorAll('input[data-g]').forEach(c=>c.onchange=()=>document.querySelectorAll('g.'+c.dataset.g).forEach(g=>g.style.display=c.checked?'':'none'));
function vb(s){return s.getAttribute('viewBox').split(' ').map(Number)}
wrap.addEventListener('wheel',e=>{e.preventDefault();const s=svg(),[x,y,w,h]=vb(s),r=s.getBoundingClientRect();
const k=e.deltaY>0?1.25:0.8,fx=(e.clientX-r.left)/r.width,fy=(e.clientY-r.top)/r.height;
const nw=w*k,nh=h*k;s.setAttribute('viewBox',[x+(w-nw)*fx,y+(h-nh)*fy,nw,nh].join(' '))},{passive:false});
let drag=null;wrap.onmousedown=e=>{drag=[e.clientX,e.clientY,vb(svg())]};window.onmouseup=()=>drag=null;
window.onmousemove=e=>{if(!drag)return;const s=svg(),r=s.getBoundingClientRect(),[x,y,w,h]=drag[2];
const sc=Math.max(w/r.width,h/r.height);s.setAttribute('viewBox',[x-(e.clientX-drag[0])*sc,y-(e.clientY-drag[1])*sc,w,h].join(' '))};
</script>""" % (opts, infos, svgs)
    open(out, "w", encoding="utf-8").write(doc)
    print("wrote", out)


main()
