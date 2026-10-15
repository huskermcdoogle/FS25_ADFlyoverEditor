# ASCII map of a saved case box (0.5 m per char, north up): paint, M = drawn middle, L = laid line of spot S
import sys, math
cells_f, walks_f, spot = sys.argv[1], sys.argv[2], sys.argv[3]
x0, x1, z0, z1 = map(float, sys.argv[4:8])
ch = {1: 'd', 2: 'g', 3: 'a', 4: 's', 5: 'F'}
g = {}
for l in open(cells_f):
    p = l.split()
    if p and p[0] == 'c': g[(round(float(p[1]) * 2), round(float(p[2]) * 2))] = ch[int(p[3])]
def draw(P, c):
    for (ax, az), (bx, bz) in zip(P, P[1:]):
        n = max(1, int(math.hypot(bx - ax, bz - az) * 4))
        for k in range(n + 1):
            t = k / n
            g[(round((ax + (bx - ax) * t) * 2), round((az + (bz - az) * t) * 2))] = c
mid, line = [], []
for l in open(walks_f):
    p = l.split()
    if p and p[0] == 'm': mid.append((float(p[1]), float(p[2])))
    if p and p[0] == 'l' and p[1] == spot: line.append((float(p[2]), float(p[3])))
draw(mid, 'M'); draw(line, 'L')
for zi in range(round(z0 * 2), round(z1 * 2) + 1):
    print('%7.1f ' % (zi / 2) + ''.join(g.get((xi, zi), '.') for xi in range(round(x0 * 2), round(x1 * 2) + 1)))
print('        x from %.0f to %.0f' % (x0, x1))
