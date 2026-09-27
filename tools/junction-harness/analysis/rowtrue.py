# Use the file's OWN <in> list, the way AutoDrive does, instead of rebuilding it from <out>.
import re, sys, math
def load(p):
    s = open(p, encoding="utf8", errors="ignore").read()
    def arr(t):
        m = re.search(r"<%s>(.*?)</%s>" % (t, t), s, re.S)
        return m.group(1).split(";") if m else []
    X=[float(v) for v in arr("x") if v.strip()]; Z=[float(v) for v in arr("z") if v.strip()]
    def lists(tag):
        L=[[int(v) for v in o.split(",") if v.strip() not in ("","-1","0")] for o in arr(tag)]
        while len(L)<len(X): L.append([])
        return L
    return X, Z, lists("out"), lists("in")
def centres(p, cx, cz, rad):
    X,Z,out,inc = load(p); res=[]
    for i in range(len(X)):
        d = math.hypot(X[i]-cx, Z[i]-cz)
        if d > rad: continue
        o,n = out[i], inc[i]
        dual = sum(1 for k in n if k in o)
        sIn  = sum(1 for k in n if k not in o)
        sOut = sum(1 for k in o if k not in n)
        if len(o) >= 1 and len(n) >= 2:
            c=True
            if   dual==1 and sIn==1 and sOut==0: c=False
            elif dual==1 and sIn==0 and sOut==1: c=False
            elif dual==2 and sIn==0 and sOut==0: c=False
            if c: res.append((d,X[i],Z[i],len(n),len(o),dual,sIn,sOut))
    res.sort(); return res
if __name__ == "__main__":
    p,cx,cz,rad = sys.argv[1],float(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
    r=centres(p,cx,cz,rad)
    print(f"{len(r)} centre(s) within {rad:.0f} m  [using the file's own <in>]")
    for d,x,z,ni,no,du,si,so in r:
        print(f"   {d:5.1f} m  {x:9.2f},{z:8.2f}   in={ni} out={no}  (dual {du}, sIn {si}, sOut {so})")
