import re, math, os, glob
import os
FS25 = os.environ.get("FS25_PROFILE") or os.path.join(os.path.expanduser("~"), "Documents", "My Games", "FarmingSimulator2025")
SAVE = os.environ.get("FS25_SAVEGAME", "savegame6")
D = os.environ.get("CAPTURE_DIR") or os.path.join(FS25, SAVE, "flyoverDebug")
def load(p):
    s=open(p,encoding="utf8",errors="ignore").read()
    def arr(t):
        m=re.search(r"<%s>(.*?)</%s>"%(t,t),s,re.S); return m.group(1).split(";") if m else []
    X=[float(v) for v in arr("x") if v.strip()]; Z=[float(v) for v in arr("z") if v.strip()]
    def L(tag):
        l=[[int(v) for v in o.split(",") if v.strip() not in ("","-1","0")] for o in arr(tag)]
        while len(l)<len(X): l.append([])
        return l
    return X,Z,L("out"),L("in")
def stats(p,cx,cz):
    X,Z,out,inc = load(p)
    merges=short=0
    for i in range(len(X)):
        d=math.hypot(X[i]-cx,Z[i]-cz)
        if d<=25:
            o,n=out[i],inc[i]
            dual=sum(1 for k in n if k in o); sIn=sum(1 for k in n if k not in o); sOut=sum(1 for k in o if k not in n)
            if len(o)>=1 and len(n)>=2:
                c=True
                if   dual==1 and sIn==1 and sOut==0: c=False
                elif dual==1 and sIn==0 and sOut==1: c=False
                elif dual==2 and sIn==0 and sOut==0: c=False
                if c: merges+=1
        for j in out[i]:
            if 1<=j<=len(X):
                a=(X[i],Z[i]); b=(X[j-1],Z[j-1])
                L=math.hypot(a[0]-b[0],a[1]-b[1])
                if 0<L<2.0 and math.hypot((a[0]+b[0])/2-cx,(a[1]+b[1])/2-cz)<=22: short+=1
    return merges, short
print(f"{'capture':<34}{'merges pre':>11}{'post':>6}{'short pre':>11}{'post':>6}  errors")
tm=ts=0
for d in sorted(glob.glob(os.path.join(D,"0*"))):
    m=re.search(r"_(-?[\d.]+)_(-?[\d.]+)$", os.path.basename(d))
    if not m: continue
    cx,cz=float(m.group(1)),float(m.group(2))
    try:
        mp,sp = stats(d+"/pre.xml",cx,cz); mq,sq = stats(d+"/post.xml",cx,cz)
    except Exception as e:
        print(f"{os.path.basename(d):<34} could not read: {e}"); continue
    log=open(d+"/tool.log",encoding="utf8",errors="ignore").read()
    err = len(re.findall(r"ERROR|WARNING|attempt to", log))
    tm+=mq; ts+=sq
    print(f"{os.path.basename(d):<34}{mp:>11}{mq:>6}{sp:>11}{sq:>6}  {err if err else ''}")
print(f"\ntotals after clearing: {tm} merge(s) left, {ts} short link(s) left")
