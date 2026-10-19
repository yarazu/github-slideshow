-- Spielfeld-Darstellung: Bodenfelder, Mauern, Kisten, Markierungen (Laufen, Teamsprung, Reichweite, Gefahr),
-- Deckungsanzeige, Reichweitenkreis, Deko-Inseln und Beleuchtung je Level.

local Lighting = game:GetService("Lighting")

local Board = {}
Board.__index = Board

local TILE = 4

local function hex(c: string): Color3
	return Color3.fromHex(c)
end

local function newPart(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function key(x: number, z: number): number
	return x * 1000 + z
end

local OVERLAY = {
	move = { "#3fa8ff", 0.35 },
	jump = { "#ffc63d", 0.3 },
	range = { "#ff5a4a", 0.72 },
	area = { "#5ee3d2", 0.5 },
}

function Board.new(G, parent: Instance)
	local self = setmetatable({}, Board)
	self.G = G
	self.W = G.W
	self.H = G.H
	self.theme = G.level.theme
	self.folder = Instance.new("Folder")
	self.folder.Name = "Spielfeld"
	self.folder.Parent = parent
	self.tops = {}
	self.covers = {}
	self.overlays = {}
	self.dangers = {}
	self.shownOverlays = {}
	self.shownDangers = {}
	self:buildTiles()
	self:buildMarkers()
	self:buildDecor()
	self:applyLighting()
	return self
end

function Board:tilePos(x: number, z: number, y: number?): Vector3
	return Vector3.new((x - self.W / 2 + 0.5) * TILE, y or 0, (z - self.H / 2 + 0.5) * TILE)
end

function Board:destroy()
	self.folder:Destroy()
end

-- ------------------------------------------------------------------ tiles & cover

function Board:buildTiles()
	local th = self.theme
	local cA, cB, side = hex(th.a), hex(th.b), hex(th.side)
	local floorMat = if th.floor == "stone" then Enum.Material.Cobblestone else Enum.Material.Grass
	for z = 0, self.H - 1 do
		for x = 0, self.W - 1 do
			local t = self.G:tileAt(x, z)
			if t.type ~= "water" then
				local pos = self:tilePos(x, z)
				local top = newPart(self.folder, Vector3.new(TILE - 0.08, 1, TILE - 0.08), CFrame.new(pos + Vector3.new(0, -0.5, 0)), if (x + z) % 2 == 0 then cA else cB, floorMat)
				local base = newPart(self.folder, Vector3.new(TILE - 0.08, 7, TILE - 0.08), CFrame.new(pos + Vector3.new(0, -4.5, 0)), side, Enum.Material.Ground)
				for _, p in ipairs({ top, base }) do
					p.CanQuery = true
					p:SetAttribute("TX", x)
					p:SetAttribute("TZ", z)
				end
				self.tops[key(x, z)] = top
				if t.type == "wall" then
					self:buildWall(x, z, pos)
				elseif t.type == "low" then
					self:buildCrate(x, z, pos)
				end
			end
		end
	end
end

function Board:buildWall(x: number, z: number, pos: Vector3)
	local wall = newPart(self.folder, Vector3.new(3.6, 6, 3.6), CFrame.new(pos + Vector3.new(0, 3, 0)) * CFrame.Angles(0, ((x * 7 + z * 3) % 4) * math.pi / 2, 0), hex("#a79fb8"), Enum.Material.Brick)
	local cap = newPart(self.folder, Vector3.new(3.95, 0.6, 3.95), CFrame.new(pos + Vector3.new(0, 6.3, 0)), hex("#8c84a0"), Enum.Material.Slate)
	for _, p in ipairs({ wall, cap }) do
		p.CanQuery = true
		p:SetAttribute("TX", x)
		p:SetAttribute("TZ", z)
	end
	self.covers[key(x, z)] = { wall, cap }
end

function Board:buildCrate(x: number, z: number, pos: Vector3)
	local yaw = (((x * 5 + z * 11) % 7) - 3) * 0.06
	local base = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	local parts = {}
	local body = newPart(self.folder, Vector3.new(3.1, 2.6, 3.1), base * CFrame.new(0, 1.3, 0), hex("#c98a4b"), Enum.Material.WoodPlanks)
	body.CanQuery = true
	body:SetAttribute("TX", x)
	body:SetAttribute("TZ", z)
	table.insert(parts, body)
	local frame = hex("#7a4524")
	for _, cx in ipairs({ -1.45, 1.45 }) do
		for _, cz in ipairs({ -1.45, 1.45 }) do
			table.insert(parts, newPart(self.folder, Vector3.new(0.4, 2.7, 0.4), base * CFrame.new(cx, 1.35, cz), frame, Enum.Material.Wood))
		end
	end
	table.insert(parts, newPart(self.folder, Vector3.new(0.35, 0.35, 3.9), base * CFrame.new(0, 1.3, -1.58) * CFrame.Angles(0, math.rad(90), math.rad(40)), frame, Enum.Material.Wood))
	table.insert(parts, newPart(self.folder, Vector3.new(0.35, 0.35, 3.9), base * CFrame.new(0, 1.3, 1.58) * CFrame.Angles(0, math.rad(90), math.rad(-40)), frame, Enum.Material.Wood))
	self.covers[key(x, z)] = parts
end

-- Kiste getroffen oder zerstört; liefert die Mitte für Effekte
function Board:crateHit(x: number, z: number, destroyed: boolean): Vector3
	local parts = self.covers[key(x, z)]
	local center = self:tilePos(x, z, 1.4)
	if not parts then
		return center
	end
	if destroyed then
		for _, p in ipairs(parts) do
			p:Destroy()
		end
		self.covers[key(x, z)] = nil
	else
		for _, p in ipairs(parts) do
			p.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, 0.12) * CFrame.new(-center) * p.CFrame
			p.Color = p.Color:Lerp(Color3.new(0, 0, 0), 0.25)
		end
	end
	return center
end

-- ------------------------------------------------------------------ markers

function Board:buildMarkers()
	for z = 0, self.H - 1 do
		for x = 0, self.W - 1 do
			if self.G:tileAt(x, z).type ~= "water" then
				local pos = self:tilePos(x, z)
				local o = newPart(self.folder, Vector3.new(3.5, 0.08, 3.5), CFrame.new(pos + Vector3.new(0, 0.06, 0)), Color3.new(1, 1, 1))
				o.Transparency = 1
				o.CastShadow = false
				self.overlays[key(x, z)] = o
				local d = newPart(self.folder, Vector3.new(2.2, 0.08, 2.2), CFrame.new(pos + Vector3.new(0, 0.1, 0)), hex("#ff3d6e"))
				d.Transparency = 1
				d.CastShadow = false
				self.dangers[key(x, z)] = d
			end
		end
	end
	-- Hover-Rahmen aus vier Leuchtleisten
	self.hoverBars = {}
	for i = 1, 4 do
		local b = newPart(self.folder, Vector3.new(3.9, 0.12, 0.22), CFrame.new(), Color3.new(1, 1, 1), Enum.Material.Neon)
		b.CastShadow = false
		b.Transparency = 1
		self.hoverBars[i] = b
	end
	self.dots = {}
	self.dotsUsed = 0
	self.shields = {}
	for i = 1, 4 do
		local s = newPart(self.folder, Vector3.new(2.6, 1.2, 0.22), CFrame.new(), hex("#ffc63d"), Enum.Material.Neon)
		s.Transparency = 1
		s.CastShadow = false
		self.shields[i] = s
	end
	self.ring = {}
	for i = 1, 80 do
		local r = newPart(self.folder, Vector3.new(0.5, 0.1, 0.25), CFrame.new(), Color3.new(1, 1, 1), Enum.Material.Neon)
		r.Transparency = 1
		r.CastShadow = false
		self.ring[i] = r
	end
end

function Board:setOverlay(x: number, z: number, kind: string)
	local o = self.overlays[key(x, z)]
	local st = OVERLAY[kind]
	if not o or not st then
		return
	end
	o.Color = hex(st[1])
	o.Transparency = st[2]
	self.shownOverlays[key(x, z)] = true
end

function Board:clearOverlays()
	for k in pairs(self.shownOverlays) do
		self.overlays[k].Transparency = 1
	end
	table.clear(self.shownOverlays)
end

function Board:setDanger(x: number, z: number)
	local d = self.dangers[key(x, z)]
	if d then
		d.Transparency = 0.45
		self.shownDangers[key(x, z)] = true
	end
end

function Board:clearDanger()
	for k in pairs(self.shownDangers) do
		self.dangers[k].Transparency = 1
	end
	table.clear(self.shownDangers)
end

function Board:setHover(x: number?, z: number?)
	if x == nil or z == nil then
		for _, b in ipairs(self.hoverBars) do
			b.Transparency = 1
		end
		return
	end
	local c = self:tilePos(x, z, 0.12)
	local h = TILE / 2 - 0.08
	local cfs = {
		CFrame.new(c + Vector3.new(0, 0, -h)),
		CFrame.new(c + Vector3.new(0, 0, h)),
		CFrame.new(c + Vector3.new(-h, 0, 0)) * CFrame.Angles(0, math.rad(90), 0),
		CFrame.new(c + Vector3.new(h, 0, 0)) * CFrame.Angles(0, math.rad(90), 0),
	}
	for i, b in ipairs(self.hoverBars) do
		b.CFrame = cfs[i]
		b.Transparency = 0.05
	end
end

function Board:addDot(p: Vector3)
	self.dotsUsed += 1
	local d = self.dots[self.dotsUsed]
	if not d then
		d = newPart(self.folder, Vector3.new(0.4, 0.4, 0.4), CFrame.new(), Color3.new(1, 1, 1), Enum.Material.Neon, Enum.PartType.Ball)
		d.CastShadow = false
		self.dots[self.dotsUsed] = d
	end
	d.CFrame = CFrame.new(p)
	d.Transparency = 0
end

function Board:clearDots()
	for _, d in ipairs(self.dots) do
		d.Transparency = 1
	end
	self.dotsUsed = 0
end

function Board:drawPath(path)
	for _, p in ipairs(path) do
		self:addDot(self:tilePos(p[1], p[2], 0.45))
	end
end

function Board:drawArc(a: Vector3, b: Vector3)
	for i = 1, 9 do
		local k = i / 10
		local p = a:Lerp(b, k) + Vector3.new(0, math.sin(math.pi * k) * 8.5 + 0.45, 0)
		self:addDot(p)
	end
end

-- Deckungsanzeige am Feldrand: niedrig/gelb = halbe, hoch/grün = volle Deckung
function Board:showShields(x: number, z: number, coverVal: (any) -> number)
	local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	for i, d in ipairs(dirs) do
		local v = coverVal(self.G:tileAt(x + d[1], z + d[2]))
		local s = self.shields[i]
		if v == 0 then
			s.Transparency = 1
		else
			local h = if v == 2 then 2.4 else 1.2
			s.Size = Vector3.new(2.6, h, 0.22)
			s.Color = if v == 2 then hex("#5fd068") else hex("#ffc63d")
			local pos = self:tilePos(x, z, h / 2 + 0.1) + Vector3.new(d[1], 0, d[2]) * (TILE / 2 - 0.35)
			local rot = if d[1] ~= 0 then CFrame.Angles(0, math.rad(90), 0) else CFrame.new()
			s.CFrame = CFrame.new(pos) * rot
			s.Transparency = 0.25
		end
	end
end

function Board:hideShields()
	for _, s in ipairs(self.shields) do
		s.Transparency = 1
	end
end

function Board:showRange(x: number, z: number, radiusTiles: number, color: Color3)
	local c = self:tilePos(x, z, 0.14)
	local r = radiusTiles * TILE
	local n = #self.ring
	local seg = 2 * math.pi * r / n
	for i, p in ipairs(self.ring) do
		local a = (i - 0.5) / n * math.pi * 2
		p.Size = Vector3.new(seg + 0.05, 0.1, 0.28)
		p.CFrame = CFrame.new(c + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)) * CFrame.Angles(0, -a + math.pi / 2, 0)
		p.Color = color
		p.Transparency = 0.15
	end
end

function Board:hideRange()
	for _, p in ipairs(self.ring) do
		p.Transparency = 1
	end
end

-- ------------------------------------------------------------------ decor

local function tree(parent: Instance, base: Vector3, s: number, rnd: Random)
	newPart(parent, Vector3.new(3.2, 0.5, 0.5) * s, CFrame.new(base + Vector3.new(0, 1.6 * s, 0)) * CFrame.Angles(0, 0, math.rad(90)), hex("#7a4a2a"), Enum.Material.Wood, Enum.PartType.Cylinder)
	local greens = { "#3f9b46", "#4fae4f", "#2f8a3f" }
	for i = 0, 2 do
		local d = (3.2 - i * 0.6) * s
		newPart(parent, Vector3.new(d, d, d), CFrame.new(base + Vector3.new((rnd:NextNumber() - 0.5) * 0.8 * s, (3.6 + i * 1.2) * s, (rnd:NextNumber() - 0.5) * 0.8 * s)), hex(greens[i + 1]), Enum.Material.Grass, Enum.PartType.Ball)
	end
end

local function mushroom(parent: Instance, base: Vector3, s: number, rnd: Random)
	newPart(parent, Vector3.new(2.2, 0.6, 0.6) * s, CFrame.new(base + Vector3.new(0, 1.1 * s, 0)) * CFrame.Angles(0, 0, math.rad(90)), hex("#f4e3c4"), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	local caps = { "#e2483f", "#f08a2e", "#8f6bd8" }
	local cap = newPart(parent, Vector3.new(3.2, 1.6, 3.2) * s, CFrame.new(base + Vector3.new(0, 2.3 * s, 0)), hex(caps[rnd:NextInteger(1, #caps)]))
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = cap
	for _ = 1, 5 do
		local a = rnd:NextNumber() * math.pi * 2
		local r = rnd:NextNumber() * 1.1 * s
		newPart(parent, Vector3.new(0.45, 0.45, 0.45) * s, CFrame.new(base + Vector3.new(math.cos(a) * r, 2.3 * s + math.sqrt(math.max(0, 0.64 - (r / (1.6 * s)) ^ 2)) * 0.8 * s * 1.1, math.sin(a) * r)), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end
end

local function pillar(parent: Instance, base: Vector3, h: number)
	newPart(parent, Vector3.new(h, 1.6, 1.6), CFrame.new(base + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)), hex("#c9bfd8"), Enum.Material.Marble, Enum.PartType.Cylinder)
	newPart(parent, Vector3.new(2.3, 0.5, 2.3), CFrame.new(base + Vector3.new(0, h, 0)), hex("#b3a8c6"), Enum.Material.Marble)
	newPart(parent, Vector3.new(2.3, 0.5, 2.3), CFrame.new(base + Vector3.new(0, 0.25, 0)), hex("#b3a8c6"), Enum.Material.Marble)
end

function Board:buildDecor()
	local th = self.theme
	local rnd = Random.new(17 + self.G.li * 31)
	local deco = Instance.new("Folder")
	deco.Name = "Deko"
	deco.Parent = self.folder
	local R = math.max(self.W, self.H) / 2 * TILE
	local halfW, halfH = self.W / 2 * TILE, self.H / 2 * TILE
	local placed, guard = 0, 0
	while placed < 16 and guard < 400 do
		guard += 1
		local a = rnd:NextNumber() * math.pi * 2
		local d = R + 12 + rnd:NextNumber() * 50
		local x, z = math.cos(a) * d, math.sin(a) * d
		if math.abs(x) > halfW + 9 or math.abs(z) > halfH + 9 then
			local size = 4 + rnd:NextNumber() * 6
			newPart(deco, Vector3.new(6, size * 2, size * 2), CFrame.new(x, -3.2, z) * CFrame.Angles(0, 0, math.rad(90)), hex(th.side), Enum.Material.Ground, Enum.PartType.Cylinder)
			newPart(deco, Vector3.new(0.8, size * 2.05, size * 2.05), CFrame.new(x, -0.1, z) * CFrame.Angles(0, 0, math.rad(90)), if th.floor == "stone" then hex("#7a7184") else hex(th.b), if th.floor == "stone" then Enum.Material.Slate else Enum.Material.Grass, Enum.PartType.Cylinder)
			local n = rnd:NextInteger(1, 3)
			for _ = 1, n do
				local p = Vector3.new(x + (rnd:NextNumber() - 0.5) * size, 0.3, z + (rnd:NextNumber() - 0.5) * size)
				if th.decor == "castle" then
					pillar(deco, p, 3 + rnd:NextNumber() * 4)
				elseif rnd:NextNumber() < 0.5 then
					tree(deco, p, 0.8 + rnd:NextNumber() * 0.6, rnd)
				else
					mushroom(deco, p, 0.8 + rnd:NextNumber() * 0.7, rnd)
				end
			end
			placed += 1
		end
	end
	if th.decor == "castle" then
		self:buildCastle(deco)
	elseif th.decor == "ruins" then
		for _ = 1, 6 do
			pillar(deco, Vector3.new((rnd:NextNumber() - 0.5) * (self.W * TILE + 60), -2, -halfH - 22 - rnd:NextNumber() * 30), 6 + rnd:NextNumber() * 10)
		end
	end
end

function Board:buildCastle(parent: Instance)
	local wall, roof, dark = hex("#6a5a86"), hex("#c23cd6"), hex("#3a2d55")
	local z0 = -self.H / 2 * TILE - 50
	newPart(parent, Vector3.new(64, 18, 8), CFrame.new(0, 7, z0), wall, Enum.Material.Brick)
	for i = -3, 3 do
		newPart(parent, Vector3.new(4, 3, 8), CFrame.new(i * 9.2, 17.5, z0), wall, Enum.Material.Brick)
	end
	local towers = { { -34, 28 }, { 34, 28 }, { -14, 38 }, { 14, 38 }, { 0, 48 } }
	for i, t in ipairs(towers) do
		local tz = if i > 2 then z0 - 6 else z0
		newPart(parent, Vector3.new(t[2], 11, 11), CFrame.new(t[1], t[2] / 2 - 2, tz) * CFrame.Angles(0, 0, math.rad(90)), wall, Enum.Material.Brick, Enum.PartType.Cylinder)
		for k = 0, 5 do
			local d = 13 * (1 - k / 6 * 0.9)
			newPart(parent, Vector3.new(2, d, d), CFrame.new(t[1], t[2] - 2 + 1 + k * 2, tz) * CFrame.Angles(0, 0, math.rad(90)), roof, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		end
		newPart(parent, Vector3.new(1.4, 2.8, 0.4), CFrame.new(t[1], t[2] * 0.7, tz - 5.5), hex("#ffd27a"), Enum.Material.Neon)
	end
	newPart(parent, Vector3.new(10, 11, 0.8), CFrame.new(0, 3.5, z0 - 4.2 + 8.5), dark)
end

-- ------------------------------------------------------------------ lighting

function Board:applyLighting()
	local th = self.theme
	Lighting.ClockTime = th.clock
	Lighting.Brightness = th.brightness
	Lighting.OutdoorAmbient = hex(th.ambient)
	Lighting.Ambient = hex(th.ambient):Lerp(Color3.new(0, 0, 0), 0.5)
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.6
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm then
		atm = Instance.new("Atmosphere")
		atm.Parent = Lighting
	end
	atm.Density = 0.28
	atm.Offset = 0.1
	atm.Color = hex(th.atmosphere)
	atm.Decay = hex(th.decay)
	atm.Glare = 0.25
	atm.Haze = 1.2
	local cc = Lighting:FindFirstChild("KrawallFarbe")
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "KrawallFarbe"
		cc.Parent = Lighting
	end
	cc.Saturation = 0.12
	cc.Contrast = 0.05
	local terrain = workspace.Terrain
	terrain.WaterColor = hex(th.water)
end

return Board
