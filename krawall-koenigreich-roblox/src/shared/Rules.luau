-- Spielregeln von Krawall-Königreich, unabhängig von Roblox.
-- Jede Aktion verändert den Zustand sofort und liefert eine Liste von Ereignissen,
-- die der Client danach der Reihe nach animiert. So bleibt die Logik testbar (tests/simulate.luau).

local Rules = {}
Rules.__index = Rules

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function key(x: number, z: number): number
	return x * 1000 + z
end

local function unkey(k: number): (number, number)
	local x = math.floor(k / 1000)
	return x, k - x * 1000
end

local function sign(v: number): number
	if v > 0 then
		return 1
	elseif v < 0 then
		return -1
	end
	return 0
end

local function round(v: number): number
	return math.floor(v + 0.5)
end

local function coverVal(t): number
	if not t then
		return 0
	end
	if t.type == "wall" then
		return 2
	elseif t.type == "low" then
		return 1
	end
	return 0
end

Rules.key = key
Rules.unkey = unkey
Rules.coverVal = coverVal
Rules.DIRS = DIRS

-- ------------------------------------------------------------------ setup

function Rules.new(config, levelIndex: number, rng: (() -> number)?)
	local L = config.LEVELS[levelIndex]
	local self = setmetatable({}, Rules)
	self.C = config
	self.li = levelIndex
	self.level = L
	self.rng = rng or math.random
	self.W = #L.map[1]
	self.H = #L.map
	self.tiles = {}
	self.units = {}
	self.byId = {}
	self.reinf = {}
	self.uid = 0
	self.turn = 1
	self.phase = "player"
	self.kingRaged = false
	self.ev = {}
	self.stats = { shots = 0, hits = 0, dealt = 0, taken = 0, kos = 0, defeated = 0 }

	local spawns = {}
	for z = 0, self.H - 1 do
		local row = L.map[z + 1]
		for x = 0, self.W - 1 do
			local ch = string.sub(row, x + 1, x + 1)
			local ttype = "floor"
			if ch == "~" then
				ttype = "water"
			elseif ch == "#" then
				ttype = "wall"
			elseif ch == "o" then
				ttype = "low"
			end
			self.tiles[key(x, z)] = { x = x, z = z, type = ttype, hp = if ttype == "low" then 2 else 0 }
			if ch == "1" or ch == "2" or ch == "3" then
				table.insert(spawns, { "hero", config.HERO_ORDER[tonumber(ch)], x, z })
			elseif config.ENEMY_CODES[ch] then
				table.insert(spawns, { "enemy", config.ENEMY_CODES[ch], x, z })
			elseif ch == "r" then
				table.insert(self.reinf, { x, z })
			end
		end
	end
	for _, s in ipairs(spawns) do
		self:addUnit(s[1], s[2], s[3], s[4])
	end
	return self
end

function Rules:addUnit(team: string, kind: string, x: number, z: number)
	local def = if team == "hero" then self.C.HEROES[kind] else self.C.ENEMIES[kind]
	self.uid += 1
	local order = 0
	if team == "hero" then
		order = table.find(self.C.HERO_ORDER, kind) or 0
	end
	local u = {
		id = self.uid,
		team = team,
		kind = kind,
		def = def,
		name = def.name,
		order = order,
		x = x,
		z = z,
		ox = x,
		oz = z,
		hp = def.hp,
		maxHp = def.hp,
		move = def.move,
		alive = true,
		moved = false,
		attacked = false,
		techUsed = false,
		dashUsed = false,
		cd = 0,
		stuck = false,
		shockCd = 0,
		status = { burn = false, honey = false, shield = false, overwatch = false },
	}
	table.insert(self.units, u)
	self.byId[u.id] = u
	return u
end

-- ------------------------------------------------------------------ queries

function Rules:inB(x: number, z: number): boolean
	return x >= 0 and z >= 0 and x < self.W and z < self.H
end

function Rules:tileAt(x: number, z: number)
	if not self:inB(x, z) then
		return nil
	end
	return self.tiles[key(x, z)]
end

function Rules:unitAt(x: number, z: number)
	for _, u in ipairs(self.units) do
		if u.alive and u.x == x and u.z == z then
			return u
		end
	end
	return nil
end

-- Helden in fester Reihenfolge (Leo, Bruna, Pip), inklusive K.O.
function Rules:heroList()
	local out = {}
	for _, u in ipairs(self.units) do
		if u.team == "hero" then
			table.insert(out, u)
		end
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

function Rules:heroes()
	local out = {}
	for _, u in ipairs(self:heroList()) do
		if u.alive then
			table.insert(out, u)
		end
	end
	return out
end

function Rules:foes()
	local out = {}
	for _, u in ipairs(self.units) do
		if u.team == "enemy" and u.alive then
			table.insert(out, u)
		end
	end
	return out
end

function Rules:result(): string?
	if #self:foes() == 0 then
		return "win"
	end
	if #self:heroes() == 0 then
		return "lose"
	end
	return nil
end

function Rules:heroDone(u): boolean
	return (not u.alive) or (u.moved and u.attacked and (u.techUsed or u.cd > 0))
end

-- Breitensuche über begehbare Felder; Verbündete sind passierbar, Gegner nicht.
function Rules:bfs(u, sx: number, sz: number, maxD: number)
	local dist, prev = {}, {}
	local q = { { sx, sz } }
	dist[key(sx, sz)] = 0
	local qi = 1
	while qi <= #q do
		local cur = q[qi]
		qi += 1
		local x, z = cur[1], cur[2]
		local d = dist[key(x, z)]
		if d < maxD then
			for _, dir in ipairs(DIRS) do
				local nx, nz = x + dir[1], z + dir[2]
				local t = self:tileAt(nx, nz)
				if t and t.type == "floor" then
					local k = key(nx, nz)
					if dist[k] == nil then
						local o = self:unitAt(nx, nz)
						if not (o and o ~= u and o.team ~= u.team) then
							dist[k] = d + 1
							prev[k] = key(x, z)
							table.insert(q, { nx, nz })
						end
					end
				end
			end
		end
	end
	return dist, prev
end

local function buildPath(prev, sx: number, sz: number, tx: number, tz: number)
	local out = {}
	local sk, k = key(sx, sz), key(tx, tz)
	if k == sk then
		return out
	end
	if prev[k] == nil then
		return nil
	end
	while k ~= sk do
		local x, z = unkey(k)
		table.insert(out, 1, { x, z })
		k = prev[k]
		if k == nil then
			return nil
		end
	end
	return out
end
Rules.buildPath = buildPath

function Rules:findPath(u, tx: number, tz: number)
	local _, prev = self:bfs(u, u.x, u.z, 99)
	return buildPath(prev, u.x, u.z, tx, tz) or {}
end

-- Deckung am Ziel (tx,tz) aus Sicht des Schützen (fx,fz): 0 keine, 1 halb, 2 voll
function Rules:coverInfo(tx: number, tz: number, fx: number, fz: number)
	local dx, dz = fx - tx, fz - tz
	local ax, az = math.abs(dx), math.abs(dz)
	local best = { value = 0, tile = nil }
	if ax + az <= 1 then
		return best
	end
	if dx ~= 0 and ax >= az * 0.5 then
		local t = self:tileAt(tx + sign(dx), tz)
		local v = coverVal(t)
		if v > best.value then
			best = { value = v, tile = t }
		end
	end
	if dz ~= 0 and az >= ax * 0.5 then
		local t = self:tileAt(tx, tz + sign(dz))
		local v = coverVal(t)
		if v > best.value then
			best = { value = v, tile = t }
		end
	end
	return best
end

function Rules:hasLOS(fx: number, fz: number, tx: number, tz: number): boolean
	local dx, dz = tx - fx, tz - fz
	local steps = math.ceil(math.sqrt(dx * dx + dz * dz) * 6)
	for i = 1, steps - 1 do
		local px, pz = fx + dx * i / steps, fz + dz * i / steps
		local cx, cz = round(px), round(pz)
		if not ((cx == fx and cz == fz) or (cx == tx and cz == tz)) then
			local t = self:tileAt(cx, cz)
			if t and t.type == "wall" and math.abs(px - cx) < 0.44 and math.abs(pz - cz) < 0.44 then
				return false
			end
		end
	end
	return true
end

function Rules:shotInfo(a, fx: number, fz: number, t)
	local w = a.def.weapon
	local d = math.sqrt((t.x - fx) ^ 2 + (t.z - fz) ^ 2)
	local r = { inRange = d <= w.range + 1e-6, chance = 0, reason = "", cover = 0, coverTile = nil }
	if not r.inRange then
		r.reason = "Außer Reichweite"
		return r
	end
	if w.melee then
		r.chance = 100
		r.reason = "Nahkampf"
		return r
	end
	local c = self:coverInfo(t.x, t.z, fx, fz)
	r.cover = c.value
	r.coverTile = c.tile
	if c.value == 2 then
		r.reason = "Volle Deckung"
		return r
	end
	if not self:hasLOS(fx, fz, t.x, t.z) then
		r.reason = "Keine Sichtlinie"
		return r
	end
	r.chance = if c.value == 1 then 50 else 100
	r.reason = if c.value == 1 then "Halbe Deckung" else "Keine Deckung"
	return r
end

-- Bewegungsoptionen eines Helden ab seinem Startfeld in diesem Zug
function Rules:computeMoveOptions(h)
	local dist = self:bfs(h, h.ox, h.oz, h.move)
	local walk, jump, dash, stomp = {}, {}, {}, {}
	for k, d in pairs(dist) do
		local x, z = unkey(k)
		local o = self:unitAt(x, z)
		if not o or o == h then
			walk[k] = { x = x, z = z, d = d }
		end
	end
	local J = self.C.JUMP
	for _, a in ipairs(self:heroes()) do
		local ak = key(a.x, a.z)
		if a ~= h and dist[ak] ~= nil then
			local da = dist[ak]
			for dz = -J, J do
				for dx = -J, J do
					if math.abs(dx) + math.abs(dz) <= J and not (dx == 0 and dz == 0) then
						local x, z = a.x + dx, a.z + dz
						local t = self:tileAt(x, z)
						if t and t.type == "floor" then
							local k = key(x, z)
							local o = self:unitAt(x, z)
							if o and o ~= h then
								if o.team == "enemy" and (stomp[k] == nil or stomp[k].d > da) then
									stomp[k] = { x = x, z = z, enemy = o, via = a, d = da }
								end
							elseif walk[k] == nil and (jump[k] == nil or jump[k].d > da) then
								jump[k] = { x = x, z = z, via = a, d = da }
							end
						end
					end
				end
			end
		end
	end
	if not h.dashUsed then
		for _, e in ipairs(self:foes()) do
			local best = nil
			for _, dir in ipairs(DIRS) do
				local w = walk[key(e.x + dir[1], e.z + dir[2])]
				if w and (best == nil or w.d < best.d) then
					best = w
				end
			end
			if best then
				dash[key(e.x, e.z)] = { enemy = e, stand = best }
			end
		end
	end
	return { walk = walk, jump = jump, dash = dash, stomp = stomp }
end

function Rules:freeTileNear(x: number, z: number, prefer)
	local best, bd = nil, math.huge
	for _, t in pairs(self.tiles) do
		if t.type == "floor" and not self:unitAt(t.x, t.z) then
			local d = math.sqrt((t.x - x) ^ 2 + (t.z - z) ^ 2)
			if prefer then
				d += math.sqrt((t.x - prefer.x) ^ 2 + (t.z - prefer.z) ^ 2) * 0.05
			end
			-- feste Reihenfolge bei Gleichstand, damit das Ergebnis nicht von pairs() abhängt
			if d < bd - 1e-9 or (math.abs(d - bd) <= 1e-9 and best and key(t.x, t.z) < key(best.x, best.z)) then
				bd = d
				best = t
			end
		end
	end
	return best
end

function Rules:techArea(h)
	local t = h.def.tech
	local r = if t.id == "overwatch" then h.def.weapon.range else t.radius
	local out = {}
	for z = 0, self.H - 1 do
		for x = 0, self.W - 1 do
			local tile = self:tileAt(x, z)
			if tile.type ~= "water" and math.sqrt((x - h.x) ^ 2 + (z - h.z) ^ 2) <= r + 1e-6 then
				table.insert(out, { x, z })
			end
		end
	end
	return out, r
end

-- ------------------------------------------------------------------ events

function Rules:emit(kind: string, data)
	data = data or {}
	data.kind = kind
	table.insert(self.ev, data)
end

function Rules:statusOf(u)
	return {
		burn = u.status.burn,
		honey = u.status.honey or u.stuck,
		shield = u.status.shield,
		overwatch = u.status.overwatch,
		alive = u.alive,
	}
end

function Rules:emitStatus(u)
	self:emit("status", { unit = u.id, status = self:statusOf(u) })
end

function Rules:begin()
	self.ev = {}
end

function Rules:finish()
	local ev = self.ev
	self.ev = {}
	return ev
end

function Rules:randInt(a: number, b: number): number
	return a + math.floor(self.rng() * (b - a + 1))
end

-- ------------------------------------------------------------------ damage & effects

function Rules:kill(u)
	u.alive = false
	u.status = { burn = false, honey = false, shield = false, overwatch = false }
	u.stuck = false
	if u.team == "enemy" then
		self.stats.defeated += 1
	else
		self.stats.kos += 1
	end
	self:emit("ko", { unit = u.id })
end

function Rules:applyDamage(t, amount: number, src, quiet: boolean?): number
	if not t.alive then
		return 0
	end
	local dmg = amount
	if t.status.shield then
		dmg = math.ceil(dmg / 2)
	end
	t.hp = math.max(0, t.hp - dmg)
	if src and src.team == "hero" then
		self.stats.dealt += dmg
	elseif t.team == "hero" then
		self.stats.taken += dmg
	end
	self:emit("damage", { unit = t.id, amount = dmg, hp = t.hp, quiet = quiet == true })
	if t.hp <= 0 then
		self:kill(t)
	end
	return dmg
end

function Rules:damageCover(t)
	if not t or t.type ~= "low" then
		return
	end
	t.hp -= 1
	local destroyed = t.hp <= 0
	if destroyed then
		t.type = "floor"
	end
	self:emit("cover", { x = t.x, z = t.z, destroyed = destroyed })
end

function Rules:pushUnit(t, dx: number, dz: number, n: number, src)
	self:emit("float", { unit = t.id, text = "Rückstoß!", style = "fx" })
	for _ = 1, n do
		if not t.alive then
			return
		end
		local nx, nz = t.x + dx, t.z + dz
		local tile = self:tileAt(nx, nz)
		if not tile or tile.type == "water" then
			self:emit("fall", { unit = t.id, x = nx, z = nz })
			self:applyDamage(t, self.C.FALL_DMG, src, true)
			if t.alive then
				local spot = self:freeTileNear(nx, nz)
				if spot then
					t.x, t.z = spot.x, spot.z
					self:emit("respawn", { unit = t.id, x = spot.x, z = spot.z })
				end
			end
			return
		end
		local blocker = self:unitAt(nx, nz)
		if tile.type ~= "floor" or blocker then
			self:emit("bump", { unit = t.id, x = nx, z = nz })
			self:applyDamage(t, self.C.BUMP_DMG, src, true)
			if blocker then
				self:applyDamage(blocker, self.C.BUMP_DMG, src, true)
			end
			if tile.type == "low" then
				self:damageCover(tile)
			end
			return
		end
		t.x, t.z = nx, nz
		self:emit("slide", { unit = t.id, x = nx, z = nz })
	end
end

local function pushDir(fromX: number, fromZ: number, t): (number, number)
	local dx, dz = t.x - fromX, t.z - fromZ
	if math.abs(dx) >= math.abs(dz) then
		return (if sign(dx) == 0 then 1 else sign(dx)), 0
	end
	return 0, sign(dz)
end

function Rules:applyEffect(a, t, eff: string)
	if eff == "burn" then
		t.status.burn = true
		self:emit("effect", { unit = t.id, effect = "burn" })
	elseif eff == "honey" then
		t.status.honey = true
		self:emit("effect", { unit = t.id, effect = "honey" })
	elseif eff == "push" then
		if t.def.boss then
			self:emit("float", { unit = t.id, text = "Standhaft!", style = "info" })
			return
		end
		local dx, dz = pushDir(a.x, a.z, t)
		self:pushUnit(t, dx, dz, a.def.weapon.push or 1, a)
	end
	if t.alive then
		self:emitStatus(t)
	end
end

function Rules:doShot(a, t, reaction: boolean?)
	local info = self:shotInfo(a, a.x, a.z, t)
	local w = a.def.weapon
	local hit = self.rng() * 100 < info.chance
	if a.team == "hero" then
		self.stats.shots += 1
		if hit then
			self.stats.hits += 1
		end
	end
	local ev = { attacker = a.id, target = t.id, hit = hit, melee = w.melee == true, reaction = reaction == true }
	if not hit and info.coverTile and info.coverTile.type ~= "floor" then
		ev.coverX, ev.coverZ, ev.coverWall = info.coverTile.x, info.coverTile.z, info.coverTile.type == "wall"
	end
	self:emit("shot", ev)
	if hit then
		local dmg = self:randInt(w.min, w.max)
		if reaction then
			dmg = round(dmg * 0.8)
		end
		self:applyDamage(t, dmg, a)
		if t.alive and w.effect and self.rng() < w.chance then
			self:applyEffect(a, t, w.effect)
		end
	else
		self:emit("float", { unit = t.id, text = "Verfehlt", style = "miss" })
		if info.cover == 1 and info.coverTile then
			self:damageCover(info.coverTile)
		end
	end
end

-- Läuft einen Pfad ab; bei Gegnern kann Leos Wachsamkeit den Lauf unterbrechen
function Rules:walk(u, path, checkOverwatch: boolean?): boolean
	for _, p in ipairs(path) do
		u.x, u.z = p[1], p[2]
		self:emit("step", { unit = u.id, x = u.x, z = u.z })
		if checkOverwatch and self:checkOverwatch(u) then
			return false
		end
		if not u.alive then
			return false
		end
	end
	return true
end

function Rules:checkOverwatch(enemy): boolean
	for _, h in ipairs(self:heroes()) do
		if h.status.overwatch and enemy.alive then
			local info = self:shotInfo(h, h.x, h.z, enemy)
			if info.chance > 0 then
				h.status.overwatch = false
				self:emit("float", { unit = h.id, text = "Wachsamkeit!", style = "info" })
				self:emitStatus(h)
				self:doShot(h, enemy, true)
				if not enemy.alive then
					return true
				end
			end
		end
	end
	return false
end

-- ------------------------------------------------------------------ hero actions (each returns its events)

function Rules:heroWalk(h, x: number, z: number)
	self:begin()
	self:walk(h, self:findPath(h, x, z))
	h.moved = true
	return self:finish()
end

function Rules:heroJump(h, j)
	self:begin()
	self:walk(h, self:findPath(h, j.via.x, j.via.z))
	self:emit("jump", { unit = h.id, via = j.via.id, x = j.x, z = j.z })
	h.x, h.z = j.x, j.z
	h.moved = true
	return self:finish()
end

function Rules:heroStomp(h, s)
	self:begin()
	local e = s.enemy
	self:walk(h, self:findPath(h, s.via.x, s.via.z))
	self:emit("stomp", { unit = h.id, via = s.via.id, target = e.id, x = e.x, z = e.z })
	self:applyDamage(e, self.C.STOMP_DMG, h)
	local land = self:freeTileNear(e.x, e.z, s.via) or self:tileAt(s.via.x, s.via.z)
	self:emit("land", { unit = h.id, x = land.x, z = land.z })
	h.x, h.z = land.x, land.z
	h.moved = true
	return self:finish()
end

function Rules:heroDash(h, d)
	self:begin()
	local e = d.enemy
	self:walk(h, self:findPath(h, d.stand.x, d.stand.z))
	self:emit("dash", { unit = h.id, target = e.id })
	self:applyDamage(e, h.def.dash, h)
	h.dashUsed = true
	return self:finish()
end

function Rules:heroAttack(h, e)
	self:begin()
	h.attacked = true
	h.moved = true
	self:doShot(h, e)
	return self:finish()
end

function Rules:heroTech(h)
	self:begin()
	local t = h.def.tech
	h.techUsed = true
	h.cd = t.cd
	local _, radius = self:techArea(h)
	self:emit("tech", { unit = h.id, tech = t.id, radius = radius })
	if t.id == "overwatch" then
		h.status.overwatch = true
		self:emitStatus(h)
	elseif t.id == "shield" then
		for _, a in ipairs(self:heroes()) do
			if math.sqrt((a.x - h.x) ^ 2 + (a.z - h.z) ^ 2) <= t.radius + 1e-6 then
				a.status.shield = true
				self:emit("float", { unit = a.id, text = "Bollwerk", style = "info" })
				self:emitStatus(a)
			end
		end
	elseif t.id == "heal" then
		for _, a in ipairs(self:heroes()) do
			if math.sqrt((a.x - h.x) ^ 2 + (a.z - h.z) ^ 2) <= t.radius + 1e-6 then
				local before = a.hp
				a.hp = math.min(a.maxHp, a.hp + t.amount)
				a.status.burn = false
				self:emit("heal", { unit = a.id, amount = a.hp - before, hp = a.hp })
				self:emitStatus(a)
			end
		end
	end
	return self:finish()
end

-- ------------------------------------------------------------------ turns

function Rules:tickStatuses(team: string)
	for _, u in ipairs(self.units) do
		if u.team == team and u.alive then
			if u.status.burn then
				u.status.burn = false
				self:emit("burn", { unit = u.id })
				self:applyDamage(u, self.C.BURN_DMG, nil)
			end
			if u.alive and u.status.honey then
				u.status.honey = false
				u.stuck = true
			end
			if u.alive then
				self:emitStatus(u)
			end
		end
	end
end

function Rules:_startPlayerTurn(first: boolean)
	if not first then
		self.turn += 1
	end
	self.phase = "player"
	for _, h in ipairs(self:heroList()) do
		h.status.shield = false
		h.status.overwatch = false
		if h.cd > 0 then
			h.cd -= 1
		end
		h.moved, h.attacked, h.techUsed, h.dashUsed, h.stuck = false, false, false, false, false
		h.ox, h.oz = h.x, h.z
	end
	self:emit("turn", { phase = "player", round = self.turn, first = first })
	self:tickStatuses("hero")
	for _, h in ipairs(self:heroes()) do
		if h.stuck then
			h.moved = true
		end
	end
end

function Rules:startPlayerTurn(first: boolean)
	self:begin()
	self:_startPlayerTurn(first)
	return self:finish()
end

-- Beendet den Spielerzug: Gegnerzug komplett auflösen und den nächsten Spielerzug vorbereiten
function Rules:endTurn()
	self:begin()
	self.phase = "enemy"
	self:emit("turn", { phase = "enemy", round = self.turn })
	self:tickStatuses("enemy")
	if not self:result() then
		local order = self:foes()
		table.sort(order, function(a, b)
			local sa = if a.kind == "sniper" then 0 else 1
			local sb = if b.kind == "sniper" then 0 else 1
			if sa ~= sb then
				return sa < sb
			end
			return a.id < b.id
		end)
		for _, e in ipairs(order) do
			if e.alive then
				self:enemyAct(e)
				if self:result() then
					break
				end
			end
		end
	end
	for _, e in ipairs(self.units) do
		if e.team == "enemy" and e.stuck then
			e.stuck = false
			if e.alive then
				self:emitStatus(e)
			end
		end
	end
	if not self:result() then
		self:_startPlayerTurn(false)
	end
	return self:finish()
end

-- ------------------------------------------------------------------ enemy AI

function Rules:overwatchThreat(x: number, z: number): boolean
	for _, h in ipairs(self:heroes()) do
		if h.status.overwatch and math.sqrt((h.x - x) ^ 2 + (h.z - z) ^ 2) <= h.def.weapon.range and self:hasLOS(h.x, h.z, x, z) then
			return true
		end
	end
	return false
end

function Rules:evalTile(e, x: number, z: number): number
	local w = e.def.weapon
	local avg = (w.min + w.max) / 2
	local bestAtk, safety, minD = 0, 0, math.huge
	for _, h in ipairs(self:heroes()) do
		local info = self:shotInfo(e, x, z, h)
		if info.chance > 0 then
			local dmg = avg * (if h.status.shield then 0.5 else 1)
			local v = info.chance / 100 * dmg
			if dmg >= h.hp then
				v += 25 * info.chance / 100
			end
			bestAtk = math.max(bestAtk, v)
		end
		local dd = math.sqrt((h.x - x) ^ 2 + (h.z - z) ^ 2)
		minD = math.min(minD, dd)
		if dd <= h.def.weapon.range + h.move * 0.6 then
			if not self:hasLOS(h.x, h.z, x, z) then
				safety += 6
			else
				local cv = self:coverInfo(x, z, h.x, h.z).value
				safety += if cv == 2 then 7 elseif cv == 1 then 3 else -4
			end
		end
	end
	local s = bestAtk + safety * (if w.melee then 0.25 else 1)
	if bestAtk == 0 then
		s -= minD * 2.4
	end
	if e.kind == "sniper" and bestAtk > 0 then
		s += math.min(minD, 8) * 0.6
	end
	if self:overwatchThreat(x, z) then
		s -= 6
	end
	return s + self.rng() * 2
end

function Rules:kingSpecials(e)
	if not self.kingRaged and e.hp <= e.maxHp / 2 then
		self.kingRaged = true
		self:emit("banner", { title = "Verstärkung!", sub = "Der König ruft seine Garde", foe = true })
		for _, p in ipairs(self.reinf) do
			local spot = if self:unitAt(p[1], p[2]) then self:freeTileNear(p[1], p[2]) else self:tileAt(p[1], p[2])
			if spot then
				local g = self:addUnit("enemy", "grunt", spot.x, spot.z)
				self:emit("spawn", { unit = g.id, kind = g.kind, x = g.x, z = g.z })
			end
		end
	end
	local near = {}
	for _, h in ipairs(self:heroes()) do
		if math.sqrt((h.x - e.x) ^ 2 + (h.z - e.z) ^ 2) <= 2.5 then
			table.insert(near, h)
		end
	end
	if #near > 0 and e.shockCd <= 0 then
		e.shockCd = 2
		self:emit("shock", { unit = e.id, radius = 2.6 })
		for _, h in ipairs(near) do
			if h.alive then
				self:applyDamage(h, self.C.SHOCK_DMG, e, true)
				if h.alive then
					local dx, dz = pushDir(e.x, e.z, h)
					self:pushUnit(h, dx, dz, 1, e)
				end
			end
		end
	elseif e.shockCd > 0 then
		e.shockCd -= 1
	end
end

function Rules:enemyAct(e)
	self:emit("enemyStart", { unit = e.id })
	if e.def.boss then
		self:kingSpecials(e)
		if self:result() then
			return
		end
	end
	if not e.stuck then
		local dist, prev = self:bfs(e, e.x, e.z, e.move)
		local bestX, bestZ, bestScore = e.x, e.z, self:evalTile(e, e.x, e.z) + 0.5
		-- feste Reihenfolge der Kandidaten, damit Läufe mit gleichem Zufallsstartwert gleich ablaufen
		local keys = {}
		for k in pairs(dist) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local x, z = unkey(k)
			if not (x == e.x and z == e.z) and not self:unitAt(x, z) then
				local sc = self:evalTile(e, x, z) - dist[k] * 0.25
				if sc > bestScore then
					bestX, bestZ, bestScore = x, z, sc
				end
			end
		end
		if bestX ~= e.x or bestZ ~= e.z then
			local path = buildPath(prev, e.x, e.z, bestX, bestZ) or {}
			self:walk(e, path, true)
			if self:result() then
				return
			end
		end
	else
		self:emit("float", { unit = e.id, text = "Klebt fest!", style = "info" })
	end
	if not e.alive then
		return
	end
	local w = e.def.weapon
	local avg = (w.min + w.max) / 2
	local target, tv = nil, 0
	for _, h in ipairs(self:heroes()) do
		local info = self:shotInfo(e, e.x, e.z, h)
		if info.chance > 0 then
			local v = info.chance / 100 * avg * (if h.status.shield then 0.5 else 1)
				+ (if avg >= h.hp then 30 else 0)
				+ (1 - h.hp / h.maxHp) * 8
			if v > tv then
				tv = v
				target = h
			end
		end
	end
	if target then
		self:doShot(e, target)
	end
	self:emit("enemyEnd", { unit = e.id })
end

return Rules
