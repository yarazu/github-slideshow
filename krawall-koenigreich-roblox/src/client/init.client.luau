-- Krawall-Königreich: Client-Steuerung.
-- Baut das Spielfeld, animiert die Ereignisse aus Rules.luau, steuert Kamera, Eingabe und Menüs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Krawall")
local Config = require(Shared:WaitForChild("Config"))
local Skins = require(Shared:WaitForChild("Skins"))
local Rules = require(Shared:WaitForChild("Rules"))
local Fx = require(script:WaitForChild("Fx"))
local Models = require(script:WaitForChild("Models"))
local Board = require(script:WaitForChild("Board"))
local Ui = require(script:WaitForChild("Ui"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local TILE = Config.TILE
local key = Rules.key

local function hex(c: string): Color3
	return Color3.fromHex(c)
end

local COL = {
	dash = hex("#ff8a2a"),
	stomp = hex("#ff5fd2"),
	c100 = hex("#5fd068"),
	c50 = hex("#ffc63d"),
	c0 = hex("#8d80a8"),
	range = hex("#ff5a4a"),
	area = hex("#5ee3d2"),
	gold = hex("#ffc63d"),
	white = Color3.new(1, 1, 1),
	foeShot = hex("#ff5fd2"),
	crate = hex("#c98a4b"),
}

-- Standard-Steuerung und Roblox-Oberflächen ausblenden, die das HUD verdecken (keine Spielfigur, jeder spielt für sich)
for _, t in ipairs({ Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu, Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Chat }) do
	pcall(function()
		StarterGui:SetCoreGuiEnabled(t, false)
	end)
end
task.spawn(function()
	pcall(function()
		local pm = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10) :: ModuleScript)
		pm:GetControls():Disable()
	end)
end)

local world = Instance.new("Folder")
world.Name = "KrawallWelt"
world.Parent = workspace
local fxFolder = Instance.new("Folder")
fxFolder.Name = "Effekte"
fxFolder.Parent = world
Fx.folder = fxFolder

-- ------------------------------------------------------------------ progress (Server speichert per DataStore)

local progress = { won = 0, best = {}, skins = table.clone(Skins.DEFAULTS) }
local remote = ReplicatedStorage:WaitForChild("KrawallProgress", 10) :: RemoteFunction?

local function loadProgress()
	if not remote then
		return
	end
	local ok, data = pcall(function()
		return remote:InvokeServer("load")
	end)
	if ok and type(data) == "table" then
		progress.won = math.clamp(tonumber(data.won) or 0, 0, #Config.LEVELS)
		if type(data.best) == "table" then
			progress.best = data.best
		end
		if type(data.skins) == "table" then
			for heroKind in pairs(Skins.DEFAULTS) do
				local want = data.skins[heroKind]
				if type(want) == "string" and Skins.isUnlocked(heroKind, want, progress.won) then
					progress.skins[heroKind] = want
				end
			end
		end
	end
end

local function saveProgress()
	if not remote then
		return
	end
	local snapshot = { won = progress.won, best = progress.best, skins = table.clone(progress.skins) }
	task.spawn(function()
		pcall(function()
			remote:InvokeServer("save", snapshot)
		end)
	end)
end

-- ------------------------------------------------------------------ state

local App = {
	phase = "title", -- title | player | enemy | over
	G = nil,
	board = nil,
	li = 1,
	pick = 1,
	selected = nil,
	mode = nil :: string?,
	busy = false,
	moveOpts = nil,
	hover = nil,
	touchPending = nil :: string?,
	run = 0,
	speed = 1,
	paused = false,
	helpReturn = nil :: string?,
	skinsReturn = nil :: string?,
}
local VU = {} -- Einheiten-ID -> Darstellung
local rnd = Random.new()
local ui

local cam = { yaw = 0, pitch = 0.95, dist = 70, target = Vector3.zero }
local goal = { yaw = 0, pitch = 0.95, dist = 70, target = Vector3.zero }

local function tp(x: number, z: number, y: number?): Vector3
	return App.board:tilePos(x, z, y)
end

local function unitTop(vu, extra: number?): Vector3
	return vu.pos + Vector3.new(0, vu.height + (extra or 0.8), 0)
end

local function faceTo(vu, p: Vector3)
	local dx, dz = p.X - vu.pos.X, p.Z - vu.pos.Z
	if math.abs(dx) + math.abs(dz) > 1e-3 then
		vu.yawGoal = math.atan2(-dx, -dz)
	end
end

local function muzzleWorld(vu): Vector3
	return vu.pos + CFrame.Angles(0, vu.yawGoal, 0):VectorToWorldSpace(vu.muzzle)
end

local function focus(p: Vector3, weight: number?)
	goal.target = Vector3.new(p.X, 0, p.Z) * (weight or 0.6)
end

-- ------------------------------------------------------------------ unit visuals

local function disc(color: Color3, d: number, h: number, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(h, d, d)
	p.Color = color
	p.Material = material
	p.Transparency = 1
	p.Parent = App.board.folder
	return p
end

local function setChips(vu, st)
	for _, c in ipairs(vu.chips:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	local list = {}
	if st.alive == false then
		table.insert(list, { "K.O.", "#5b4e74", "#e2daf3" })
	end
	if st.burn then
		table.insert(list, { "BRAND", "#ff7a2f", "#2b0e00" })
	end
	if st.honey then
		table.insert(list, { "HONIG", "#ffd23d", "#3a2700" })
	end
	if st.shield then
		table.insert(list, { "SCHILD", "#5ee3d2", "#05302b" })
	end
	if st.overwatch then
		table.insert(list, { "WACHE", "#ffffff", "#3a1d05" })
	end
	for i, c in ipairs(list) do
		local l = Instance.new("TextLabel")
		l.Text = c[1]
		l.Font = Enum.Font.GothamBold
		l.TextSize = 11
		l.BackgroundColor3 = hex(c[2])
		l.TextColor3 = hex(c[3])
		l.Size = UDim2.fromOffset(0, 15)
		l.AutomaticSize = Enum.AutomaticSize.X
		l.LayoutOrder = i
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 4)
		pad.PaddingRight = UDim.new(0, 4)
		pad.Parent = l
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0, 4)
		cr.Parent = l
		l.Parent = vu.chips
	end
	vu.status = st
end

local function refreshBar(vu)
	local r = math.clamp(vu.hp / vu.maxHp, 0, 1)
	vu.fill.Size = UDim2.fromScale(r, 1)
	if vu.team == "hero" then
		vu.fill.BackgroundColor3 = if r > 0.5 then COL.c100 elseif r > 0.25 then COL.c50 else hex("#ff5a5a")
	end
end

local function makeVisual(u)
	local model, info
	if u.team == "hero" then
		model, info = Models.hero(u.kind, Skins.get(u.kind, progress.skins[u.kind]))
	else
		model, info = Models.enemy(u.kind, u.def)
	end
	model.Parent = App.board.folder
	local h = info.height
	local vu = {
		id = u.id,
		unit = u,
		team = u.team,
		model = model,
		height = h,
		muzzle = info.muzzle,
		shotColor = if u.team == "hero" then info.glow else COL.foeShot,
		pos = tp(u.x, u.z),
		yaw = if u.team == "hero" then 0 else math.pi,
		yawGoal = if u.team == "hero" then 0 else math.pi,
		lift = 0,
		flip = 0,
		tilt = 0,
		phase = rnd:NextNumber() * math.pi * 2,
		alive = u.alive,
		hp = u.hp,
		maxHp = u.maxHp,
		flash = 0,
		hlColor = nil,
		status = { burn = false, honey = false, shield = false, overwatch = false, alive = true },
	}
	-- Trefferfläche (außerhalb des Modells, damit Highlights sauber bleiben)
	local hit = Instance.new("Part")
	hit.Anchored = true
	hit.CanCollide = false
	hit.CanTouch = false
	hit.CanQuery = true
	hit.Transparency = 1
	hit.Size = Vector3.new(3.4, h, 3.4)
	hit:SetAttribute("UnitId", u.id)
	hit.Parent = App.board.folder
	vu.hitbox = hit
	local hl = Instance.new("Highlight")
	hl.Enabled = false
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = model
	vu.hl = hl
	vu.ring = disc(COL.gold, 3.9, 0.12, Enum.Material.Neon)
	vu.watch = disc(COL.white, 4.3, 0.1, Enum.Material.Neon)
	vu.honey = disc(hex("#ffc21a"), 3.4, 0.16, Enum.Material.SmoothPlastic)
	local bubble = Instance.new("Part")
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.CastShadow = false
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.new(h * 1.15, h * 1.15, h * 1.15)
	bubble.Color = hex("#5ee3d2")
	bubble.Material = Enum.Material.ForceField
	bubble.Transparency = 1
	bubble.Parent = App.board.folder
	vu.bubble = bubble

	-- Lebensbalken & Statusanzeige
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(if u.def.boss then 140 else 96, 70)
	bb.StudsOffsetWorldSpace = Vector3.new(0, h / 2 + 1.6, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 400
	bb.Adornee = hit
	bb.Parent = hit
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = bb
	local chance = Instance.new("TextLabel")
	chance.Font = Enum.Font.FredokaOne
	chance.TextSize = 17
	chance.Size = UDim2.fromOffset(0, 20)
	chance.AutomaticSize = Enum.AutomaticSize.X
	chance.Visible = false
	chance.LayoutOrder = 1
	local cpad = Instance.new("UIPadding")
	cpad.PaddingLeft = UDim.new(0, 7)
	cpad.PaddingRight = UDim.new(0, 7)
	cpad.Parent = chance
	local ccr = Instance.new("UICorner")
	ccr.CornerRadius = UDim.new(0, 8)
	ccr.Parent = chance
	chance.Parent = bb
	local nameLbl = Instance.new("TextLabel")
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 13
	nameLbl.TextColor3 = COL.white
	nameLbl.Text = u.name
	nameLbl.Size = UDim2.new(1, 0, 0, 15)
	nameLbl.Visible = u.def.boss == true
	nameLbl.LayoutOrder = 2
	local ns = Instance.new("UIStroke")
	ns.Thickness = 2
	ns.Color = hex("#120c20")
	ns.Parent = nameLbl
	nameLbl.Parent = bb
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(if u.def.boss then 120 else 64, 9)
	bar.BackgroundColor3 = hex("#120c20")
	bar.BorderSizePixel = 0
	bar.LayoutOrder = 3
	local bcr = Instance.new("UICorner")
	bcr.CornerRadius = UDim.new(0, 4)
	bcr.Parent = bar
	bar.Parent = bb
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = if u.team == "hero" then COL.c100 else hex("#ff5a7a")
	fill.BorderSizePixel = 0
	local fcr = Instance.new("UICorner")
	fcr.CornerRadius = UDim.new(0, 4)
	fcr.Parent = fill
	fill.Parent = bar
	local chips = Instance.new("Frame")
	chips.BackgroundTransparency = 1
	chips.Size = UDim2.new(1, 0, 0, 15)
	chips.LayoutOrder = 4
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cl.Padding = UDim.new(0, 2)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.Parent = chips
	chips.Parent = bb
	vu.bb, vu.chance, vu.nameLbl, vu.fill, vu.chips = bb, chance, nameLbl, fill, chips
	VU[u.id] = vu
	refreshBar(vu)
	setChips(vu, Rules.statusOf(App.G, u))
	return vu
end

local function destroyVisual(vu)
	vu.model:Destroy()
	for _, p in ipairs({ vu.hitbox, vu.ring, vu.watch, vu.honey, vu.bubble }) do
		p:Destroy()
	end
	VU[vu.id] = nil
end

-- Skin eines Helden während des Spiels austauschen (Zustand bleibt erhalten)
local function reskin(heroKind: string)
	if not App.G then
		return
	end
	for _, u in ipairs(App.G.units) do
		local old = VU[u.id]
		if u.kind == heroKind and old then
			local keep = { pos = old.pos, yaw = old.yaw, yawGoal = old.yawGoal, hp = old.hp, alive = old.alive, status = old.status, tilt = old.tilt }
			destroyVisual(old)
			local vu = makeVisual(u)
			for k, v in pairs(keep) do
				vu[k] = v
			end
			refreshBar(vu)
			setChips(vu, vu.status)
		end
	end
end

local function updateVisuals(dt: number, t: number)
	for _, vu in pairs(VU) do
		local d = vu.yawGoal - vu.yaw
		d = math.atan2(math.sin(d), math.cos(d))
		vu.yaw += d * math.min(1, dt * 12)
		local bob = if vu.alive then math.abs(math.sin(t * 2.4 + vu.phase)) * 0.14 else 0
		local base = vu.pos + Vector3.new(0, vu.lift + bob, 0)
		local cf = CFrame.new(base) * CFrame.Angles(0, vu.yaw, 0)
		if vu.flip ~= 0 then
			cf = cf * CFrame.new(0, vu.height / 2, 0) * CFrame.Angles(vu.flip, 0, 0) * CFrame.new(0, -vu.height / 2, 0)
		end
		if vu.tilt ~= 0 then
			cf = cf * CFrame.new(0, 0.6, 0) * CFrame.Angles(vu.tilt, 0, 0)
		end
		vu.model:PivotTo(cf)
		vu.hitbox.CFrame = CFrame.new(base + Vector3.new(0, vu.height / 2, 0))
		local flat = CFrame.new(vu.pos) * CFrame.Angles(0, 0, math.rad(90))
		local selected = App.selected ~= nil and App.selected.id == vu.id and App.phase == "player" and vu.alive
		vu.ring.CFrame = flat + Vector3.new(0, 0.1, 0)
		vu.ring.Transparency = if selected then 0.25 + math.sin(t * 5) * 0.15 else 1
		vu.watch.CFrame = flat + Vector3.new(0, 0.14, 0)
		vu.watch.Transparency = if vu.alive and vu.status.overwatch then 0.45 else 1
		vu.honey.CFrame = flat + Vector3.new(0, 0.09, 0)
		vu.honey.Transparency = if vu.alive and vu.status.honey then 0.15 else 1
		vu.bubble.CFrame = CFrame.new(base + Vector3.new(0, vu.height / 2, 0))
		vu.bubble.Transparency = if vu.alive and vu.status.shield then 0 else 1
		-- Highlight: Treffer-Blitz hat Vorrang vor Zielmarkierung
		local hl = vu.hl
		if vu.flash > 0 then
			vu.flash = math.max(0, vu.flash - dt * 4.5)
			hl.Enabled = true
			hl.FillColor = COL.white
			hl.FillTransparency = 1 - 0.8 * vu.flash
			hl.OutlineTransparency = 1
		elseif vu.hlColor then
			hl.Enabled = true
			hl.FillColor = vu.hlColor
			hl.OutlineColor = vu.hlColor
			hl.FillTransparency = 0.82
			hl.OutlineTransparency = 0
		else
			hl.Enabled = false
		end
		if vu.alive and vu.status.burn and rnd:NextNumber() < dt * 8 then
			Fx.burst(unitTop(vu, -0.6), if rnd:NextNumber() < 0.5 then hex("#ff7a2f") else hex("#ffc63d"), 1, 2, 0.5, 0.28, 5, -0.3)
		end
	end
end

local function syncVisuals()
	for _, u in ipairs(App.G.units) do
		local vu = VU[u.id]
		if vu and u.alive then
			vu.pos = tp(u.x, u.z)
			vu.lift = 0
			vu.flip = 0
			vu.hp = u.hp
			refreshBar(vu)
			setChips(vu, App.G:statusOf(u))
		end
	end
end

-- ------------------------------------------------------------------ animation helpers

local function jumpArc(vu, to: Vector3, height: number, dur: number, flip: boolean)
	local from = vu.pos
	faceTo(vu, to)
	Fx.sound("jump")
	Fx.tween(dur, function(k)
		vu.pos = from:Lerp(to, k)
		vu.lift = math.sin(math.pi * k) * height
		if flip then
			vu.flip = -Fx.ease(k) * math.pi * 2
		end
	end)
	vu.flip = 0
	vu.lift = 0
end

local function lunge(vu, target: Vector3, frac: number)
	local from = vu.pos
	faceTo(vu, target)
	local mid = from:Lerp(Vector3.new(target.X, from.Y, target.Z), frac)
	Fx.tween(0.12, function(k)
		vu.pos = from:Lerp(mid, Fx.ease(k))
	end)
	Fx.tween(0.16, function(k)
		vu.pos = mid:Lerp(from, Fx.ease(k))
	end)
	vu.pos = from
end

local function boost(vu)
	if not vu then
		return
	end
	Fx.tween(0.12, function(k)
		vu.lift = -k * 0.6
	end)
	task.spawn(function()
		Fx.tween(0.2, function(k)
			vu.lift = -0.6 + k * 0.6
		end)
		vu.lift = 0
	end)
end

local function setScale(model: Model, s: number)
	pcall(function()
		model:ScaleTo(math.max(0.01, s))
	end)
end

-- ------------------------------------------------------------------ event playback

local H = {}

function H.step(e)
	local vu = VU[e.unit]
	local from, to = vu.pos, tp(e.x, e.z)
	faceTo(vu, to)
	Fx.tween(0.17, function(k)
		vu.pos = from:Lerp(to, k)
		vu.lift = math.sin(k * math.pi) * 0.6
	end)
	vu.lift = 0
	Fx.sound("step")
	if vu.team == "enemy" then
		focus(to, 0.7)
	end
end

function H.jump(e)
	local vu = VU[e.unit]
	local to = tp(e.x, e.z)
	faceTo(vu, to)
	boost(VU[e.via])
	jumpArc(vu, to, 8.5, 0.55, true)
	Fx.sound("land")
	Fx.burst(to + Vector3.new(0, 0.3, 0), COL.white, 10, 8, 0.4, 0.3, 2)
end

function H.stomp(e)
	local vu, target = VU[e.unit], VU[e.target]
	faceTo(vu, target.pos)
	boost(VU[e.via])
	jumpArc(vu, target.pos + Vector3.new(0, target.height * 0.85, 0), 9.5, 0.55, true)
	Fx.floatText(unitTop(target, 1.8), "Sprungangriff!", "fx")
end

function H.land(e)
	local vu = VU[e.unit]
	local from = vu.pos
	local to = tp(e.x, e.z)
	faceTo(vu, to)
	Fx.tween(0.4, function(k)
		vu.pos = from:Lerp(to, k)
		vu.lift = (1 - k) * (from.Y - to.Y) + math.sin(math.pi * k) * 4
	end)
	vu.pos = to
	vu.lift = 0
	Fx.sound("land")
end

function H.dash(e)
	local vu, target = VU[e.unit], VU[e.target]
	Fx.sound("dash")
	Fx.floatText(unitTop(target, 1.8), "Sprint!", "fx")
	lunge(vu, target.pos, 0.7)
	Fx.burst(target.pos + Vector3.new(0, 2, 0), COL.dash, 14, 12, 0.5, 0.4)
end

function H.shot(e)
	local a, t = VU[e.attacker], VU[e.target]
	faceTo(a, t.pos)
	if e.reaction then
		focus((a.pos + t.pos) / 2, 0.8)
	end
	Fx.sleep(0.18)
	if e.melee then
		Fx.sound("dash")
		lunge(a, t.pos, 0.55)
		return
	end
	Fx.sound("shoot")
	local from = muzzleWorld(a)
	local to = t.pos + Vector3.new(0, t.height * 0.55, 0)
	if not e.hit then
		if e.coverX then
			to = tp(e.coverX, e.coverZ, if e.coverWall then 4 else 1.8)
		else
			local dir = (to - from).Unit
			to += Vector3.new(-dir.Z, 0, dir.X) * (if rnd:NextNumber() < 0.5 then -3 else 3)
		end
	end
	Fx.projectile(from, to, a.shotColor)
end

function H.damage(e)
	local vu = VU[e.unit]
	vu.hp = e.hp
	refreshBar(vu)
	Fx.floatText(unitTop(vu, 1.2), "-" .. e.amount, if vu.team == "hero" then "heroDmg" else "dmg")
	vu.flash = 1
	Fx.shake(if vu.team == "hero" then 0.6 else 0.35)
	if not e.quiet then
		Fx.sound("hit")
	end
	ui:refresh()
end

function H.ko(e)
	local vu = VU[e.unit]
	vu.alive = false
	vu.hitbox.CanQuery = false
	Fx.sound("ko")
	setChips(vu, { alive = false })
	if vu.team == "enemy" then
		Fx.floatText(unitTop(vu, 1.6), "Besiegt!", "fx")
		Fx.burst(vu.pos + Vector3.new(0, 2, 0), vu.unit.def and hex(vu.unit.def.color) or COL.white, 22, 14, 0.8, 0.45)
		Fx.burst(vu.pos + Vector3.new(0, 2, 0), COL.white, 10, 10, 0.6, 0.35)
		vu.bb.Enabled = false
		task.spawn(function()
			local startYaw = vu.yawGoal
			Fx.tween(0.45, function(k)
				vu.yawGoal = startYaw + k * 6
				setScale(vu.model, 1 - Fx.ease(k))
			end)
			if VU[vu.id] == vu then
				destroyVisual(vu)
			end
		end)
	else
		Fx.floatText(unitTop(vu, 1.6), "K.O.!", "fx")
		for _, p in ipairs(vu.model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Color = p.Color:Lerp(Color3.fromRGB(119, 119, 136), 0.6)
			end
		end
		Fx.tween(0.5, function(k)
			vu.tilt = Fx.ease(k) * math.pi / 2
		end)
	end
	ui:refresh()
end

function H.effect(e)
	local vu = VU[e.unit]
	if e.effect == "burn" then
		Fx.floatText(unitTop(vu, 1.8), "Brand!", "fx")
		Fx.burst(unitTop(vu, -1), hex("#ff7a2f"), 10, 6, 0.6, 0.3, 6, -0.2)
	elseif e.effect == "honey" then
		Fx.floatText(unitTop(vu, 1.8), "Honig!", "fx")
		Fx.burst(vu.pos + Vector3.new(0, 0.5, 0), hex("#ffc21a"), 10, 6, 0.6, 0.3)
	end
end

function H.float(e)
	local vu = VU[e.unit]
	if vu then
		Fx.floatText(unitTop(vu, 1.8), e.text, e.style)
	end
end

function H.cover(e)
	local c = App.board:crateHit(e.x, e.z, e.destroyed)
	Fx.sound("crack")
	Fx.burst(c, COL.crate, if e.destroyed then 18 else 8, 10, 0.6, 0.4)
	Fx.floatText(c + Vector3.new(0, 2.5, 0), if e.destroyed then "Kiste zerstört" else "Kiste beschädigt", "info")
end

function H.slide(e)
	local vu = VU[e.unit]
	local from, to = vu.pos, tp(e.x, e.z)
	Fx.tween(0.13, function(k)
		vu.pos = from:Lerp(to, Fx.ease(k))
	end)
end

function H.bump(e)
	local vu = VU[e.unit]
	lunge(vu, tp(e.x, e.z), 0.35)
	Fx.floatText(tp(e.x, e.z, 4), "Rums!", "info")
end

function H.fall(e)
	local vu = VU[e.unit]
	local from, to = vu.pos, tp(e.x, e.z)
	Fx.tween(0.16, function(k)
		vu.pos = from:Lerp(to, k)
		vu.lift = math.sin(k * math.pi) * 1.5
	end)
	Fx.tween(0.3, function(k)
		vu.lift = -k * 6
	end)
	Fx.sound("splash")
	Fx.burst(tp(e.x, e.z, -2), hex("#bfe8ff"), 22, 10, 0.7, 0.4, 12)
	Fx.floatText(tp(e.x, e.z, 2.5), "Platsch!", "info")
end

function H.respawn(e)
	local vu = VU[e.unit]
	vu.pos = tp(e.x, e.z)
	Fx.tween(0.3, function(k)
		vu.lift = (1 - k * k) * 10
	end)
	vu.lift = 0
	Fx.burst(vu.pos, COL.white, 8, 8, 0.4, 0.3)
end

function H.tech(e)
	local vu = VU[e.unit]
	if e.tech == "overwatch" then
		Fx.sound("watch")
		Fx.floatText(unitTop(vu, 1.5), "Wachsam!", "info")
		Fx.ringWave(vu.pos, COL.white, e.radius * TILE)
	elseif e.tech == "shield" then
		Fx.sound("shield")
		Fx.ringWave(vu.pos, COL.area, e.radius * TILE)
	else
		Fx.sound("heal")
		Fx.ringWave(vu.pos, hex("#7dff8a"), e.radius * TILE)
	end
end

function H.heal(e)
	local vu = VU[e.unit]
	vu.hp = e.hp
	refreshBar(vu)
	Fx.floatText(unitTop(vu, 1.2), "+" .. e.amount, "heal")
	Fx.burst(vu.pos + Vector3.new(0, 1, 0), hex("#7dff8a"), 12, 5, 0.9, 0.3, 5, -0.25)
	ui:refresh()
end

function H.status(e)
	local vu = VU[e.unit]
	if vu then
		setChips(vu, e.status)
	end
end

function H.burn(e)
	local vu = VU[e.unit]
	Fx.floatText(unitTop(vu, 1.8), "Brand", "fx")
	Fx.burst(unitTop(vu, -1), hex("#ff7a2f"), 12, 6, 0.6, 0.35, 6, -0.2)
	Fx.sleep(0.25)
end

function H.turn(e)
	local L = App.G.level
	ui:setRound(e.round, e.phase)
	if e.phase == "player" then
		Fx.sound("turn")
		if e.first then
			ui:showBanner(L.name, "Kampf " .. App.li .. " · " .. L.goal, false)
		else
			ui:showBanner("Dein Zug", "Runde " .. e.round, false)
		end
	else
		Fx.sound("foe")
		ui:showBanner("Gegnerzug", "Die Krawallos greifen an", true)
	end
	Fx.sleep(1.1)
end

function H.banner(e)
	ui:showBanner(e.title, e.sub, e.foe)
	Fx.sleep(1.1)
end

function H.shock(e)
	local vu = VU[e.unit]
	Fx.floatText(unitTop(vu, 1.8), "Schockwelle!", "fx")
	Fx.sound("quake")
	Fx.shake(1.4)
	Fx.ringWave(vu.pos, COL.stomp, e.radius * TILE)
end

function H.spawn(e)
	local u = App.G.byId[e.unit]
	local vu = makeVisual(u)
	vu.pos = tp(e.x, e.z)
	Fx.burst(vu.pos + Vector3.new(0, 1.5, 0), hex("#c23cd6"), 16, 10, 0.6, 0.4)
	Fx.tween(0.35, function(k)
		vu.lift = (1 - Fx.ease(k)) * 8
	end)
	vu.lift = 0
end

function H.enemyStart(e)
	local vu = VU[e.unit]
	if vu then
		focus(vu.pos, 0.7)
		vu.nameLbl.Visible = true
	end
	Fx.sleep(0.3)
end

function H.enemyEnd(e)
	local vu = VU[e.unit]
	if vu then
		vu.nameLbl.Visible = vu.unit.def.boss == true
	end
	Fx.sleep(0.12)
end

local function play(events): boolean
	local run = App.run
	for _, e in ipairs(events) do
		if run ~= App.run then
			return false
		end
		local fn = H[e.kind]
		-- Ereignisse zu bereits entfernten Figuren überspringen (z. B. besiegte Gegner)
		local missing = (e.kind ~= "spawn" and e.unit ~= nil and VU[e.unit] == nil)
			or (e.target ~= nil and VU[e.target] == nil)
			or (e.attacker ~= nil and VU[e.attacker] == nil)
		if fn and not missing then
			local ok, err = pcall(fn, e)
			if not ok then
				warn("Krawall: Animation für " .. tostring(e.kind) .. " fehlgeschlagen: " .. tostring(err))
			end
		end
	end
	return run == App.run
end

-- ------------------------------------------------------------------ highlights & hover

local function chanceCol(c: number): Color3
	return if c >= 100 then COL.c100 elseif c > 0 then COL.c50 else COL.c0
end

local function showChance(vu, c: number)
	vu.chance.Text = c .. " %"
	vu.chance.Visible = true
	vu.chance.BackgroundColor3 = chanceCol(c)
	vu.chance.TextColor3 = if c >= 100 then hex("#0f2a12") elseif c > 0 then hex("#2a1a00") else hex("#e2daf3")
end

local function clearChances()
	for _, vu in pairs(VU) do
		vu.chance.Visible = false
	end
end

local function clearHighlights()
	if not App.board then
		return
	end
	local b = App.board
	b:clearOverlays()
	b:clearDanger()
	b:clearDots()
	b:hideShields()
	b:hideRange()
	b:setHover(nil)
	for _, vu in pairs(VU) do
		vu.hlColor = nil
		vu.chance.Visible = false
		vu.nameLbl.Visible = vu.unit.def.boss == true
	end
end

local applyHover

local function defaultMode(h): string?
	if not h or not h.alive then
		return nil
	end
	if not h.moved then
		return "move"
	end
	if not h.attacked then
		return "attack"
	end
	return nil
end

local function refreshHighlights()
	if not App.board then
		return
	end
	clearHighlights()
	App.moveOpts = nil
	if App.phase ~= "player" or App.busy then
		return
	end
	local G, b, h = App.G, App.board, App.selected
	if not h or not h.alive then
		return
	end
	if App.mode == "move" then
		local o = G:computeMoveOptions(h)
		App.moveOpts = o
		for _, v in pairs(o.walk) do
			if not (v.x == h.x and v.z == h.z) then
				b:setOverlay(v.x, v.z, "move")
			end
		end
		for _, v in pairs(o.jump) do
			b:setOverlay(v.x, v.z, "jump")
		end
		for k, v in pairs(o.stomp) do
			if not o.dash[k] and VU[v.enemy.id] then
				VU[v.enemy.id].hlColor = COL.stomp
			end
		end
		for _, v in pairs(o.dash) do
			if VU[v.enemy.id] then
				VU[v.enemy.id].hlColor = COL.dash
			end
		end
	elseif App.mode == "attack" then
		local w = h.def.weapon
		b:showRange(h.x, h.z, w.range, COL.range)
		for z = 0, G.H - 1 do
			for x = 0, G.W - 1 do
				if G:tileAt(x, z).type == "floor" and math.sqrt((x - h.x) ^ 2 + (z - h.z) ^ 2) <= w.range + 1e-6 and not (x == h.x and z == h.z) then
					b:setOverlay(x, z, "range")
				end
			end
		end
		for _, e in ipairs(G:foes()) do
			local info = G:shotInfo(h, h.x, h.z, e)
			local vu = VU[e.id]
			if info.inRange and vu then
				vu.hlColor = chanceCol(info.chance)
				showChance(vu, info.chance)
			end
		end
	elseif App.mode == "tech" then
		local area, r = G:techArea(h)
		local ow = h.def.tech.id == "overwatch"
		b:showRange(h.x, h.z, r, if ow then COL.white else COL.area)
		for _, p in ipairs(area) do
			b:setOverlay(p[1], p[2], if ow then "range" else "area")
		end
	end
	if App.hover then
		applyHover(App.hover)
	end
end

local function hitKey(hit): string
	if not hit then
		return ""
	end
	if hit.unit then
		return "u" .. hit.unit.id
	end
	return "t" .. hit.tile.x .. "," .. hit.tile.z
end

local function pct(n: number): string
	return n .. " %"
end

local function num(v: number): string
	return (string.gsub(tostring(v), "%.", ","))
end

local function enemyTip(e, extra: string?): string
	local w = e.def.weapon
	return string.format(
		'<font size="17"><b>%s</b></font>\nLebenspunkte  <b>%d / %d</b>\n%s  <b>%d–%d</b> · Reichweite %s\nBewegung  %d Felder%s',
		e.name, e.hp, e.maxHp, w.name, w.min, w.max, num(w.range), e.move, extra or ""
	)
end

local lastPointer = Vector2.zero

applyHover = function(hit)
	local b = App.board
	if not b then
		return
	end
	if hit and hit.unit and not hit.unit.alive then
		hit = { tile = hit.tile, unit = nil }
	end
	b:clearDots()
	b:hideShields()
	b:clearDanger()
	b:setHover(nil)
	for _, vu in pairs(VU) do
		vu.nameLbl.Visible = vu.unit.def.boss == true or (hit ~= nil and hit.unit == vu.unit)
	end
	if App.mode == "move" then
		clearChances()
	end
	if not hit or App.phase ~= "player" or App.busy then
		ui:hideTip()
		return
	end
	local G, h, u, t = App.G, App.selected, hit.unit, hit.tile
	if t then
		b:setHover(t.x, t.z)
	end
	if u and u.team == "enemy" then
		if App.mode ~= "attack" then
			local dist = G:bfs(u, u.x, u.z, u.move)
			for k in pairs(dist) do
				local x, z = Rules.unkey(k)
				if not (x == u.x and z == u.z) then
					b:setDanger(x, z)
				end
			end
		end
		local extra = ""
		if h and App.mode == "attack" then
			local info = G:shotInfo(h, h.x, h.z, u)
			local w = h.def.weapon
			local c = if info.chance >= 100 then "#5fd068" elseif info.chance > 0 then "#ffc63d" else "#ff5a5a"
			extra = string.format('\n<font color="#b9add6">────────────</font>\nTrefferchance  <font size="19" color="%s"><b>%s</b></font>\n%s', c, if info.inRange then pct(info.chance) else "–", info.reason)
			if u.status.shield then
				extra ..= " · Schild"
			end
			if info.chance > 0 then
				extra ..= string.format("\nSchaden  <b>%d–%d</b>", w.min, w.max)
				if w.effect then
					extra ..= string.format("\n%s  %s%s", Config.EFFECT_NAMES[w.effect], pct(math.round(w.chance * 100)), if u.def.boss and w.effect == "push" then " (immun)" else "")
				end
			end
		elseif h and App.mode == "move" and App.moveOpts then
			local k, o = key(u.x, u.z), App.moveOpts
			if o.dash[k] then
				extra = string.format('\n<font color="#ff8a2a"><b>Sprintangriff</b></font>  %d Schaden', h.def.dash)
				local st = o.dash[k].stand
				b:drawPath(G:findPath(h, st.x, st.z))
			elseif o.stomp[k] then
				local s = o.stomp[k]
				extra = string.format('\n<font color="#ff5fd2"><b>Sprungangriff über %s</b></font>  %d Schaden', s.via.name, Config.STOMP_DMG)
				b:drawPath(G:findPath(h, s.via.x, s.via.z))
				b:drawArc(tp(s.via.x, s.via.z), tp(u.x, u.z, 3))
			end
		end
		ui:showTip(enemyTip(u, extra), lastPointer.X, lastPointer.Y)
		return
	end
	if u and u.team == "hero" then
		ui:showTip(string.format('<font size="17"><b>%s</b></font>\nLebenspunkte  <b>%d / %d</b>%s', u.name, u.hp, u.maxHp, if u ~= h then "\nKlicken zum Auswählen" else ""), lastPointer.X, lastPointer.Y)
		return
	end
	if not h or not t then
		ui:hideTip()
		return
	end
	if App.mode == "move" and App.moveOpts then
		local k, o = key(t.x, t.z), App.moveOpts
		local title = nil
		if o.walk[k] and not (t.x == h.x and t.z == h.z) then
			b:drawPath(G:findPath(h, t.x, t.z))
			title = "Laufen"
		elseif o.jump[k] then
			local j = o.jump[k]
			b:drawPath(G:findPath(h, j.via.x, j.via.z))
			b:drawArc(tp(j.via.x, j.via.z), tp(t.x, t.z))
			title = "Teamsprung über " .. j.via.name
		end
		if title then
			b:showShields(t.x, t.z, Rules.coverVal)
			for _, e in ipairs(G:foes()) do
				local info = G:shotInfo(h, t.x, t.z, e)
				if info.inRange and VU[e.id] then
					showChance(VU[e.id], info.chance)
				end
			end
			local best = 0
			for _, d in ipairs(Rules.DIRS) do
				best = math.max(best, Rules.coverVal(G:tileAt(t.x + d[1], t.z + d[2])))
			end
			ui:showTip(string.format('<font size="17"><b>%s</b></font>\nDeckung hier  <b>%s</b>\n<font color="#b9add6">Zahlen über Gegnern: Trefferchance von hier</font>', title, ({ "keine", "halb", "voll" })[best + 1]), lastPointer.X, lastPointer.Y)
			return
		end
	end
	ui:hideTip()
end

-- ------------------------------------------------------------------ HUD refresh

local function refreshUi()
	if not ui or not App.G then
		return
	end
	local G = App.G
	local playing = App.phase == "player" and not App.busy
	local data = {}
	for _, u in ipairs(G:heroList()) do
		local vu = VU[u.id]
		table.insert(data, {
			hp = if vu then vu.hp else u.hp,
			maxHp = u.maxHp,
			alive = if vu then vu.alive else u.alive,
			moved = u.moved,
			attacked = u.attacked,
			techReady = not u.techUsed and u.cd == 0,
			cd = u.cd,
			selected = App.selected == u and App.phase == "player",
		})
	end
	ui:setHeroes(data)
	local h = App.selected
	if h and not h.alive then
		h = nil
	end
	local allSpent = #G:heroes() > 0
	for _, u in ipairs(G:heroes()) do
		if not (u.moved and u.attacked) then
			allSpent = false
		end
	end
	local techLabel = "Technik [T]"
	if h then
		techLabel = if App.mode == "tech" then "Einsetzen [T]" else h.def.tech.name .. (if h.cd > 0 then " (" .. h.cd .. ")" else "")
	end
	ui:setActions({
		move = playing and h ~= nil and not h.moved,
		attack = playing and h ~= nil and not h.attacked,
		tech = playing and h ~= nil and not h.techUsed and h.cd == 0,
		endTurn = playing,
		mode = if playing then App.mode else nil,
		techLabel = techLabel,
		pulse = playing and allSpent,
	})
	if not h then
		ui:setInfo(if App.phase == "enemy" then '<font size="18"><b>Die Krawallos sind dran</b></font>' else '<font size="18"><b>Wähle einen Helden</b></font>')
		return
	end
	local w, t = h.def.weapon, h.def.tech
	local tState = if h.techUsed then "eingesetzt" elseif h.cd > 0 then "bereit in " .. h.cd .. (if h.cd == 1 then " Runde" else " Runden") else "bereit"
	ui:setInfo(string.format(
		'<font size="19" color="%s"><b>%s</b></font>  <font color="#b9add6">%s · %d Felder</font>\n<font color="#ffc63d"><b>WAFFE</b></font>  %s · %d–%d Schaden · Reichweite %s · %s %s\n<font color="#ffc63d"><b>TECHNIK</b></font>  %s (%s): %s\n<font color="#ffc63d"><b>SPRINT</b></font>  %d Schaden · %s',
		h.def.color, h.name, h.def.role, h.move,
		w.name, w.min, w.max, num(w.range), Config.EFFECT_NAMES[w.effect], pct(math.round(w.chance * 100)),
		t.name, tState, t.desc,
		h.def.dash, if h.dashUsed then "schon benutzt" else "einmal pro Zug"
	))
end

-- ------------------------------------------------------------------ flow

local finish
local selectHero

local function checkEnd(): boolean
	if App.phase == "over" or App.phase == "title" then
		return true
	end
	local r = App.G:result()
	if r then
		finish(r == "win")
		return true
	end
	return false
end

local function postAction()
	local G = App.G
	local h = App.selected
	if not h or not h.alive or G:heroDone(h) then
		for _, u in ipairs(G:heroes()) do
			if not G:heroDone(u) then
				h = u
				break
			end
		end
	end
	if h and h.alive then
		App.selected = h
		App.mode = defaultMode(h)
		focus(tp(h.x, h.z))
	end
	refreshHighlights()
	refreshUi()
	local allDone = true
	for _, u in ipairs(G:heroes()) do
		if not G:heroDone(u) then
			allDone = false
		end
	end
	if allDone then
		local run = App.run
		task.delay(0.9, function()
			if run == App.run and App.phase == "player" and not App.busy then
				App.endTurn()
			end
		end)
	end
end

local function act(fn: () -> { any })
	if App.busy or App.phase ~= "player" or App.paused then
		return
	end
	App.busy = true
	App.touchPending = nil
	ui:hideTip()
	refreshHighlights()
	refreshUi()
	local run = App.run
	task.spawn(function()
		local ok, events = pcall(fn)
		if not ok then
			warn("Krawall: Aktion fehlgeschlagen: " .. tostring(events))
			events = {}
		end
		play(events)
		if run ~= App.run then
			return
		end
		syncVisuals()
		App.busy = false
		if checkEnd() then
			return
		end
		postAction()
	end)
end

selectHero = function(u)
	if not u or not u.alive then
		return
	end
	if App.selected ~= u then
		Fx.sound("select")
	end
	App.selected = u
	App.touchPending = nil
	App.mode = defaultMode(u)
	focus(tp(u.x, u.z))
	refreshHighlights()
	refreshUi()
end

local function setMode(m: string?)
	App.mode = m
	refreshHighlights()
	refreshUi()
end

function App.endTurn()
	if App.phase ~= "player" or App.busy or App.paused then
		return
	end
	App.phase = "enemy"
	App.busy = true
	App.mode = nil
	App.hover = nil
	ui:hideTip()
	clearHighlights()
	refreshUi()
	local run = App.run
	task.spawn(function()
		local events = App.G:endTurn()
		play(events)
		if run ~= App.run then
			return
		end
		syncVisuals()
		App.busy = false
		if checkEnd() then
			return
		end
		App.phase = "player"
		local sel = if App.selected and App.selected.alive then App.selected else App.G:heroes()[1]
		App.selected = nil
		selectHero(sel)
	end)
end

local function frameCamera()
	local G = App.G
	local span = math.max(G.W, G.H) * TILE
	local vp = camera.ViewportSize
	local aspect = vp.X / math.max(1, vp.Y)
	goal.yaw = 0
	goal.pitch = 0.95
	goal.dist = span * (if aspect < 1.2 then 1.75 else 1.38)
	goal.target = Vector3.new(0, 0, span * 0.1)
	cam.yaw, cam.pitch, cam.dist, cam.target = goal.yaw, goal.pitch, goal.dist, goal.target
end

local function buildBattlefield(li: number)
	if App.board then
		App.board:destroy()
	end
	table.clear(VU)
	Fx.clear()
	App.li = li
	App.G = Rules.new(Config, li, function()
		return rnd:NextNumber()
	end)
	App.board = Board.new(App.G, world)
	for _, u in ipairs(App.G.units) do
		makeVisual(u)
	end
	frameCamera()
end

local function enemyCounts()
	local out = {}
	for i, L in ipairs(Config.LEVELS) do
		local n = 0
		for _, rowStr in ipairs(L.map) do
			for c in string.gmatch(rowStr, ".") do
				if Config.ENEMY_CODES[c] then
					n += 1
				end
			end
		end
		out[i] = n
	end
	return out
end
local ENEMY_COUNTS = enemyCounts()

local function showTitle()
	App.run += 1
	App.phase = "title"
	App.busy = false
	App.paused = false
	Fx.speed = App.speed
	App.selected = nil
	App.mode = nil
	App.hover = nil
	App.pick = math.min(progress.won + 1, #Config.LEVELS)
	buildBattlefield(App.pick)
	ui:setHudVisible(false)
	ui:hideTip()
	ui:setLevels(Config.LEVELS, progress.won, progress.best, App.pick, ENEMY_COUNTS)
	ui:show("title")
end

local function startLevel(li: number)
	App.run += 1
	App.paused = false
	Fx.speed = App.speed
	buildBattlefield(li)
	App.phase = "player"
	App.busy = true
	App.selected = nil
	App.mode = nil
	App.hover = nil
	ui:setLevel(li, App.G.level)
	ui:buildHeroCards(App.G:heroList())
	ui:show(nil)
	ui:setHudVisible(true)
	refreshUi()
	local run = App.run
	task.spawn(function()
		play(App.G:startPlayerTurn(true))
		if run ~= App.run then
			return
		end
		syncVisuals()
		App.busy = false
		selectHero(App.G:heroes()[1])
	end)
end

finish = function(won: boolean)
	App.phase = "over"
	App.busy = false
	App.mode = nil
	clearHighlights()
	refreshUi()
	ui:hideTip()
	local run = App.run
	task.delay(0.9, function()
		if run ~= App.run then
			return
		end
		Fx.sound(if won then "win" else "lose")
		local G, li = App.G, App.li
		local L = G.level
		local final = won and li == #Config.LEVELS
		local rating
		local unlockText = nil
		if won then
			local score = 1 + (if G.turn <= L.par then 1 else 0) + (if G.stats.kos == 0 then 1 else 0)
			rating = ({ "Bewertung: Geschafft", "Bewertung: Stark", "Bewertung: Meisterhaft" })[score] .. " · Ziel war " .. L.par .. " Runden"
			local prev = progress.best[tostring(li)]
			if not prev or score > prev.score or (score == prev.score and G.turn < prev.turn) then
				progress.best[tostring(li)] = { score = score, turn = G.turn }
			end
			if li > progress.won then
				progress.won = li
				local names = {}
				for _, entry in ipairs(Skins.unlockedBy(li)) do
					table.insert(names, entry.skin.name .. " (" .. Config.HEROES[entry.hero].name .. ")")
				end
				if #names > 0 then
					unlockText = "<b>Neue Skins freigeschaltet:</b> " .. table.concat(names, ", ") .. ". Rüste sie in der Garderobe aus."
				end
			end
			saveProgress()
			if final then
				rating ..= " · Der Krawall-König ist gestürzt."
			end
		else
			rating = "Alle Helden sind K.O. Versuch es mit mehr Deckung und Teamsprüngen."
		end
		local acc = if G.stats.shots > 0 then math.round(100 * G.stats.hits / G.stats.shots) else 0
		local buttons = {}
		if won and not final then
			table.insert(buttons, { "Nächster Kampf", "gold", function()
				startLevel(li + 1)
			end })
		elseif not won then
			table.insert(buttons, { "Nochmal versuchen", "gold", function()
				startLevel(li)
			end })
		end
		if unlockText then
			table.insert(buttons, { "Garderobe", if final then "gold" else "violet", function()
				App.skinsReturn = "ending"
				ui:openSkins(Skins, progress)
			end })
		end
		if final then
			table.insert(buttons, { "Nochmal von vorn", "violet", function()
				startLevel(1)
			end })
		end
		table.insert(buttons, { "Hauptmenü", "violet", showTitle })
		ui:showEnd({
			eyebrow = "KAMPF " .. li .. " · " .. string.upper(L.name),
			title = if final then "Königreich gerettet!" elseif won then "Sieg!" else "Niederlage",
			won = won,
			rating = rating,
			stats = { { "RUNDEN", tostring(G.turn) }, { "TREFFERQUOTE", pct(acc) }, { "SCHADEN", tostring(G.stats.dealt) }, { "HELDEN K.O.", tostring(G.stats.kos) } },
			unlock = unlockText,
			buttons = buttons,
		})
	end)
end

-- ------------------------------------------------------------------ board clicks

local function onBoardClick(hit, isTouch: boolean)
	if App.phase ~= "player" or App.busy or App.paused or not hit then
		return
	end
	local G, h, u, t = App.G, App.selected, hit.unit, hit.tile
	if isTouch then
		local k = hitKey(hit)
		local immediate = u ~= nil and u.team == "hero" and u ~= h and App.mode ~= "tech"
		if not immediate and App.touchPending ~= k then
			App.touchPending = k
			App.hover = hit
			applyHover(hit)
			return
		end
		App.touchPending = nil
	end
	if u and u.team == "hero" and App.mode ~= "tech" then
		if u ~= h then
			selectHero(u)
		end
		return
	end
	if not h or not h.alive then
		return
	end
	if App.mode == "move" and App.moveOpts then
		local o = App.moveOpts
		if u and u.team == "enemy" then
			local k = key(u.x, u.z)
			if o.dash[k] then
				local d = o.dash[k]
				act(function()
					return G:heroDash(h, d)
				end)
			elseif o.stomp[k] then
				local s = o.stomp[k]
				act(function()
					return G:heroStomp(h, s)
				end)
			end
			return
		end
		if not t then
			return
		end
		local k = key(t.x, t.z)
		if o.walk[k] and not (t.x == h.x and t.z == h.z) then
			act(function()
				return G:heroWalk(h, t.x, t.z)
			end)
		elseif o.jump[k] then
			local j = o.jump[k]
			act(function()
				return G:heroJump(h, j)
			end)
		end
		return
	end
	if App.mode == "attack" then
		if u and u.team == "enemy" and not h.attacked then
			local info = G:shotInfo(h, h.x, h.z, u)
			if info.chance > 0 then
				act(function()
					return G:heroAttack(h, u)
				end)
			elseif VU[u.id] then
				Fx.floatText(unitTop(VU[u.id], 1.6), info.reason, "miss")
			end
		elseif not u and not h.moved then
			setMode("move")
		end
		return
	end
	if App.mode == "tech" then
		local area = G:techArea(h)
		local inArea = false
		if t then
			for _, p in ipairs(area) do
				if p[1] == t.x and p[2] == t.z then
					inArea = true
				end
			end
		end
		if inArea then
			act(function()
				return G:heroTech(h)
			end)
		else
			setMode(defaultMode(h))
		end
	end
end

-- ------------------------------------------------------------------ UI handlers

local function useTech()
	local h = App.selected
	if App.phase ~= "player" or App.busy or not h or h.techUsed or h.cd > 0 then
		return
	end
	if App.mode == "tech" then
		act(function()
			return App.G:heroTech(h)
		end)
	else
		setMode("tech")
	end
end

local function openPause()
	if App.phase == "title" or App.phase == "over" or ui.current ~= nil then
		return
	end
	App.paused = true
	Fx.speed = 0
	ui:hideTip()
	ui:showPause(string.format("Kampf %d · %s, Runde %d. Gegner übrig: %d.", App.li, App.G.level.name, App.G.turn, #App.G:foes()))
end

local function resume()
	App.paused = false
	Fx.speed = App.speed
	ui:show(nil)
end

ui = Ui.new({
	onPlay = function()
		startLevel(App.pick)
	end,
	onPickLevel = function(i: number)
		App.pick = i
		buildBattlefield(i)
		ui:setLevels(Config.LEVELS, progress.won, progress.best, App.pick, ENEMY_COUNTS)
	end,
	onOpenSkins = function()
		App.skinsReturn = ui.current or "title"
		ui:openSkins(Skins, progress)
	end,
	onCloseSkins = function()
		ui:show(App.skinsReturn or "title")
	end,
	onEquip = function(heroKind: string, id: string)
		if Skins.isUnlocked(heroKind, id, progress.won) then
			progress.skins[heroKind] = id
			saveProgress()
			reskin(heroKind)
			ui:refreshSkins()
		end
	end,
	onHelp = function()
		App.helpReturn = ui.current
		if App.helpReturn == nil and (App.phase == "player" or App.phase == "enemy") then
			App.paused = true
			Fx.speed = 0
		end
		ui:show("help")
	end,
	onCloseHelp = function()
		ui:show(App.helpReturn)
		if App.helpReturn == nil then
			App.paused = false
			Fx.speed = App.speed
		end
	end,
	onPause = openPause,
	onResume = resume,
	onRestart = function()
		startLevel(App.li)
	end,
	onToTitle = showTitle,
	onSpeed = function()
		App.speed = if App.speed >= 3 then 1 else App.speed + 1
		if not App.paused then
			Fx.speed = App.speed
		end
		ui.speedBtn:setText(App.speed .. "×")
	end,
	onSound = function()
		Fx.muted = not Fx.muted
		ui.soundBtn:setText(if Fx.muted then "Stumm" else "Ton")
	end,
	onSelectHero = function(i: number)
		if App.phase == "player" and not App.busy and not App.paused then
			local u = App.G:heroList()[i]
			if u and u.alive then
				selectHero(u)
			end
		end
	end,
	onMode = function(m: string)
		local h = App.selected
		if App.phase ~= "player" or App.busy or not h then
			return
		end
		if m == "move" and not h.moved then
			setMode("move")
		elseif m == "attack" and not h.attacked then
			setMode("attack")
		end
	end,
	onTech = useTech,
	onEndTurn = function()
		App.endTurn()
	end,
})
ui.refresh = function()
	refreshUi()
end

-- ------------------------------------------------------------------ input

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

local function pick(x: number, y: number)
	if not App.board or not App.G then
		return nil
	end
	rayParams.FilterDescendantsInstances = { App.board.folder }
	local ray = camera:ScreenPointToRay(x, y)
	local res = workspace:Raycast(ray.Origin, ray.Direction * 800, rayParams)
	if not res then
		return nil
	end
	local inst = res.Instance
	local uid = inst:GetAttribute("UnitId")
	if uid then
		local u = App.G.byId[uid]
		if u and u.alive then
			return { unit = u, tile = App.G:tileAt(u.x, u.z) }
		end
		return nil
	end
	local tx, tz = inst:GetAttribute("TX"), inst:GetAttribute("TZ")
	if tx ~= nil and tz ~= nil then
		return { tile = App.G:tileAt(tx, tz), unit = App.G:unitAt(tx, tz) }
	end
	return nil
end

local function rotateBy(delta: Vector2)
	goal.yaw -= delta.X * 0.006
	goal.pitch = math.clamp(goal.pitch + delta.Y * 0.004, 0.42, 1.38)
end

local function panBy(delta: Vector2)
	local s = cam.dist * 0.0016
	local fwd = Vector3.new(-math.sin(cam.yaw), 0, -math.cos(cam.yaw))
	local right = Vector3.new(math.cos(cam.yaw), 0, -math.sin(cam.yaw))
	goal.target += right * (-delta.X * s) + fwd * (delta.Y * s)
end

-- Liegt der Mauszeiger über einem sichtbaren HUD-Element?
local function overHud(p: Vector2): boolean
	for _, g in ipairs(player.PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y)) do
		if g:IsDescendantOf(ui.hud) and g ~= ui.tip and not g:IsDescendantOf(ui.tip) and (g.BackgroundTransparency < 1 or g:IsA("GuiButton")) then
			return true
		end
	end
	return false
end

local drag = nil
local keysDown = {}
local pinchStart = nil

local KEY_ACTIONS = {
	[Enum.KeyCode.Q] = function()
		goal.yaw += math.pi / 4
	end,
	[Enum.KeyCode.E] = function()
		goal.yaw -= math.pi / 4
	end,
	[Enum.KeyCode.L] = function()
		ui.h.onMode("move")
	end,
	[Enum.KeyCode.F] = function()
		ui.h.onMode("attack")
	end,
	[Enum.KeyCode.T] = useTech,
	[Enum.KeyCode.Return] = function()
		App.endTurn()
	end,
	[Enum.KeyCode.P] = function()
		if App.paused and ui.current == "pause" then
			resume()
		else
			openPause()
		end
	end,
	[Enum.KeyCode.H] = function()
		if ui.current == "help" then
			ui.h.onCloseHelp()
		elseif ui.current == nil and App.phase ~= "title" then
			ui.h.onHelp()
		end
	end,
	[Enum.KeyCode.X] = function()
		local h = App.selected
		if App.phase == "player" and not App.busy and h then
			setMode(defaultMode(h))
		end
	end,
}

local function cycleHero(dir: number)
	if App.phase ~= "player" or App.busy or App.paused then
		return
	end
	local list = App.G:heroes()
	if #list == 0 then
		return
	end
	local idx = table.find(list, App.selected) or 0
	selectHero(list[((idx - 1 + dir) % #list) + 1])
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		if processed and input.KeyCode ~= Enum.KeyCode.Tab then
			return
		end
		local kc = input.KeyCode
		keysDown[kc] = true
		if App.phase == "title" or ui.current ~= nil and ui.current ~= "pause" and ui.current ~= "help" then
			return
		end
		if kc == Enum.KeyCode.One or kc == Enum.KeyCode.Two or kc == Enum.KeyCode.Three then
			local idx = if kc == Enum.KeyCode.One then 1 elseif kc == Enum.KeyCode.Two then 2 else 3
			ui.h.onSelectHero(idx)
		elseif kc == Enum.KeyCode.Tab or kc == Enum.KeyCode.N then
			cycleHero(1)
		elseif KEY_ACTIONS[kc] then
			if ui.current ~= nil and kc ~= Enum.KeyCode.P and kc ~= Enum.KeyCode.H then
				return
			end
			KEY_ACTIONS[kc]()
		end
		return
	end
	if processed then
		return
	end
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
		local p = Vector2.new(input.Position.X, input.Position.Y)
		drag = { start = p, last = p, button = t, moved = false, touch = false }
	elseif t == Enum.UserInputType.Touch then
		local p = Vector2.new(input.Position.X, input.Position.Y)
		if drag == nil then
			drag = { start = p, last = p, button = t, moved = false, touch = true, input = input }
		else
			drag.moved = true -- zweiter Finger: kein Tippen mehr
		end
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement then
		local p = Vector2.new(input.Position.X, input.Position.Y)
		lastPointer = p
		if drag and not drag.touch then
			local delta = p - drag.last
			if not drag.moved and (p - drag.start).Magnitude > 6 then
				drag.moved = true
			end
			if drag.moved then
				local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				if drag.button == Enum.UserInputType.MouseButton3 or shift then
					panBy(delta)
				else
					rotateBy(delta)
				end
				ui:hideTip()
			end
			drag.last = p
			return
		end
		if processed or overHud(p) then
			if App.hover then
				App.hover = nil
				applyHover(nil)
			end
			return
		end
		local hit = pick(p.X, p.Y)
		if hitKey(hit) ~= hitKey(App.hover) then
			App.hover = hit
			applyHover(hit)
		elseif ui.tip.Visible then
			ui:showTip(ui.tipLabel.Text, p.X, p.Y)
		end
	elseif t == Enum.UserInputType.MouseWheel then
		if not processed then
			goal.dist = math.clamp(goal.dist * math.exp(-input.Position.Z * 0.12), 22, 170)
		end
	elseif t == Enum.UserInputType.Touch then
		if drag and drag.touch and drag.input == input then
			local p = Vector2.new(input.Position.X, input.Position.Y)
			if not drag.moved and (p - drag.start).Magnitude > 10 then
				drag.moved = true
			end
			if drag.moved and pinchStart == nil then
				rotateBy(p - drag.last)
			end
			drag.last = p
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _processed: boolean)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = nil
		return
	end
	if drag and not drag.touch and drag.button == t then
		local wasDrag = drag
		drag = nil
		if not wasDrag.moved and t == Enum.UserInputType.MouseButton1 then
			onBoardClick(pick(input.Position.X, input.Position.Y), false)
		end
	elseif t == Enum.UserInputType.Touch and drag and drag.touch and drag.input == input then
		local wasDrag = drag
		drag = nil
		if not wasDrag.moved then
			lastPointer = Vector2.new(input.Position.X, input.Position.Y)
			onBoardClick(pick(input.Position.X, input.Position.Y), true)
		end
	end
end)

UserInputService.TouchPinch:Connect(function(_positions, scale: number, _velocity, state: Enum.UserInputState, processed: boolean)
	if processed then
		return
	end
	if state == Enum.UserInputState.Begin then
		pinchStart = goal.dist
		if drag then
			drag.moved = true
		end
	elseif state == Enum.UserInputState.Change and pinchStart then
		goal.dist = math.clamp(pinchStart / math.max(0.2, scale), 22, 170)
	else
		pinchStart = nil
	end
end)

-- ------------------------------------------------------------------ camera & frame loop

RunService:BindToRenderStep("KrawallKamera", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	camera.CameraType = Enum.CameraType.Scriptable
	if App.phase == "title" then
		goal.yaw += dt * 0.07
	end
	local pan = 40 * dt
	local fwd = Vector3.new(-math.sin(cam.yaw), 0, -math.cos(cam.yaw))
	local right = Vector3.new(math.cos(cam.yaw), 0, -math.sin(cam.yaw))
	if keysDown[Enum.KeyCode.W] or keysDown[Enum.KeyCode.Up] then
		goal.target += fwd * pan
	end
	if keysDown[Enum.KeyCode.S] or keysDown[Enum.KeyCode.Down] then
		goal.target -= fwd * pan
	end
	if keysDown[Enum.KeyCode.A] or keysDown[Enum.KeyCode.Left] then
		goal.target -= right * pan
	end
	if keysDown[Enum.KeyCode.D] or keysDown[Enum.KeyCode.Right] then
		goal.target += right * pan
	end
	if App.G then
		local hw, hh = App.G.W * TILE / 2, App.G.H * TILE / 2
		goal.target = Vector3.new(math.clamp(goal.target.X, -hw, hw), 0, math.clamp(goal.target.Z, -hh, hh))
	end
	local f = 1 - math.exp(-dt * 7)
	cam.yaw += (goal.yaw - cam.yaw) * f
	cam.pitch += (goal.pitch - cam.pitch) * f
	cam.dist += (goal.dist - cam.dist) * f
	cam.target = cam.target:Lerp(goal.target, f * 0.8)
	local cp = math.cos(cam.pitch)
	local pos = cam.target + Vector3.new(cam.dist * cp * math.sin(cam.yaw), cam.dist * math.sin(cam.pitch), cam.dist * cp * math.cos(cam.yaw))
	if Fx.shakeAmount > 0.01 then
		pos += Vector3.new((rnd:NextNumber() - 0.5) * Fx.shakeAmount, (rnd:NextNumber() - 0.5) * Fx.shakeAmount, 0)
	end
	camera.CFrame = CFrame.lookAt(pos, cam.target)
	camera.FieldOfView = 45
end)

RunService.RenderStepped:Connect(function(dt: number)
	Fx.update(dt)
	if App.board then
		updateVisuals(dt, os.clock())
	end
end)

-- ------------------------------------------------------------------ start

loadProgress()
ui.soundBtn:setText("Ton")
showTitle()
