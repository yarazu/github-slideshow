-- 3D-Modelle aus Parts: Helden als Roblox-Blockfiguren mit austauschbaren Skins,
-- Krawallos als runde, einäugige Monster. Vorderseite ist -Z (Roblox-Standard), Ursprung = Füße.

local Models = {}

local FACE = "rbxasset://textures/face.png"
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.fromHex("#14101e")

local function hex(c: string): Color3
	return Color3.fromHex(c)
end

local function newPart(model: Instance, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- Baukasten mit Skalierung: alle Maße unskaliert angeben
local function builder(model: Instance, s: number)
	local B = {}
	local function place(cf: CFrame): CFrame
		return CFrame.new(cf.Position * s) * (cf - cf.Position)
	end
	function B.cf(shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): Part
		return newPart(model, shape, size * s, place(cf), color, mat)
	end
	function B.block(size: Vector3, pos: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?): Part
		return B.cf(Enum.PartType.Block, size, CFrame.new(pos) * (rot or CFrame.new()), color, mat)
	end
	function B.ball(d: number, pos: Vector3, color: Color3, mat: Enum.Material?): Part
		return B.cf(Enum.PartType.Ball, Vector3.new(d, d, d), CFrame.new(pos), color, mat)
	end
	function B.ellipsoid(size: Vector3, pos: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?): Part
		local p = B.block(size, pos, color, mat, rot)
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Parent = p
		return p
	end
	-- Zylinder entlang der Blickrichtung (Läufe, Linsen)
	function B.zcyl(len: number, d: number, pos: Vector3, color: Color3, mat: Enum.Material?): Part
		return B.cf(Enum.PartType.Cylinder, Vector3.new(len, d, d), CFrame.new(pos) * CFrame.Angles(0, math.rad(90), 0), color, mat)
	end
	-- stehender Zylinder
	function B.vcyl(h: number, d: number, pos: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?): Part
		return B.cf(Enum.PartType.Cylinder, Vector3.new(h, d, d), CFrame.new(pos) * (rot or CFrame.new()) * CFrame.Angles(0, 0, math.rad(90)), color, mat)
	end
	-- Stufenkegel aus gestapelten Scheiben; base ist die Mitte der Grundfläche
	function B.cone(baseD: number, h: number, steps: number, base: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?): { Part }
		local frame = CFrame.new(base) * (rot or CFrame.new())
		local parts = {}
		for i = 0, steps - 1 do
			local d = baseD * (1 - (i / steps) * 0.85)
			local cf = frame * CFrame.new(0, h * (i + 0.5) / steps, 0) * CFrame.Angles(0, 0, math.rad(90))
			table.insert(parts, B.cf(Enum.PartType.Cylinder, Vector3.new(h / steps, d, d), cf, color, mat))
		end
		return parts
	end
	return B
end

-- ------------------------------------------------------------------ hero headgear (Kopfmitte y=4.6, Oberkante ~5.22)

local HATS = {}

HATS.zipfel = function(B, sk)
	B.vcyl(0.18, 1.55, Vector3.new(0, 5.2, 0), hex(sk.accent), Enum.Material.Metal)
	B.cone(1.3, 1.45, 5, Vector3.new(0, 5.28, 0.05), hex(sk.hatColor), nil, CFrame.Angles(math.rad(18), 0, 0))
	B.block(Vector3.new(0.12, 0.9, 0.32), Vector3.new(0.6, 5.65, 0.15), WHITE, nil, CFrame.Angles(0, 0, math.rad(-28)))
end

HATS.ritter = function(B, sk)
	B.block(Vector3.new(1.45, 1.4, 1.45), Vector3.new(0, 4.65, 0), hex(sk.hatColor), Enum.Material.Metal)
	B.block(Vector3.new(1.2, 0.14, 0.06), Vector3.new(0, 4.72, -0.74), BLACK)
	B.block(Vector3.new(0.06, 0.5, 0.06), Vector3.new(0, 4.45, -0.74), BLACK)
	local plume = B.block(Vector3.new(0.22, 0.55, 1.3), Vector3.new(0, 5.6, 0.1), hex(sk.accent), Enum.Material.Neon)
	B.block(Vector3.new(0.22, 0.4, 0.7), Vector3.new(0, 5.95, 0.45), hex(sk.accent), Enum.Material.Neon)
	return plume
end

HATS.dreispitz = function(B, sk)
	B.vcyl(0.14, 2.1, Vector3.new(0, 5.22, 0), hex(sk.hatColor))
	B.vcyl(0.06, 2.16, Vector3.new(0, 5.3, 0), hex(sk.accent), Enum.Material.Metal)
	B.vcyl(0.55, 1.35, Vector3.new(0, 5.55, 0), hex(sk.hatColor))
	B.block(Vector3.new(0.34, 0.34, 0.06), Vector3.new(0, 5.55, -0.69), hex(sk.accent), Enum.Material.Metal)
end

HATS.sternkrone = function(B, sk)
	B.vcyl(0.3, 1.42, Vector3.new(0, 5.2, 0), hex("#ffc63d"), Enum.Material.Metal)
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2
		B.block(Vector3.new(0.22, 0.6, 0.22), Vector3.new(math.sin(a) * 0.58, 5.62, math.cos(a) * 0.58), hex(sk.hatColor), Enum.Material.Neon)
	end
end

HATS.stahlhelm = function(B, sk)
	local mat = Enum.Material.Metal
	if sk.material == "Foil" then
		mat = Enum.Material.Foil
	end
	B.ellipsoid(Vector3.new(1.6, 1.15, 1.6), Vector3.new(0, 5.0, 0), hex(sk.hatColor), mat)
	B.vcyl(0.12, 1.72, Vector3.new(0, 4.98, 0), hex(sk.hatColor), mat)
	B.block(Vector3.new(0.18, 0.32, 1.3), Vector3.new(0, 5.55, 0), hex(sk.accent), mat)
end

HATS.hoernerhelm = function(B, sk)
	B.ellipsoid(Vector3.new(1.6, 1.15, 1.6), Vector3.new(0, 5.0, 0), hex(sk.hatColor), Enum.Material.Metal)
	B.vcyl(0.12, 1.72, Vector3.new(0, 4.98, 0), hex(sk.accent), Enum.Material.Neon)
	local horn = hex("#e8d9c0")
	B.cone(0.5, 1.0, 4, Vector3.new(-0.62, 5.2, 0), horn, nil, CFrame.Angles(0, 0, math.rad(35)))
	B.cone(0.5, 1.0, 4, Vector3.new(0.62, 5.2, 0), horn, nil, CFrame.Angles(0, 0, math.rad(-35)))
	local tip = B.ball(0.24, Vector3.new(-1.19, 6.0, 0), hex(sk.glow), Enum.Material.Neon)
	B.ball(0.24, Vector3.new(1.19, 6.0, 0), hex(sk.glow), Enum.Material.Neon)
	return tip
end

HATS.eiskrone = function(B, sk)
	B.vcyl(0.3, 1.42, Vector3.new(0, 5.2, 0), hex(sk.hatColor), Enum.Material.Ice)
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local h = if i % 2 == 0 then 0.95 else 0.6
		local p = B.block(Vector3.new(0.24, h, 0.24), Vector3.new(math.sin(a) * 0.58, 5.3 + h / 2, math.cos(a) * 0.58), hex(sk.hatColor), Enum.Material.Ice)
		p.Transparency = 0.15
	end
end

HATS.blatt = function(B, sk)
	B.block(Vector3.new(1.32, 0.16, 1.32), Vector3.new(0, 4.95, 0), hex("#5a3a22"))
	for _, x in ipairs({ -0.27, 0.27 }) do
		B.zcyl(0.16, 0.48, Vector3.new(x, 4.95, -0.66), hex(sk.accent), Enum.Material.Metal)
		B.zcyl(0.06, 0.32, Vector3.new(x, 4.95, -0.75), hex("#9fe8ff"), Enum.Material.Neon)
	end
	B.vcyl(0.35, 0.08, Vector3.new(0, 5.38, 0), hex("#3a7a2a"))
	B.ellipsoid(Vector3.new(0.45, 0.1, 0.85), Vector3.new(0.12, 5.6, 0.05), hex(sk.hatColor), nil, CFrame.Angles(0, 0, math.rad(25)))
end

HATS.ninja = function(B, sk)
	local fabric = Enum.Material.Fabric
	B.block(Vector3.new(1.36, 0.36, 1.36), Vector3.new(0, 4.98, 0), hex(sk.hatColor), fabric)
	B.block(Vector3.new(1.32, 0.5, 0.18), Vector3.new(0, 4.38, -0.58), hex(sk.hatColor), fabric)
	B.block(Vector3.new(1.45, 0.32, 1.3), Vector3.new(0, 4.05, 0), hex(sk.accent), fabric)
	B.block(Vector3.new(0.22, 0.12, 1.0), Vector3.new(0.25, 4.98, 1.1), hex(sk.accent), fabric, CFrame.Angles(math.rad(-20), math.rad(10), 0))
	B.block(Vector3.new(0.22, 0.12, 0.8), Vector3.new(-0.05, 4.9, 1.0), hex(sk.accent), fabric, CFrame.Angles(math.rad(-30), math.rad(-15), 0))
end

HATS.glashelm = function(B, sk)
	local dome = B.ball(1.95, Vector3.new(0, 4.62, 0), hex(sk.hatColor), Enum.Material.Glass)
	dome.Transparency = 0.6
	B.vcyl(0.28, 1.75, Vector3.new(0, 3.98, 0), hex(sk.accent), Enum.Material.Metal)
	B.vcyl(0.6, 0.06, Vector3.new(0.5, 5.55, 0.2), hex("#c9ccd6"), Enum.Material.Metal)
	B.ball(0.18, Vector3.new(0.5, 5.9, 0.2), hex(sk.glow), Enum.Material.Neon)
end

HATS.regenbogen = function(B, _sk)
	local colors = { "#ff4a4a", "#ff9d2a", "#ffe14a", "#5fd068", "#4fb4ff", "#9a5cf0" }
	for i, c in ipairs(colors) do
		B.block(Vector3.new(0.3, 0.55, 0.26), Vector3.new(0, 5.45, -0.6 + (i - 1) * 0.24), hex(c), Enum.Material.Neon)
	end
end

-- ------------------------------------------------------------------ weapons (rechte Hand bei x=hx, y=3.55, z=-1.75)

local WEAPONS = {}

WEAPONS.leo = function(B, sk, hx)
	B.zcyl(1.4, 0.42, Vector3.new(hx, 3.55, -2.3), hex(sk.weapon), Enum.Material.Metal)
	B.block(Vector3.new(0.3, 0.6, 0.35), Vector3.new(hx, 3.2, -1.95), hex("#3a2a1a"))
	B.ball(0.5, Vector3.new(hx, 3.55, -3.0), hex(sk.glow), Enum.Material.Neon)
	return Vector3.new(hx, 3.55, -3.2)
end

WEAPONS.bruna = function(B, sk, hx)
	B.zcyl(1.8, 0.58, Vector3.new(hx, 3.55, -2.45), hex(sk.weapon), Enum.Material.Metal)
	B.zcyl(0.4, 1.0, Vector3.new(hx, 3.55, -3.4), hex(sk.weapon), Enum.Material.Metal)
	B.zcyl(0.06, 0.7, Vector3.new(hx, 3.55, -3.62), hex(sk.glow), Enum.Material.Neon)
	return Vector3.new(hx, 3.55, -3.7)
end

WEAPONS.pip = function(B, sk, hx)
	B.zcyl(3.0, 0.24, Vector3.new(hx, 3.55, -3.0), hex(sk.weapon), Enum.Material.Metal)
	B.zcyl(0.9, 0.32, Vector3.new(hx, 3.92, -2.4), hex("#6b7088"), Enum.Material.Metal)
	B.block(Vector3.new(0.32, 0.5, 0.9), Vector3.new(hx, 3.35, -1.4), hex("#5a3a22"))
	B.ball(0.3, Vector3.new(hx, 3.55, -4.5), hex(sk.glow), Enum.Material.Neon)
	return Vector3.new(hx, 3.55, -4.6)
end

local HERO_SHAPE = {
	leo = { scale = 0.8, bulk = 1.0 },
	bruna = { scale = 0.86, bulk = 1.25 },
	pip = { scale = 0.7, bulk = 0.95 },
}

local function addEffect(kind: string?, part: BasePart?, glow: Color3)
	if not kind or not part then
		return
	end
	if kind == "fire" then
		local f = Instance.new("Fire")
		f.Size = 2
		f.Heat = 3
		f.Color = glow
		f.SecondaryColor = Color3.fromHex("#ffd84a")
		f.Parent = part
	elseif kind == "smoke" then
		local s = Instance.new("Smoke")
		s.Size = 0.4
		s.Opacity = 0.12
		s.RiseVelocity = 2
		s.Color = Color3.fromHex("#3a3236")
		s.Parent = part
	elseif kind == "sparkles" or kind == "snow" then
		local s = Instance.new("Sparkles")
		s.SparkleColor = glow
		s.Parent = part
	end
end

-- Baut einen Helden im gewählten Skin. Rückgabe: Model und Infos (Mündung, Höhe)
function Models.hero(kind: string, sk)
	local shape = HERO_SHAPE[kind]
	local s = shape.scale
	local bulk = shape.bulk
	local model = Instance.new("Model")
	model.Name = kind
	local B = builder(model, s)
	local mat = if sk.material then Enum.Material[sk.material] else Enum.Material.SmoothPlastic
	local shirt, pants, skinC, accent = hex(sk.shirt), hex(sk.pants), hex(sk.skin), hex(sk.accent)
	local accentMat = if sk.neonAccent then Enum.Material.Neon else Enum.Material.SmoothPlastic
	local tw = 2 * bulk
	local hx = tw / 2 + 0.5
	local armL, armR = shirt, shirt
	if sk.rainbow then
		armL, armR = hex("#4fb4ff"), hex("#ffe14a")
	end
	local shoe = pants:Lerp(BLACK, 0.55)

	-- Beine
	for _, side in ipairs({ -1, 1 }) do
		B.block(Vector3.new(1, 1.6, 1), Vector3.new(0.5 * bulk * side, 1.25, 0), pants, mat)
		B.block(Vector3.new(1.05, 0.45, 1.25), Vector3.new(0.5 * bulk * side, 0.225, -0.1), shoe)
	end
	-- Rumpf mit Gürtel
	local torso = B.block(Vector3.new(tw, 2, 1.05), Vector3.new(0, 3, 0), shirt, mat)
	B.block(Vector3.new(tw + 0.06, 0.3, 1.11), Vector3.new(0, 2.15, 0), accent, accentMat)
	B.block(Vector3.new(0.45, 0.36, 0.08), Vector3.new(0, 2.15, -0.58), hex("#ffd84a"), Enum.Material.Metal)
	if sk.rainbow then
		local stripes = { "#ff4a4a", "#ff9d2a", "#ffe14a", "#5fd068" }
		for i, c in ipairs(stripes) do
			B.block(Vector3.new(tw * 0.92, 0.28, 0.06), Vector3.new(0, 3.75 - (i - 1) * 0.36, -0.55), hex(c), Enum.Material.Neon)
		end
	elseif kind == "leo" and sk.hat == "dreispitz" then
		for i = 0, 2 do
			B.ball(0.2, Vector3.new(0, 3.6 - i * 0.45, -0.56), hex(sk.accent), Enum.Material.Metal)
		end
	end
	if kind == "bruna" then
		for _, side in ipairs({ -1, 1 }) do
			B.ellipsoid(Vector3.new(1.25, 0.7, 1.25), Vector3.new((tw / 2 + 0.35) * side, 4.0, 0), accent, if sk.material then mat else Enum.Material.Metal)
		end
	end
	-- Arme: links hängend, rechts mit der Waffe nach vorn
	B.block(Vector3.new(1, 2, 1), Vector3.new(-hx, 3, 0), armL, mat)
	B.block(Vector3.new(0.9, 0.5, 0.9), Vector3.new(-hx, 1.75, 0), skinC)
	B.block(Vector3.new(1, 2, 1), Vector3.new(hx, 3.55, -0.6), armR, mat, CFrame.Angles(math.rad(90), 0, 0))
	B.block(Vector3.new(0.9, 0.9, 0.5), Vector3.new(hx, 3.55, -1.75), skinC)
	-- Kopf im klassischen Roblox-Stil mit Standardgesicht
	local head = B.block(Vector3.new(1.25, 1.25, 1.25), Vector3.new(0, 4.6, 0), skinC)
	local hm = Instance.new("SpecialMesh")
	hm.MeshType = Enum.MeshType.Head
	hm.Parent = head
	local face = Instance.new("Decal")
	face.Texture = FACE
	face.Face = Enum.NormalId.Front
	face.Parent = head
	if sk.eyepatch then
		B.block(Vector3.new(0.3, 0.28, 0.08), Vector3.new(0.24, 4.68, -0.66), BLACK)
		B.block(Vector3.new(1.32, 0.07, 1.32), Vector3.new(0, 4.85, 0), BLACK, nil, CFrame.Angles(0, 0, math.rad(-14)))
	end
	if sk.backpack then
		B.block(Vector3.new(1.6, 1.6, 0.7), Vector3.new(0, 3.1, 0.88), hex("#e6e8ee"))
		for _, side in ipairs({ -1, 1 }) do
			B.vcyl(1.3, 0.5, Vector3.new(0.42 * side, 3.15, 1.35), accent, Enum.Material.Metal)
		end
	end
	local hatFn = HATS[sk.hat]
	local effectPart = nil
	if hatFn then
		effectPart = hatFn(B, sk)
	end
	local muzzle = WEAPONS[kind](B, sk, hx)
	addEffect(sk.effect, effectPart or torso, hex(sk.glow))
	model.WorldPivot = CFrame.new()
	return model, { muzzle = muzzle * s, height = 5.6 * s, glow = hex(sk.glow) }
end

-- ------------------------------------------------------------------ enemies

local ENEMY_SCALE = { grunt = 0.95, sniper = 0.88, brute = 1.2, king = 1.45 }

function Models.enemy(kind: string, def)
	local s = ENEMY_SCALE[kind] or 1
	local model = Instance.new("Model")
	model.Name = kind
	local B = builder(model, s)
	local c = hex(def.color)
	local light = c:Lerp(WHITE, 0.35)
	local dark = c:Lerp(Color3.new(0, 0, 0), 0.25)
	local horn = hex("#ffe7b0")
	for _, side in ipairs({ -1, 1 }) do
		B.ellipsoid(Vector3.new(0.95, 0.42, 1.15), Vector3.new(0.6 * side, 0.21, -0.2), dark)
	end
	B.ball(3.0, Vector3.new(0, 1.65, 0), c)
	B.ball(2.0, Vector3.new(0, 1.45, -0.62), light)
	B.ball(1.1, Vector3.new(0, 2.2, -1.12), WHITE)
	B.ball(0.52, Vector3.new(0, 2.2, -1.6), BLACK)
	B.ball(0.15, Vector3.new(0.13, 2.36, -1.84), WHITE, Enum.Material.Neon)
	B.block(Vector3.new(0.95, 0.16, 0.14), Vector3.new(0, 1.22, -1.42), BLACK)
	for _, side in ipairs({ -1, 1 }) do
		B.block(Vector3.new(0.2, 0.18, 0.08), Vector3.new(0.22 * side, 1.12, -1.48), WHITE)
	end
	B.cone(0.46, 0.9, 4, Vector3.new(-0.62, 2.85, 0), horn, nil, CFrame.Angles(0, 0, math.rad(25)))
	B.cone(0.46, 0.9, 4, Vector3.new(0.62, 2.85, 0), horn, nil, CFrame.Angles(0, 0, math.rad(-25)))
	local muzzle, top = Vector3.new(1.35, 1.5, -1.7), 3.6
	if kind == "grunt" then
		B.zcyl(1.4, 0.38, Vector3.new(1.35, 1.5, -0.95), hex("#5b5f70"), Enum.Material.Metal)
		B.ball(0.3, Vector3.new(1.35, 1.5, -1.7), hex("#ff5fd2"), Enum.Material.Neon)
	elseif kind == "sniper" then
		B.zcyl(2.4, 0.2, Vector3.new(1.25, 1.75, -1.0), hex("#7a4a2a"))
		B.ball(0.3, Vector3.new(1.25, 1.75, -2.25), hex("#ffc63d"), Enum.Material.Neon)
		B.vcyl(1.0, 0.08, Vector3.new(0, 3.55, 0.1), hex("#1f6f52"))
		B.ball(0.28, Vector3.new(0, 4.1, 0.1), hex("#ffc63d"), Enum.Material.Neon)
		muzzle = Vector3.new(1.25, 1.75, -2.3)
		top = 4.2
	elseif kind == "brute" then
		for _, side in ipairs({ -1, 1 }) do
			B.ball(1.05, Vector3.new(1.75 * side, 1.35, -0.55), light)
		end
		B.block(Vector3.new(1.3, 0.22, 0.25), Vector3.new(0, 2.78, -1.22), BLACK, nil, CFrame.Angles(math.rad(20), 0, 0))
		muzzle = Vector3.new(0, 1.5, -1.6)
	elseif kind == "king" then
		local gold = hex("#ffc63d")
		B.vcyl(0.45, 1.3, Vector3.new(0, 3.3, 0), gold, Enum.Material.Metal)
		for i = 0, 4 do
			local a = i / 5 * math.pi * 2
			B.block(Vector3.new(0.2, 0.45, 0.2), Vector3.new(math.sin(a) * 0.55, 3.72, math.cos(a) * 0.55), gold, Enum.Material.Metal)
		end
		B.ball(0.24, Vector3.new(0, 3.3, -0.66), hex("#ff3d6e"), Enum.Material.Neon)
		B.block(Vector3.new(2.7, 2.5, 0.16), Vector3.new(0, 1.7, 1.3), hex("#7d1f9e"), Enum.Material.Fabric, CFrame.Angles(math.rad(-12), 0, 0))
		B.vcyl(2.8, 0.14, Vector3.new(1.75, 1.6, -0.45), hex("#6b4a2a"))
		B.ball(0.5, Vector3.new(1.75, 3.05, -0.45), gold, Enum.Material.Metal)
		muzzle = Vector3.new(1.75, 3.05, -0.8)
		top = 4.1
	end
	model.WorldPivot = CFrame.new()
	return model, { muzzle = muzzle * s, height = top * s }
end

return Models
