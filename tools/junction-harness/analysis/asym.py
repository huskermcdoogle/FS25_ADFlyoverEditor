# A link is two halves: A.out lists B, and B.in lists A. Where only one half is there, the graph
# disagrees with itself - and AutoDrive reads the stored `in`, so it sees a road that nothing drives.
import re, sys, math
def load(p):
    s=open(p,encoding="utf8",errors="ignore").read()
    def arr(t):
        m=re.search(r"<%s>(.*?)</%s>"%(t,t),s,re.S); return m.group(1).split(";") if m else []
    X=[float(v) for v in arr("x") if v.strip()]; Z=[float(v) for v in arr("z") if v.strip()]
    def lists(tag):
        L=[[int(v) for v in o.split(",") if v.strip() not in ("","-1","0")] for o in arr(tag)]
        while len(L)<len(X): L.append([])
        return L
    return X,Z,lists("out"),lists("in")
p,cx,cz,rad=sys.argv[1],float(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
X,Z,out,inc=load(p)
bad=[]
for i in range(len(X)):
    for j in inc[i]:                       # i says "j feeds me"
        if 1<=j<=len(X) and (i+1) not in out[j-1]:
            bad.append(("in-without-out", j, i+1))
    for j in out[i]:                       # i says "I feed j"
        if 1<=j<=len(X) and (i+1) not in inc[j-1]:
            bad.append(("out-without-in", i+1, j))
near=[b for b in bad if math.hypot(X[b[1]-1]-cx,Z[b[1]-1]-cz)<=rad or math.hypot(X[b[2]-1]-cx,Z[b[2]-1]-cz)<=rad]
print(f"asymmetric links: {len(bad)} in the whole network, {len(near)} within {rad:.0f} m")
for kind,a,b in near[:20]:
    print(f"   {kind:16s}  {X[a-1]:9.2f},{Z[a-1]:8.2f}  ->  {X[b-1]:9.2f},{Z[b-1]:8.2f}"
          f"   ({math.hypot(X[a-1]-X[b-1],Z[a-1]-Z[b-1]):.1f} m)")
