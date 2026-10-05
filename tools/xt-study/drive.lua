-- Drive the captured truck+semi (SweptSim.EXAMPLE_RIG, stock AutoDrive follower) through every
-- movement of the XT junction pieces and measure where it really goes.
-- Usage: lua drive.lua <repo scripts/editor dir> <out dir>
local SRC, OUT = arg[1], arg[2]
dofile(SRC .. "/SweptSim.lua")
local S = SweptSim
local rig, drv = S.EXAMPLE_RIG, S.STOCK_DRIVER

-- Template nodes at unit size (L = 1): the 1 m version of the mod's layout, scaled by L.
local T = { [1]={0,0},[2]={-.5,.5},[3]={-.75,.5},[4]={-1.5,.5},[5]={-.5,.75},[6]={-.5,1.5},[7]={.5,1.5},
  [8]={.5,.75},[9]={.5,.5},[10]={.75,.5},[11]={1.5,.5},[12]={1.5,-.5},[13]={-1.5,-.5} }
local TL = { {1,2},{1,13},{2,5},{2,9},{3,2},{3,5},{4,3},{5,6},{7,8},{8,9},{8,10},{9,10},{9,1},{10,11},{12,13},{12,1} }
local X = { [1]={0,0},[2]={-.5,.5},[3]={-.75,.5},[4]={-1.5,.5},[5]={-.5,.75},[6]={-.5,1.5},[7]={.5,1.5},
  [8]={.5,.75},[9]={.5,.5},[10]={.75,.5},[11]={1.5,.5},[12]={1.5,-.5},[13]={.75,-.5},[14]={.5,-.5},
  [15]={.5,-.75},[16]={.5,-1.5},[17]={-.5,-1.5},[18]={-.5,-.75},[19]={-.5,-.5},[20]={-.75,-.5},[21]={-1.5,-.5} }
local XL = { {1,2},{1,9},{1,14},{1,19},{2,5},{2,9},{3,2},{3,5},{4,3},{5,6},{7,8},{8,9},{8,10},{9,10},{9,14},
  {10,11},{12,13},{13,14},{13,15},{14,15},{14,19},{15,16},{17,18},{18,19},{18,20},{19,20},{19,2},{20,21} }

local PIECES = {
  { key="T", nodes=T, links=TL, moves={
    { "main eastbound, straight", {4,3,2,9,10,11} },
    { "main westbound, straight", {12,13} },
    { "main eastbound, right into side", {4,3,5,6} },
    { "main westbound, left into side", {12,1,2,5,6} },
    { "side, right onto main", {7,8,10,11} },
    { "side, left onto main", {7,8,9,1,13} } } },
  { key="X", nodes=X, links=XL, moves={
    { "straight", {4,3,2,9,10,11} },
    { "right", {4,3,5,6} },
    { "left via centre", {4,3,2,1,14,15,16} },
    { "left round the square", {4,3,2,9,14,15,16} },
    { "U-turn via centre", {4,3,2,1,19,20,21} } } },
}

local LEAD, STEP = 45, 3   -- straight road before and after the piece, AutoDrive-like node spacing

-- Arm ends sit at |x| or |z| = 1.5: the road runs along that axis, so lead in/out along it.
local function armDir(nd)
  if math.abs(nd[1]) > 1.4 then return (nd[1] > 0) and 1 or -1, 0 end
  return 0, (nd[2] > 0) and 1 or -1
end

local function buildPath(nodes, ids, L)
  local p = {}
  local a = nodes[ids[1]]
  local dx, dz = armDir(a); dx, dz = -dx, -dz
  for d = LEAD, STEP, -STEP do p[#p+1] = { x=a[1]*L - dx*d, z=a[2]*L - dz*d } end
  for _, id in ipairs(ids) do p[#p+1] = { x=nodes[id][1]*L, z=nodes[id][2]*L } end
  local e = nodes[ids[#ids]]
  dx, dz = armDir(e)
  for d = STEP, LEAD, STEP do p[#p+1] = { x=e[1]*L + dx*d, z=e[2]*L + dz*d } end
  return p, math.atan2(p[2].x-p[1].x, p[2].z-p[1].z)
end

-- Distance from point to the nearest lane line of the piece (any link) - where the wheels are
-- relative to the painted lanes, regardless of which movement this is.
local function segDist(px, pz, ax, az, bx, bz)
  local dx, dz = bx-ax, bz-az; local l2 = dx*dx+dz*dz
  local t = l2 > 0 and math.max(0, math.min(1, ((px-ax)*dx+(pz-az)*dz)/l2)) or 0
  return math.sqrt((ax+t*dx-px)^2 + (az+t*dz-pz)^2)
end

local res = {}
local svg = {}
for _, pc in ipairs(PIECES) do
  for _, L in ipairs({3,4,5,6}) do
    for _, mv in ipairs(pc.moves) do
      local path, h0 = buildPath(pc.nodes, mv[2], L)
      local st = S.simulate(path, rig, drv, { x=path[1].x, z=path[1].z, heading=h0, speed=30 },
        { speedLimitKmh=40 })
      -- Only judge the part near the piece (within 2.5 L + 12 m of its centre).
      local R = 1.5*L + 12
      local inL, inR, trL, trR, frL, frR, vmin = 0,0,0,0,0,0,99
      local tri, trx, trz = 0
      for _, s in ipairs(st) do
        local near = math.sqrt(s.x^2+s.z^2) < R or math.sqrt(s.ax^2+s.az^2) < R
        if near then
          local o = S.offsetFromPath(path, s.x, s.z)            -- tow rear axle
          local oa = S.offsetFromPath(path, s.ax, s.az)         -- trailer axle
          local fx, fz = math.sin(s.heading), math.cos(s.heading)
          local fo = S.offsetFromPath(path, s.x + fx*(rig.wheelbase+1.2), s.z + fz*(rig.wheelbase+1.2)) -- front bumper
          inL, inR = math.max(inL, o), math.max(inR, -o)
          trL, trR = math.max(trL, oa), math.max(trR, -oa)
          frL, frR = math.max(frL, fo), math.max(frR, -fo)
          vmin = math.min(vmin, s.v)
        end
      end
      local hw = rig.trailerWidth/2
      res[#res+1] = string.format("%s %dm | %-34s | truck axle off line L%4.1f R%4.1f | trailer axle L%4.1f R%4.1f (wheel edge L%4.1f R%4.1f) | nose L%4.1f R%4.1f | min %4.1f km/h",
        pc.key, L, mv[1], inL, inR, trL, trR, trL+hw, trR+hw, frL, frR, vmin)

      -- SVG panel
      local sc, W = 8, 2*R*8
      local function P(x, z) return string.format("%.1f,%.1f", (x+R)*sc, (z+R)*sc) end
      local g = { string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" style="background:#fff;border:1px solid #ccc;margin:4px">', W, W+18, W, W+18) }
      g[#g+1] = string.format('<text x="4" y="%d" font-size="12" font-family="sans-serif">%s %dm: %s</text>', W+14, pc.key, L, mv[1])
      for _, lk in ipairs(pc.links) do
        local a, b = pc.nodes[lk[1]], pc.nodes[lk[2]]
        g[#g+1] = string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#bbb" stroke-width="2"/>',
          P(a[1]*L,a[2]*L):match("([^,]+),"), P(a[1]*L,a[2]*L):match(",(.+)"), P(b[1]*L,b[2]*L):match("([^,]+),"), P(b[1]*L,b[2]*L):match(",(.+)"))
      end
      local function poly(key, xk, zk, col, w, off)
        local pts = {}
        for k = 1, #st, 6 do
          local s = st[k]
          local x, z = s[xk], s[zk]
          if off then
            local th = (xk == "ax") and s.trailerHeading or s.heading
            x, z = x + math.cos(th)*off, z - math.sin(th)*off
          end
          if math.abs(x) < R and math.abs(z) < R then pts[#pts+1] = P(x, z) end
        end
        if #pts > 1 then g[#g+1] = string.format('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s"/>', table.concat(pts, " "), col, w) end
      end
      local pp = {}
      for _, p in ipairs(path) do if math.abs(p.x) < R and math.abs(p.z) < R then pp[#pp+1] = P(p.x, p.z) end end
      g[#g+1] = string.format('<polyline points="%s" fill="none" stroke="#2563eb" stroke-width="2" stroke-dasharray="5 3"/>', table.concat(pp, " "))
      poly("tow", "x", "z", "#16a34a", 1.5, rig.towWidth/2); poly("tow", "x", "z", "#16a34a", 1.5, -rig.towWidth/2)
      poly("tr", "ax", "az", "#dc2626", 1.5, hw); poly("tr", "ax", "az", "#dc2626", 1.5, -hw)
      g[#g+1] = '</svg>'
      svg[#svg+1] = { key=pc.key, L=L, s=table.concat(g, "\n") }
      local pf = io.open(string.format("%s/panel_%s%d_%s.svg", OUT, pc.key, L, mv[1]:gsub("[^%w]+", "-")), "w")
      pf:write(table.concat(g, "\n")); pf:close()
    end
  end
end

local f = io.open(OUT .. "/drive_results.txt", "w"); f:write(table.concat(res, "\n"), "\n"); f:close()
print(table.concat(res, "\n"))
local h = { '<!doctype html><meta charset="utf-8"><title>XT drive test</title><body style="font-family:sans-serif">',
  '<p>North up. Grey = the piece\'s paths. Blue dashes = the path driven. Green = truck wheels. Red = trailer wheels. Rig: Transtar II + SKS 30/1050 semi, stock AutoDrive steering.</p>' }
local last
for _, v in ipairs(svg) do
  local tag = v.key .. v.L
  if tag ~= last then h[#h+1] = string.format('<h3>%s %d m</h3>', v.key, v.L); last = tag end
  h[#h+1] = v.s
end
f = io.open(OUT .. "/drive.html", "w"); f:write(table.concat(h, "\n")); f:close()
