-- Testablauf für den Client in der Roblox-Nachbildung (siehe tools/run_client_test.py).
-- Startet Server- und Client-Skript, klickt sich wie ein Spieler durch Menüs, Garderobe und alle drei Kämpfe
-- und meldet jeden Laufzeitfehler und jede Warnung.

local UIS = Mock.UIS
local RS = Mock.ReplicatedStorage

-- Projektstruktur wie in default.project.json nachbauen
local shared = Mock.newInstance("Folder")
shared.Name = "Krawall"
shared.Parent = RS
for _, n in ipairs({ "Config", "Skins", "Rules" }) do
	Mock.module(n, __src["shared/" .. n]).Parent = shared
end

-- Zugriff auf den Spielzustand des Clients: Rules.new mitschneiden
local G = nil
Mock.onRequire = function(m, result)
	if m.Name == "Rules" then
		local orig = result.new
		result.new = function(...)
			G = orig(...)
			return G
		end
	end
end

local serverScript = Mock.scriptInstance("Script", "Progress")
task.spawn(function()
	__src["server/Progress"](serverScript)
end)

local clientScript = Mock.scriptInstance("LocalScript", "KrawallClient")
for _, n in ipairs({ "Fx", "Models", "Board", "Ui" }) do
	Mock.module(n, __src["client/" .. n]).Parent = clientScript
end
task.spawn(function()
	__src["client/init"](clientScript)
end)
Mock.run(1)

-- ------------------------------------------------------------------ helpers

local function visible(inst)
	local p = inst
	while p and p ~= Mock.playerGui do
		local cls = p.ClassName
		if cls == "ScreenGui" then
			if p.Enabled == false then
				return false
			end
		elseif (cls == "Frame" or cls == "TextButton" or cls == "TextLabel" or cls == "ViewportFrame") and p.Visible == false then
			return false
		end
		p = p.Parent
	end
	return p == Mock.playerGui
end

local function findButton(text)
	for _, d in ipairs(Mock.playerGui:GetDescendants()) do
		if d.ClassName == "TextButton" and d.Text == text and visible(d) then
			return d
		end
	end
	return nil
end

local function findButtonWithLabel(text)
	for _, d in ipairs(Mock.playerGui:GetDescendants()) do
		if d.ClassName == "TextButton" and visible(d) then
			for _, c in ipairs(d:GetChildren()) do
				if c.ClassName == "TextLabel" and c.Text == text then
					return d
				end
			end
		end
	end
	return nil
end

local checks = 0
local function check(cond, msg)
	checks += 1
	if not cond then
		table.insert(Mock.errors, "PRÜFUNG: " .. msg)
		print("[prüfung] " .. msg)
	end
end

local function click(text)
	local b = findButton(text)
	check(b ~= nil, "Knopf '" .. text .. "' sichtbar")
	if b then
		b.MouseButton1Down:Fire()
		b.Activated:Fire()
		Mock.run(0.2)
	end
end

local function screenVisible(name)
	local menus = Mock.playerGui:FindFirstChild("KrawallMenus")
	if not menus or menus.Enabled == false then
		return false
	end
	local f = menus:FindFirstChild(name)
	return f ~= nil and f.Visible ~= false
end

local OFF = Color3.fromHex("#43375e")
local function idle()
	for _, d in ipairs(Mock.playerGui:GetDescendants()) do
		if d.ClassName == "TextButton" and (d.Text == "Zug beenden" or d.Text == "Zug beenden!") then
			return visible(d) and not (d.BackgroundColor3 == OFF)
		end
	end
	return false
end

local function waitUntil(cond, maxSeconds)
	local t = 0
	while not cond() do
		Mock.step(1 / 30)
		t += 1 / 30
		if t > maxSeconds then
			return false
		end
	end
	return true
end

local function settle()
	return waitUntil(function()
		return idle() or screenVisible("ending")
	end, 120)
end

local function key(name)
	local inp = Mock.input("Keyboard", { KeyCode = Enum.KeyCode[name] })
	UIS.InputBegan:Fire(inp, false)
	UIS.InputEnded:Fire(inp, false)
	Mock.step(1 / 30)
end

local world = Mock.workspace:FindFirstChild("KrawallWelt")
local function tilePart(x, z)
	for _, d in ipairs(world:GetDescendants()) do
		if d.ClassName == "Part" and d:GetAttribute("TX") == x and d:GetAttribute("TZ") == z and d.CanQuery then
			return d
		end
	end
	return nil
end

local function unitPart(id)
	for _, d in ipairs(world:GetDescendants()) do
		if d.ClassName == "Part" and d:GetAttribute("UnitId") == id and d.CanQuery then
			return d
		end
	end
	return nil
end

local function hover(part)
	Mock.nextHit = part
	UIS.InputChanged:Fire(Mock.input("MouseMovement", { Position = Vector3.new(300 + math.random() * 80, 250, 0) }), false)
	Mock.step(1 / 30)
end

local function clickPart(part, touch)
	check(part ~= nil, "Klickziel vorhanden")
	Mock.nextHit = part
	if touch then
		for _ = 1, 2 do
			local inp = Mock.input("Touch")
			UIS.InputBegan:Fire(inp, false)
			UIS.InputEnded:Fire(inp, false)
			Mock.step(1 / 30)
		end
	else
		local inp = Mock.input("MouseButton1")
		UIS.InputBegan:Fire(inp, false)
		UIS.InputEnded:Fire(inp, false)
		Mock.step(1 / 30)
	end
end

local function cameraGestures()
	-- Drehen mit rechter Maustaste, Zoomen, Pinch, Tasten
	local down = Mock.input("MouseButton2", { Position = Vector3.new(500, 300, 0) })
	UIS.InputBegan:Fire(down, false)
	for i = 1, 5 do
		UIS.InputChanged:Fire(Mock.input("MouseMovement", { Position = Vector3.new(500 + i * 12, 300 + i * 4, 0) }), false)
		Mock.step(1 / 30)
	end
	UIS.InputEnded:Fire(down, false)
	UIS.InputChanged:Fire(Mock.input("MouseWheel", { Position = Vector3.new(0, 0, 1) }), false)
	UIS.InputChanged:Fire(Mock.input("MouseWheel", { Position = Vector3.new(0, 0, -1) }), false)
	UIS.TouchPinch:Fire({}, 1, 0, Enum.UserInputState.Begin, false)
	UIS.TouchPinch:Fire({}, 1.3, 0, Enum.UserInputState.Change, false)
	UIS.TouchPinch:Fire({}, 1.3, 0, Enum.UserInputState.End, false)
	local w = Mock.input("Keyboard", { KeyCode = Enum.KeyCode.W })
	UIS.InputBegan:Fire(w, false)
	Mock.run(0.3)
	UIS.InputEnded:Fire(w, false)
	key("Q")
	key("E")
	Mock.run(0.2)
end

-- ------------------------------------------------------------------ bot

local used = { walk = 0, jump = 0, dash = 0, stomp = 0, shot = 0, tech = 0, touch = 0, hoverEnemy = 0 }
local rng = Random.new(99)

local function chooseMove(h)
	local o = G:computeMoveOptions(h)
	local best, bestSc = nil, -math.huge
	local cands = {}
	for _, v in pairs(o.walk) do
		if not (v.x == h.x and v.z == h.z) then
			table.insert(cands, { x = v.x, z = v.z })
		end
	end
	for _, v in pairs(o.jump) do
		table.insert(cands, { x = v.x, z = v.z, jump = true })
	end
	for _, c in ipairs(cands) do
		local sc, near = 0, math.huge
		for _, e in ipairs(G:foes()) do
			sc = math.max(sc, G:shotInfo(h, c.x, c.z, e).chance)
			near = math.min(near, math.sqrt((e.x - c.x) ^ 2 + (e.z - c.z) ^ 2))
		end
		sc = sc * 2 - near + rng:NextNumber() + (if c.jump then 0.5 else 0)
		if sc > bestSc then
			bestSc, best = sc, c
		end
	end
	return o, best
end

local function anyKey(map)
	local keys = {}
	for k in pairs(map) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return map[keys[1]]
end

local function heroTurn(i)
	local h = G:heroList()[i]
	if not h.alive or G:result() then
		return
	end
	key(({ "One", "Two", "Three" })[i])
	settle()
	if G:result() then
		return
	end
	local o = G:computeMoveOptions(h)
	-- Gegner überfahren: Gefahrenzone und Tooltip
	local foe = G:foes()[1]
	if foe and unitPart(foe.id) then
		hover(unitPart(foe.id))
		used.hoverEnemy += 1
	end
	local touch = rng:NextNumber() < 0.25
	if next(o.stomp) and rng:NextNumber() < 0.35 then
		local s = anyKey(o.stomp)
		hover(unitPart(s.enemy.id))
		clickPart(unitPart(s.enemy.id), touch)
		used.stomp += 1
	else
		if next(o.dash) and rng:NextNumber() < 0.4 then
			local d = anyKey(o.dash)
			clickPart(unitPart(d.enemy.id), touch)
			used.dash += 1
			settle()
			if G:result() then
				return
			end
		end
		local _, best = chooseMove(h)
		if best then
			hover(tilePart(best.x, best.z))
			clickPart(tilePart(best.x, best.z), touch)
			if best.jump then
				used.jump += 1
			else
				used.walk += 1
			end
		end
	end
	if touch then
		used.touch += 1
	end
	settle()
	if G:result() or not h.alive then
		return
	end
	if not h.attacked then
		key("F")
		local tgt, tc = nil, 0
		for _, e in ipairs(G:foes()) do
			local c = G:shotInfo(h, h.x, h.z, e).chance
			if c > tc then
				tc, tgt = c, e
			end
		end
		if tgt then
			hover(unitPart(tgt.id))
			clickPart(unitPart(tgt.id), false)
			used.shot += 1
			settle()
		else
			key("X")
		end
	end
	if G:result() or not h.alive then
		return
	end
	if not h.techUsed and h.cd == 0 and rng:NextNumber() < 0.6 then
		key("T")
		hover(tilePart(h.x, h.z))
		key("T")
		used.tech += 1
		settle()
	end
end

local function playLevel(label, cheat)
	check(waitUntil(idle, 30), label .. ": Spielerzug beginnt")
	local rounds = 0
	while not screenVisible("ending") and rounds < 25 do
		rounds += 1
		if cheat then
			cheat(G, rounds)
		end
		for i = 1, 3 do
			heroTurn(i)
			if screenVisible("ending") or G:result() then
				break
			end
		end
		if G:result() then
			break
		end
		if rounds == 2 then
			cameraGestures()
		end
		if idle() then
			key("Return")
		end
		settle()
	end
	check(waitUntil(function()
		return screenVisible("ending")
	end, 10), label .. ": Endbildschirm erscheint")
	return G:result()
end

-- ------------------------------------------------------------------ Ablauf

check(screenVisible("title"), "Titelbildschirm sichtbar")
click("So spielst du")
check(screenVisible("help"), "Regeln sichtbar")
click("Verstanden")
check(screenVisible("title"), "zurück zum Titel")

-- Garderobe vor dem ersten Sieg: nur Standard-Skins, gesperrte Skins nicht ausrüstbar
click("Helden-Skins")
check(screenVisible("skins"), "Garderobe sichtbar")
local feuer = findButtonWithLabel("Feuerritter")
check(feuer ~= nil, "Skin-Eintrag Feuerritter sichtbar")
if feuer then
	feuer.Activated:Fire()
	Mock.run(0.1)
end
check(findButton("Gesperrt") ~= nil, "gesperrter Skin zeigt 'Gesperrt'")
click("Zurück")

-- Kampf 1
click("Spielen")
check(waitUntil(idle, 30), "Kampf 1 startet")
click("?")
check(screenVisible("help"), "Hilfe im Kampf")
click("Verstanden")
click("II")
check(screenVisible("pause"), "Pause sichtbar")
click("Weiter")
click("1×")
click("2×")
click("3×")
click("Ton")
click("Stumm")
local r1 = playLevel("Kampf 1", function(g, round)
	if round == 3 then
		for _, e in ipairs(g:foes()) do
			e.hp = math.min(e.hp, 12)
		end
	end
end)
check(r1 == "win", "Kampf 1 gewonnen (mit Hilfe)")
check(findButton("Nächster Kampf") ~= nil, "Knopf 'Nächster Kampf'")
-- neue Skins direkt aus dem Endbildschirm ausrüsten
click("Garderobe")
check(screenVisible("skins"), "Garderobe vom Endbildschirm")
for _, heroName in ipairs({ "Leo", "Bruna", "Pip" }) do
	click(heroName)
	local second = ({ Leo = "Feuerritter", Bruna = "Lavaschmiedin", Pip = "Schattenninja" })[heroName]
	local b = findButtonWithLabel(second)
	check(b ~= nil, "Skin " .. second .. " sichtbar")
	if b then
		b.Activated:Fire()
		Mock.run(0.1)
	end
	click("Ausrüsten")
	check(findButton("Ausgerüstet") ~= nil, second .. " ausgerüstet")
end
click("Zurück")
check(screenVisible("ending"), "zurück zum Endbildschirm")

-- Kampf 2 mit neuen Skins
click("Nächster Kampf")
local r2 = playLevel("Kampf 2", function(g, round)
	if round == 4 then
		for _, e in ipairs(g:foes()) do
			e.hp = math.min(e.hp, 12)
		end
	end
end)
check(r2 == "win", "Kampf 2 gewonnen (mit Hilfe)")

-- Kampf 3: König in Raserei bringen (Verstärkung), dann gewinnen
click("Nächster Kampf")
local spawnedBefore = 0
local r3 = playLevel("Kampf 3", function(g, round)
	if round == 1 then
		spawnedBefore = #g.units
		for _, h in ipairs(g:heroes()) do
			h.maxHp, h.hp = 999, 999
		end
	end
	if round == 2 then
		for _, e in ipairs(g:foes()) do
			if e.kind == "king" then
				e.hp = math.min(e.hp, 150)
			end
		end
		for _, h in ipairs(g:heroes()) do
			h.hp = h.maxHp
		end
	end
	if round == 3 then
		for _, e in ipairs(g:foes()) do
			e.hp = math.min(e.hp, 10)
		end
	end
end)
check(#G.units > spawnedBefore, "König hat Verstärkung gerufen")
check(r3 == "win", "Kampf 3 gewonnen (mit Hilfe)")
check(findButton("Nochmal von vorn") ~= nil, "Finale: 'Nochmal von vorn'")

-- alle 12 Skins in der Garderobe ansehen (baut jedes Modell) und die letzten ausrüsten
click("Hauptmenü")
check(screenVisible("title"), "Titel nach dem Finale")
click("Helden-Skins")
local SKIN_NAMES = {
	Leo = { "Abenteurer", "Feuerritter", "Kapitän Leo", "Sternenheld" },
	Bruna = { "Brecherin", "Lavaschmiedin", "Eiswächterin", "Goldene Bruna" },
	Pip = { "Späherin", "Schattenninja", "Astronautin", "Regenbogen-Pip" },
}
for _, heroName in ipairs({ "Leo", "Bruna", "Pip" }) do
	click(heroName)
	for _, skinName in ipairs(SKIN_NAMES[heroName]) do
		local b = findButtonWithLabel(skinName)
		check(b ~= nil, "Skin " .. skinName .. " in der Liste")
		if b then
			b.Activated:Fire()
			Mock.run(0.05)
		end
	end
	click("Ausrüsten")
end
click("Zurück")

-- Niederlage prüfen: Helden fast K.O., Gegner greifen an
local lvl1 = findButtonWithLabel("Pilzwiese")
check(lvl1 ~= nil, "Levelkarte Pilzwiese")
if lvl1 then
	lvl1.Activated:Fire()
	Mock.run(0.2)
end
click("Spielen")
check(waitUntil(idle, 30), "Kampf 1 erneut gestartet")
for _, h in ipairs(G:heroes()) do
	h.hp = 1
end
for _, e in ipairs(G:foes()) do
	e.def = table.clone(e.def)
	e.def.weapon = table.clone(e.def.weapon)
	e.def.weapon.range = 30
	e.move = 8
end
key("Return")
settle()
check(waitUntil(function()
	return screenVisible("ending")
end, 60), "Niederlage zeigt Endbildschirm")
check(G:result() == "lose", "Ergebnis ist Niederlage")
check(findButton("Nochmal versuchen") ~= nil, "Knopf 'Nochmal versuchen'")
click("Nochmal versuchen")
check(waitUntil(idle, 30), "Neustart nach Niederlage")
click("II")
click("Neu starten")
check(waitUntil(idle, 30), "Neustart aus der Pause")
click("II")
click("Hauptmenü")
check(screenVisible("title"), "Hauptmenü aus der Pause")

-- Speichern beim Verlassen
Mock.Players.PlayerRemoving:Fire(Mock.Players.LocalPlayer)
Mock.run(0.5)
local saved = Mock.storeData["p_4242"]
check(saved ~= nil and saved.won == 3, "Fortschritt gespeichert (3 Siege)")
check(saved ~= nil and saved.skins.leo == "sternenheld", "Skin-Auswahl gespeichert")

print(string.format(
	"Aktionen: laufen %d, Teamsprung %d, Sprint %d, Sprungangriff %d, Schüsse %d, Techniken %d, Touch %d, Gegner-Hover %d, Raycasts %d",
	used.walk, used.jump, used.dash, used.stomp, used.shot, used.tech, used.touch, used.hoverEnemy, Mock.raycasts
))
print(string.format("%d Prüfungen, %d Fehler, %d Warnungen", checks, #Mock.errors, #Mock.warnings))
if #Mock.errors > 0 or #Mock.warnings > 0 then
	error("Client-Test fehlgeschlagen")
end
print("Client-Test bestanden")
