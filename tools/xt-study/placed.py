"""Find the two placed XT junctions in savegame6's AutoDrive network and show how they are hooked up.
Usage: python placed.py <savegame folder>/AutoDrive_config.xml"""
import re, math, os, sys
CFG = sys.argv[1]
t = open(CFG, encoding='utf-8-sig').read()
wp = re.search(r'<waypoints>(.*?)</waypoints>', t, re.S).group(1)
g = lambda k: re.search(r'<%s>(.*?)</%s>' % (k, k), wp, re.S).group(1).strip()
ids = [int(v) for v in g('id').split(',')]
X = [float(v) for v in g('x').split(',')]
Y = [float(v) for v in g('y').split(',')]
Z = [float(v) for v in g('z').split(',')]
outs = [[int(v) for v in s.split(',') if v not in ('-1', '')] for s in g('out').split(';')]
inc = [[int(v) for v in s.split(',') if v not in ('-1', '')] for s in g('incoming').split(';')]
fl = [int(v) for v in g('flags').split(',')]
idx = {ids[i]: i for i in range(len(ids))}
mm = re.findall(r'<mm\d+>\s*<id>(.*?)</id>\s*<name>(.*?)</name>\s*<group>(.*?)</group>', t, re.S)
markers = {int(float(a)): (b, c) for a, b, c in mm}
print('network nodes', len(ids), 'markers', len(markers))

SITES = [('T 6m', -741.554, 262.304), ('X 5m', -783.136, 267.573)]
for name, cx, cz in SITES:
    print('=====', name, 'at', cx, cz)
    near = sorted([i for i in range(len(ids)) if math.hypot(X[i] - cx, Z[i] - cz) < 16],
                  key=lambda i: math.hypot(X[i] - cx, Z[i] - cz))
    nearset = {ids[i] for i in near}
    for i in near:
        n = ids[i]
        def tag(j):
            k = idx[j]
            ext = '' if j in nearset else '*'
            two = '<>' if n in outs[k] else '>'
            return '%d%s%s' % (j, two, ext)
        print('  %6d local(%6.2f,%6.2f) y%.2f d=%5.2f fl=%d out:%-26s in:%s %s' % (
            n, X[i] - cx, Z[i] - cz, Y[i], math.hypot(X[i] - cx, Z[i] - cz), fl[i],
            ' '.join(tag(j) for j in outs[i]), inc[i], markers.get(n, '')))
    print('  (* = node outside 16 m, i.e. the wider network)')
