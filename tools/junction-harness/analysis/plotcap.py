# Before and after, straight from a debug capture. North up.
import re, sys, math
def load(p):
    s=open(p,encoding="utf8",errors="ignore").read()
    def arr(t):
        m=re.search(r"<%s>(.*?)</%s>"%(t,t),s,re.S); return m.group(1).split(";") if m else []
    X=[float(v) for v in arr("x") if v.strip()]; Z=[float(v) for v in arr("z") if v.strip()]
    out=[[int(v) for v in o.split(",") if v.strip() not in ("","-1","0")] for o in arr("out")]
    while len(out)<len(X): out.append([])
    L=[]
    for i,o in enumerate(out):
        for j in o:
            if 1<=j<=len(X): L.append(((X[i],Z[i]),(X[j-1],Z[j-1])))
    return X,Z,L
CAP, CX, CZ, RAD, OUT = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
SIDE,PAD,TOP=520,18,52
W=2*(SIDE+PAD)+PAD; H=TOP+SIDE+34
def sx(x,p): return PAD+p*(SIDE+PAD)+(x-(CX-RAD))/(2*RAD)*SIDE
def sy(z):   return TOP+(z-(CZ-RAD))/(2*RAD)*SIDE   # north up: FS25 z grows southward
o=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
   '<style>text{font-family:ui-sans-serif,system-ui,sans-serif}.t{font-size:14px;font-weight:600;fill:#111}'
   '.s{font-size:11px;fill:#555}</style>','<rect width="100%" height="100%" fill="#fbfbfa"/>',
   '<defs><marker id="a" markerWidth="7" markerHeight="7" refX="6" refY="2.4" orient="auto">'
   '<path d="M0,0 L6,2.4 L0,4.8 z" fill="#1f9d55"/></marker></defs>']
for p,(f,title) in enumerate(((CAP+"/pre.xml","before"),(CAP+"/post.xml","after"))):
    X,Z,L=load(f)
    o.append(f'<rect x="{PAD+p*(SIDE+PAD)}" y="{TOP}" width="{SIDE}" height="{SIDE}" fill="#fff" stroke="#ddd"/>')
    n=0; pts=set()
    for a,b in L:
        if (abs(a[0]-CX)<=RAD and abs(a[1]-CZ)<=RAD) or (abs(b[0]-CX)<=RAD and abs(b[1]-CZ)<=RAD):
            o.append(f'<line x1="{sx(a[0],p):.1f}" y1="{sy(a[1]):.1f}" x2="{sx(b[0],p):.1f}" y2="{sy(b[1]):.1f}" '
                     f'stroke="#1f9d55" stroke-width="1.5" marker-end="url(#a)"/>')
            n+=1; pts.add(a); pts.add(b)
    for q in pts:
        if abs(q[0]-CX)<=RAD and abs(q[1]-CZ)<=RAD:
            o.append(f'<circle cx="{sx(q[0],p):.1f}" cy="{sy(q[1]):.1f}" r="3.4" fill="#d93025"/>')
    o.append(f'<text class="t" x="{PAD+p*(SIDE+PAD)}" y="{TOP-20}">{title}</text>')
    o.append(f'<text class="s" x="{PAD+p*(SIDE+PAD)}" y="{TOP-6}">{len(pts)} points, {n} links</text>')
o.append(f'<text class="s" x="{PAD}" y="{H-10}">centred {CX:.1f}, {CZ:.1f}  &#177;{RAD:.0f} m  north up</text>')
o.append('</svg>')
open(OUT,"w",encoding="utf8").write("\n".join(o))
print("wrote",OUT)
