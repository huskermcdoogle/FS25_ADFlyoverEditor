"""Print every node and link of the mod's X and T pieces. Usage: python decode.py <unzipped mod folder>"""
import re, glob, os, sys
D = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

def parse(f):
    t = open(f, encoding='utf-8-sig').read()
    g = lambda k: re.search(r'<%s>(.*?)</%s>' % (k, k), t, re.S).group(1).strip()
    ids = [int(v) for v in g('id').split(',')]
    xs = [float(v) for v in g('x').split(',')]
    zs = [float(v) for v in g('z').split(',')]
    outs = [[int(v) for v in s.split(',') if v != '-1'] for s in g('out').split(';')]
    inc = [[int(v) for v in s.split(',') if v != '-1'] for s in g('incoming').split(';')]
    fl = g('flags').split(',')
    mm = re.findall(r'<mm\d+>.*?<id>(.*?)</id>.*?<name>(.*?)</name>.*?<group>(.*?)</group>', t, re.S)
    return ids, xs, zs, outs, inc, fl, mm

for f in sorted(glob.glob(os.path.join(D, '*crossing-*m-line.xml'))):
    ids, xs, zs, outs, inc, fl, mm = parse(f)
    print('=====', os.path.basename(f), 'nodes', len(ids), 'flags', set(fl), 'markers', mm)
    for i in range(len(ids)):
        kinds = ['%d%s' % (j, '<>' if i + 1 in outs[j - 1] else '>') for j in outs[i]]
        print('  %2d (%6.2f,%6.2f) out:%-14s in:%s' % (ids[i], xs[i], zs[i], ' '.join(kinds), inc[i]))
    bad = [(i + 1, j) for i in range(len(ids)) for j in outs[i] if (i + 1) not in inc[j - 1]]
    print('  out/incoming mismatch:', bad)
