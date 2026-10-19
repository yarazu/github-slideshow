-- Headless-Test der Spielregeln mit dem Luau-Interpreter:
--   luau tests/simulate.luau
-- Spielt viele Partien pro Level mit einem einfachen Bot und einem Zufalls-Bot und prüft nach jeder Aktion Invarianten.

local Config = require("../src/shared/Config")
local Rules = require("../src/shared/Rules")
local Skins = require("../src/shared/Skins")

local EVENT_KINDS = {
	step = true, jump = true, stomp = true, land = true, dash = true, shot = true, damage = true, ko = true,
	effect = true, float = true, cover = true, fall = true, bump = true, slide = true, respawn = true, tech = true,
	heal = true, status = true, turn = true, burn = true, shock = true, spawn = true, banner = true,
	enemyStart = true, enemyEnd = true,
}

local failures = 0
local function fail(msg)
	failures += 1
	if failures <= 20 then
		print("FEHLER: " .. msg)
	end
end

-- deterministischer Zufall (LCG), damit Fehler reproduzierbar sind
local function makeRng(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

local function checkInvariants(G, events, label)
	local seen = {}
	for _, u in ipairs(G.units) do
		if u.alive then
			local t = G:tileAt(u.x, u.z)
			if not t or t.type ~= "floor" then
				fail(label .. ": " .. u.name .. " steht auf ungültigem Feld " .. u.x .. "," .. u.z)
			end
			local k = Rules.key(u.x, u.z)
			if seen[k] then
				fail(label .. ": zwei Einheiten auf " .. u.x .. "," .. u.z)
			end
			seen[k] = true
		end
		if u.hp < 0 or u.hp > u.maxHp then
			fail(label .. ": HP außerhalb des Bereichs bei " .. u.name)
		end
		if u.alive and u.hp == 0 then
			fail(label .. ": " .. u.name .. " hat 0 LP und lebt")
		end
	end
	for _, ev in ipairs(events) do
		if not EVENT_KINDS[ev.kind] then
			fail(label .. ": unbekanntes Ereignis " .. tostring(ev.kind))
		end
		if ev.unit and not G.byId[ev.unit] then
			fail(label .. ": Ereignis " .. ev.kind .. " verweist auf unbekannte Einheit")
		end
		if ev.target and not G.byId[ev.target] then
			fail(label .. ": Ereignis " .. ev.kind .. " verweist auf unbekanntes Ziel")
		end
	end
end

local function count(map)
	local n = 0
	for _ in pairs(map) do
		n += 1
	end
	return n
end

local function values(map)
	local out = {}
	for _, v in pairs(map) do
		table.insert(out, v)
	end
	table.sort(out, function(a, b)
		return (a.x or a.enemy.x) * 100 + (a.z or a.enemy.z) < (b.x or b.enemy.x) * 100 + (b.z or b.enemy.z)
	end)
	return out
end

local used = { walk = 0, jump = 0, dash = 0, stomp = 0, shot = 0, tech = 0 }

-- Bot wie im Browser-Test: sucht Felder mit guter Trefferchance, nutzt Sprung/Sprint/Technik
local function smartTurn(G, rng, label)
	for _, h in ipairs(G:heroes()) do
		if G:result() then
			return
		end
		if h.alive then
			local o = G:computeMoveOptions(h)
			local ev
			if count(o.stomp) > 0 and rng() < 0.3 then
				ev = G:heroStomp(h, values(o.stomp)[1])
				used.stomp += 1
				checkInvariants(G, ev, label .. " stomp")
			else
				if count(o.dash) > 0 and rng() < 0.4 then
					ev = G:heroDash(h, values(o.dash)[1])
					used.dash += 1
					checkInvariants(G, ev, label .. " dash")
					if G:result() then
						return
					end
				end
				local o2 = G:computeMoveOptions(h)
				local best, bestSc = nil, -math.huge
				local cands = {}
				for _, v in pairs(o2.walk) do
					table.insert(cands, { x = v.x, z = v.z })
				end
				for _, v in pairs(o2.jump) do
					table.insert(cands, { x = v.x, z = v.z, jump = v })
				end
				table.sort(cands, function(a, b)
					return a.x * 100 + a.z < b.x * 100 + b.z
				end)
				for _, c in ipairs(cands) do
					local sc = 0
					local near = math.huge
					for _, e in ipairs(G:foes()) do
						sc = math.max(sc, G:shotInfo(h, c.x, c.z, e).chance)
						near = math.min(near, math.sqrt((e.x - c.x) ^ 2 + (e.z - c.z) ^ 2))
					end
					sc = sc * 2 - near + rng() + (if c.jump then 0.5 else 0)
					if sc > bestSc then
						bestSc = sc
						best = c
					end
				end
				if best and not (best.x == h.x and best.z == h.z) then
					if best.jump then
						ev = G:heroJump(h, best.jump)
						used.jump += 1
					else
						ev = G:heroWalk(h, best.x, best.z)
						used.walk += 1
					end
					checkInvariants(G, ev, label .. " move")
				end
			end
			if G:result() then
				return
			end
			if h.alive and not h.attacked then
				local tgt, tc = nil, 0
				for _, e in ipairs(G:foes()) do
					local c = G:shotInfo(h, h.x, h.z, e).chance
					if c > tc then
						tc = c
						tgt = e
					end
				end
				if tgt then
					ev = G:heroAttack(h, tgt)
					used.shot += 1
					checkInvariants(G, ev, label .. " shot")
				end
			end
			if G:result() then
				return
			end
			if h.alive and not h.techUsed and h.cd == 0 and rng() < 0.6 then
				ev = G:heroTech(h)
				used.tech += 1
				checkInvariants(G, ev, label .. " tech")
			end
		end
	end
end

-- Zufalls-Bot: wählt beliebige erlaubte Aktionen, um Randfälle zu treffen
local function randomTurn(G, rng, label)
	for _ = 1, 8 do
		if G:result() then
			return
		end
		local hs = G:heroes()
		local h = hs[1 + math.floor(rng() * #hs)]
		local roll = rng()
		local ev = nil
		if roll < 0.45 and not h.moved then
			local o = G:computeMoveOptions(h)
			local pool = {}
			for _, v in pairs(o.walk) do
				if not (v.x == h.x and v.z == h.z) then
					table.insert(pool, { "walk", v })
				end
			end
			for _, v in pairs(o.jump) do
				table.insert(pool, { "jump", v })
			end
			for _, v in pairs(o.dash) do
				table.insert(pool, { "dash", v })
			end
			for _, v in pairs(o.stomp) do
				table.insert(pool, { "stomp", v })
			end
			table.sort(pool, function(a, b)
				local ax = a[2].x or a[2].enemy.x
				local az = a[2].z or a[2].enemy.z
				local bx = b[2].x or b[2].enemy.x
				local bz = b[2].z or b[2].enemy.z
				if a[1] ~= b[1] then
					return a[1] < b[1]
				end
				return ax * 100 + az < bx * 100 + bz
			end)
			if #pool > 0 then
				local pick = pool[1 + math.floor(rng() * #pool)]
				if pick[1] == "walk" then
					ev = G:heroWalk(h, pick[2].x, pick[2].z)
				elseif pick[1] == "jump" then
					ev = G:heroJump(h, pick[2])
				elseif pick[1] == "dash" then
					ev = G:heroDash(h, pick[2])
				else
					ev = G:heroStomp(h, pick[2])
				end
			end
		elseif roll < 0.8 and not h.attacked then
			for _, e in ipairs(G:foes()) do
				if G:shotInfo(h, h.x, h.z, e).chance > 0 then
					ev = G:heroAttack(h, e)
					break
				end
			end
		elseif not h.techUsed and h.cd == 0 then
			ev = G:heroTech(h)
		end
		if ev then
			checkInvariants(G, ev, label .. " zufall")
		end
	end
end

local function playGame(levelIndex, seed, botTurn)
	local rng = makeRng(seed)
	local G = Rules.new(Config, levelIndex, rng)
	local label = "Level " .. levelIndex .. " Seed " .. seed
	checkInvariants(G, G:startPlayerTurn(true), label .. " start")
	local guard = 0
	while not G:result() and guard < 60 do
		guard += 1
		botTurn(G, rng, label .. " R" .. G.turn)
		if G:result() then
			break
		end
		local ev = G:endTurn()
		checkInvariants(G, ev, label .. " Gegnerzug R" .. G.turn)
	end
	if not G:result() then
		fail(label .. ": kein Ergebnis nach 60 Runden")
	end
	return G:result(), G.turn, G
end

-- Gezielte Regel-Checks
do
	local G = Rules.new(Config, 1, makeRng(1))
	local leo = G:heroList()[1]
	local grunt = G:foes()[1]
	-- ohne Deckung, in Reichweite: 100 %
	leo.x, leo.z = 6, 4
	grunt.x, grunt.z = 6, 0
	local info = G:shotInfo(leo, leo.x, leo.z, grunt)
	if info.chance ~= 100 then
		fail("Freier Schuss sollte 100 % haben, war " .. info.chance)
	end
	-- Kiste (1,5) zwischen Schütze (1,8) und Ziel (1,4)? Kiste liegt an Ziel (1,5)->Deckung halb
	grunt.x, grunt.z = 1, 4
	leo.x, leo.z = 1, 8
	info = G:shotInfo(leo, leo.x, leo.z, grunt)
	if info.chance ~= 50 then
		fail("Kiste direkt vor dem Ziel sollte 50 % geben, war " .. info.chance .. " (" .. info.reason .. ")")
	end
	-- Mauer (4,6) direkt vor dem Ziel (4,5) -> volle Deckung
	grunt.x, grunt.z = 4, 5
	leo.x, leo.z = 4, 9
	info = G:shotInfo(leo, leo.x, leo.z, grunt)
	if info.chance ~= 0 or info.reason ~= "Volle Deckung" then
		fail("Mauer direkt vor dem Ziel sollte volle Deckung sein, war " .. info.chance .. " " .. info.reason)
	end
	-- Flanke: von der Seite zählt die Mauer nicht
	leo.x, leo.z = 0, 5
	info = G:shotInfo(leo, leo.x, leo.z, grunt)
	if info.chance ~= 100 then
		fail("Flankenschuss sollte 100 % haben, war " .. info.chance .. " " .. info.reason)
	end
	-- Reichweite
	leo.x, leo.z = 12, 11
	info = G:shotInfo(leo, leo.x, leo.z, grunt)
	if info.inRange then
		fail("Ziel sollte außer Reichweite sein")
	end
	-- Rückstoß ins Wasser kostet 50 LP und setzt die Einheit auf ein freies Feld
	local G2 = Rules.new(Config, 1, makeRng(2))
	local bruna = G2:heroList()[2]
	local foe = G2:foes()[1]
	foe.x, foe.z = 2, 0
	bruna.x, bruna.z = 3, 0
	G2:begin()
	G2:pushUnit(foe, -1, 0, 2, bruna)
	local ev = G2:finish()
	if foe.hp ~= foe.maxHp - Config.FALL_DMG then
		fail("Sturz ins Wasser sollte " .. Config.FALL_DMG .. " Schaden machen, LP " .. foe.hp)
	end
	if G2:tileAt(foe.x, foe.z).type ~= "floor" then
		fail("Nach dem Sturz sollte die Einheit auf Boden stehen")
	end
	checkInvariants(G2, ev, "Rückstoß-Test")
	-- Teamsprung: Optionen existieren am Start von Level 1
	local G3 = Rules.new(Config, 1, makeRng(3))
	G3:startPlayerTurn(true)
	local o = G3:computeMoveOptions(G3:heroList()[1])
	if count(o.jump) == 0 then
		fail("Leo sollte am Start Teamsprung-Felder haben")
	end
end

-- Skins: jeder Held hat 4 Skins mit eindeutigen IDs, Freischaltung 0..3
for heroKind, list in pairs(Skins.HEROES) do
	if #list ~= 4 then
		fail(heroKind .. " sollte 4 Skins haben")
	end
	local ids = {}
	for i, s in ipairs(list) do
		if ids[s.id] then
			fail("doppelte Skin-ID " .. s.id)
		end
		ids[s.id] = true
		if s.unlock ~= i - 1 then
			fail(s.id .. " hat unerwartete Freischaltung " .. s.unlock)
		end
	end
end

local GAMES = 60
for li = 1, #Config.LEVELS do
	local wins, losses, rounds = 0, 0, 0
	for seed = 1, GAMES do
		local res, turns = playGame(li, seed * 7919 + li, smartTurn)
		if res == "win" then
			wins += 1
			rounds += turns
		else
			losses += 1
		end
	end
	local rw, rl = 0, 0
	for seed = 1, GAMES do
		local res = playGame(li, seed * 104729 + li, randomTurn)
		if res == "win" then
			rw += 1
		else
			rl += 1
		end
	end
	print(
		string.format(
			"Level %d %-13s  Bot: %2d Siege / %2d Niederlagen (Ø %.1f Runden bei Sieg)   Zufall: %2d / %2d",
			li,
			Config.LEVELS[li].name,
			wins,
			losses,
			if wins > 0 then rounds / wins else 0,
			rw,
			rl
		)
	)
end
print(string.format("Aktionen: laufen %d, Teamsprung %d, Sprint %d, Sprungangriff %d, Schüsse %d, Techniken %d", used.walk, used.jump, used.dash, used.stomp, used.shot, used.tech))
if failures > 0 then
	print(failures .. " Fehler gefunden")
	error("Test fehlgeschlagen")
end
print("Alle Regel-Tests bestanden")
