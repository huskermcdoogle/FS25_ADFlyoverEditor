"""Which entry->exit movements AutoDrive can route through each piece, honouring its 80-degree
transit rule (GraphManager.prepareWayPoints), and the shortest legal node sequence for each."""
import math, heapq
T = {1:(0,0),2:(-.5,.5),3:(-.75,.5),4:(-1.5,.5),5:(-.5,.75),6:(-.5,1.5),7:(.5,1.5),8:(.5,.75),9:(.5,.5),
     10:(.75,.5),11:(1.5,.5),12:(1.5,-.5),13:(-1.5,-.5)}
TL = [(1,2),(1,13),(2,5),(2,9),(3,2),(3,5),(4,3),(5,6),(7,8),(8,9),(8,10),(9,10),(9,1),(10,11),(12,13),(12,1)]
X = {1:(0,0),2:(-.5,.5),3:(-.75,.5),4:(-1.5,.5),5:(-.5,.75),6:(-.5,1.5),7:(.5,1.5),8:(.5,.75),9:(.5,.5),
     10:(.75,.5),11:(1.5,.5),12:(1.5,-.5),13:(.75,-.5),14:(.5,-.5),15:(.5,-.75),16:(.5,-1.5),17:(-.5,-1.5),
     18:(-.5,-.75),19:(-.5,-.5),20:(-.75,-.5),21:(-1.5,-.5)}
XL = [(1,2),(2,1),(1,9),(9,1),(1,14),(14,1),(1,19),(19,1),(2,5),(2,9),(3,2),(3,5),(4,3),(5,6),(7,8),(8,9),(8,10),
      (9,10),(9,14),(10,11),(12,13),(13,14),(13,15),(14,15),(14,19),(15,16),(17,18),(18,19),(18,20),(19,20),(19,2),(20,21)]

def ang(a, b, c, N):
    v1 = (N[b][0]-N[a][0], N[b][1]-N[a][1]); v2 = (N[c][0]-N[b][0], N[c][1]-N[b][1])
    d = (v1[0]*v2[0]+v1[1]*v2[1]) / (math.hypot(*v1)*math.hypot(*v2))
    return math.degrees(math.acos(max(-1, min(1, d))))

def run(name, N, links):
    out = {}; inc = {}
    for a, b in links: out.setdefault(a, []).append(b); inc.setdefault(b, []).append(a)
    def legal(a, b, c):
        if ang(a, b, c, N) <= 80: return True
        rs = b not in inc.get(c, [])
        re_ = (b in inc.get(c, [])) and (a not in inc.get(b, []))
        return rs or re_
    ins = [n for n in N if n not in inc]; outs = [n for n in N if n not in out]
    print('=====', name)
    bad = sorted({(a, b, c, round(ang(a, b, c, N))) for a in N for b in out.get(a, []) for c in out.get(b, []) if c != a and not legal(a, b, c)})
    print('  turns AutoDrive refuses (in-node-out, degrees):', bad)
    for s in ins:
        for e in outs:
            # Dijkstra over (prev,node) states, distance only
            pq = [(0, None, s, (s,))]; seen = set(); best = None
            while pq:
                d, p, n, path = heapq.heappop(pq)
                if (p, n) in seen: continue
                seen.add((p, n))
                if n == e: best = (d, path); break
                for m in out.get(n, []):
                    if p is not None and not legal(p, n, m): continue
                    if m in path: continue
                    heapq.heappush(pq, (d + math.dist(N[n], N[m]), n, m, path + (m,)))
            print('  %2d -> %2d : %s' % (s, e, ' '.join(map(str, best[1])) if best else 'NO LEGAL ROUTE'))

run('T', T, TL); run('X', X, XL)
