local Config = require("../src/shared/Config")
local Rules = require("../src/shared/Rules")
local function makeRng(seed) local s = seed return function() s = (s * 1103515245 + 12345) % 2147483648 return s / 2147483648 end end
local function defense(G, h, x, z)
  local d = 0
  for _, e in ipairs(G:foes()) do
    local dd = math.sqrt((e.x-x)^2+(e.z-z)^2)
    if dd <= e.def.weapon.range + e.move then
      if e.def.weapon.melee then d -= (dd <= e.move + 1.5) and 1 or 0
      elseif not G:hasLOS(e.x, e.z, x, z) then d += 1
      else local cv = G:coverInfo(x, z, e.x, e.z).value; d += (cv == 2 and 1) or (cv == 1 and 0.4) or -1 end
    end
  end
  return d
end
local function turn(G, rng)
  for _, h in ipairs(G:heroes()) do
    if G:result() then return end
    local o = G:computeMoveOptions(h)
    local cands = {}
    for _, v in pairs(o.walk) do table.insert(cands, {x=v.x, z=v.z}) end
    for _, v in pairs(o.jump) do table.insert(cands, {x=v.x, z=v.z, jump=v}) end
    local best, bs = nil, -math.huge
    for _, c in ipairs(cands) do
      local atk, near = 0, math.huge
      for _, e in ipairs(G:foes()) do
        local ch = G:shotInfo(h, c.x, c.z, e).chance
        local w = h.def.weapon
        local v = ch/100 * (w.min+w.max)/2 * (e.hp <= w.max and 1.5 or 1)
        atk = math.max(atk, v); near = math.min(near, math.sqrt((e.x-c.x)^2+(e.z-c.z)^2))
      end
      local sc = atk/20 + defense(G, h, c.x, c.z) * 1.2 - (atk == 0 and near*0.3 or 0) + rng()*0.2
      if sc > bs then bs = sc; best = c end
    end
    if best and not (best.x == h.x and best.z == h.z) then
      if best.jump then G:heroJump(h, best.jump) else G:heroWalk(h, best.x, best.z) end
    end
    if G:result() then return end
    local tgt, tv = nil, 0
    for _, e in ipairs(G:foes()) do
      local ch = G:shotInfo(h, h.x, h.z, e).chance
      local v = ch * (e.hp <= h.def.weapon.max and 2 or 1)
      if v > tv then tv = v; tgt = e end
    end
    if tgt then G:heroAttack(h, tgt) end
    if G:result() then return end
    if h.cd == 0 and not h.techUsed then
      local t = h.def.tech.id
      local want = false
      if t == "heal" then for _, a in ipairs(G:heroes()) do if a.hp < a.maxHp - 40 and math.sqrt((a.x-h.x)^2+(a.z-h.z)^2) <= 3 then want = true end end
      elseif t == "shield" then want = true
      else want = true end
      if want then G:heroTech(h) end
    end
  end
end
for li = 1, 3 do
  local wins, rounds = 0, 0
  for seed = 1, 100 do
    local G = Rules.new(Config, li, makeRng(seed * 31 + li))
    G:startPlayerTurn(true)
    local guard = 0
    while not G:result() and guard < 60 do guard += 1; turn(G, G.rng); if G:result() then break end; G:endTurn() end
    if G:result() == "win" then wins += 1; rounds += G.turn end
  end
  print(("Level %d vorsichtiger Bot: %d/100 Siege, Ø %.1f Runden"):format(li, wins, wins > 0 and rounds/wins or 0))
end
