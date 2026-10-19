-- Animationen und Effekte: Zeit-Tweens (blockierend, für Abläufe), Partikel, Projektile,
-- Schadenszahlen, Ringwellen und Sounds. Alles nur aus Parts und Roblox-eigenen Client-Assets.

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Fx = {}
Fx.speed = 1
Fx.muted = false
Fx.shakeAmount = 0
Fx.folder = nil :: Folder?

local INK_DEEP = Color3.fromHex("#120c20")

-- Blockierender Tween: ruft fn(k) mit k von 0 bis 1 auf und kehrt erst danach zurück.
function Fx.tween(dur: number, fn: (number) -> ())
	if dur <= 0 then
		fn(1)
		return
	end
	local t = 0
	fn(0)
	while t < dur do
		local dt = RunService.Heartbeat:Wait()
		t += dt * Fx.speed
		fn(math.min(1, t / dur))
	end
end

function Fx.sleep(s: number)
	Fx.tween(s, function() end)
end

function Fx.ease(k: number): number
	if k < 0.5 then
		return 2 * k * k
	end
	return 1 - ((-2 * k + 2) ^ 2) / 2
end

local function newPart(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = Fx.folder
	return p
end
Fx.newPart = newPart

-- ------------------------------------------------------------------ particles

local particles = {}

function Fx.burst(pos: Vector3, color: Color3, n: number?, spd: number?, life: number?, size: number?, up: number?, grav: number?)
	local count = n or 12
	local speed = spd or 12
	local lifetime = life or 0.55
	local sz = size or 0.36
	local upward = if up == nil then 6 else up
	local g = if grav == nil then 1 else grav
	for _ = 1, count do
		local s = sz * (0.6 + math.random() * 0.8)
		local p = newPart(Vector3.new(s, s, s), CFrame.new(pos), color, Enum.Material.Neon)
		local a = math.random() * math.pi * 2
		local r = speed * (0.3 + math.random() * 0.7)
		table.insert(particles, {
			part = p,
			v = Vector3.new(math.cos(a) * r, upward + math.random() * speed * 0.8, math.sin(a) * r),
			life = lifetime,
			max = lifetime,
			s = s,
			g = g,
			spin = Vector3.new(math.random() * 6, math.random() * 6, 0),
		})
	end
end

function Fx.update(dt: number)
	for i = #particles, 1, -1 do
		local p = particles[i]
		p.life -= dt
		if p.life <= 0 then
			p.part:Destroy()
			table.remove(particles, i)
		else
			p.v += Vector3.new(0, -36 * dt * p.g, 0)
			local s = math.max(0.05, p.s * (p.life / p.max))
			p.part.Size = Vector3.new(s, s, s)
			p.part.CFrame = (p.part.CFrame + p.v * dt) * CFrame.Angles(p.spin.X * dt, p.spin.Y * dt, 0)
		end
	end
	Fx.shakeAmount *= math.exp(-dt * 10)
end

function Fx.clear()
	for _, p in ipairs(particles) do
		p.part:Destroy()
	end
	table.clear(particles)
end

function Fx.shake(a: number)
	Fx.shakeAmount = math.max(Fx.shakeAmount, a)
end

-- ------------------------------------------------------------------ projectiles & waves

function Fx.projectile(from: Vector3, to: Vector3, color: Color3)
	local ball = newPart(Vector3.new(0.55, 0.55, 0.55), CFrame.new(from), color, Enum.Material.Neon, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Brightness = 2
	light.Parent = ball
	local d = (to - from).Magnitude
	local frame = 0
	Fx.tween(math.max(0.12, d / 68), function(k)
		local pos = from:Lerp(to, k) + Vector3.new(0, math.sin(k * math.pi) * d * 0.035, 0)
		ball.CFrame = CFrame.new(pos)
		frame += 1
		if frame % 2 == 0 then
			Fx.burst(pos, color, 1, 1, 0.25, 0.25, 0.4, 0)
		end
	end)
	ball:Destroy()
	Fx.burst(to, color, 10, 10, 0.45, 0.32)
end

function Fx.ringWave(pos: Vector3, color: Color3, radius: number)
	local disc = newPart(Vector3.new(0.2, 1, 1), CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.Neon, Enum.PartType.Cylinder)
	disc.Transparency = 0.35
	Fx.tween(0.45, function(k)
		local d = 1 + Fx.ease(k) * radius * 2
		disc.Size = Vector3.new(0.2, d, d)
		disc.Transparency = 0.35 + 0.6 * k
	end)
	disc:Destroy()
end

-- ------------------------------------------------------------------ floating text

local STYLES = {
	dmg = { color = "#ffe25a", size = 34 },
	heroDmg = { color = "#ff6b6b", size = 34 },
	heal = { color = "#7dff8a", size = 32 },
	miss = { color = "#e2daf3", size = 26 },
	fx = { color = "#ffa24a", size = 26 },
	info = { color = "#8fe9ff", size = 24 },
}

function Fx.floatText(pos: Vector3, text: string, style: string?)
	local st = STYLES[style or "dmg"] or STYLES.dmg
	local anchor = newPart(Vector3.new(0.2, 0.2, 0.2), CFrame.new(pos), Color3.new(1, 1, 1))
	anchor.Transparency = 1
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(320, 60)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Adornee = anchor
	bb.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextSize = st.size
	label.TextColor3 = Color3.fromHex(st.color)
	label.Parent = bb
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = INK_DEEP
	stroke.Parent = label
	task.spawn(function()
		local t = 0
		while t < 1.3 do
			t += RunService.RenderStepped:Wait()
			bb.StudsOffsetWorldSpace = Vector3.new(0, t * 3.6, 0)
			local fade = math.max(0, (t - 0.85) / 0.45)
			label.TextTransparency = fade
			stroke.Transparency = fade
			label.TextSize = if t < 0.12 then st.size * (0.6 + t / 0.12 * 0.5) elseif t < 0.22 then st.size * (1.1 - (t - 0.12)) else st.size
		end
		anchor:Destroy()
	end)
end

-- ------------------------------------------------------------------ sounds (Roblox-eigene Client-Sounds, keine Uploads nötig)

local SOUNDS = {
	select = { "rbxasset://sounds/electronicpingshort.wav", 1.2, 0.35 },
	step = { "rbxasset://sounds/action_footsteps_plastic.mp3", 1.4, 0.15 },
	jump = { "rbxasset://sounds/action_jump.mp3", 1, 0.5 },
	land = { "rbxasset://sounds/action_jump_land.mp3", 1, 0.5 },
	shoot = { "rbxasset://sounds/paintball.wav", 1, 0.45 },
	hit = { "rbxasset://sounds/swordslash.wav", 0.9, 0.5 },
	dash = { "rbxasset://sounds/swordlunge.wav", 1, 0.55 },
	ko = { "rbxasset://sounds/uuhhh.mp3", 1, 0.5 },
	splash = { "rbxasset://sounds/impact_water.mp3", 1, 0.6 },
	crack = { "rbxasset://sounds/collide.wav", 0.8, 0.5 },
	turn = { "rbxasset://sounds/electronicpingshort.wav", 1.5, 0.4 },
	foe = { "rbxasset://sounds/electronicpingshort.wav", 0.6, 0.4 },
	heal = { "rbxasset://sounds/electronicpingshort.wav", 1.9, 0.4 },
	shield = { "rbxasset://sounds/electronicpingshort.wav", 0.9, 0.45 },
	watch = { "rbxasset://sounds/electronicpingshort.wav", 2.2, 0.35 },
	quake = { "rbxasset://sounds/collide.wav", 0.4, 0.8 },
	win = { "rbxasset://sounds/electronicpingshort.wav", 1.3, 0.6 },
	lose = { "rbxasset://sounds/uuhhh.mp3", 0.7, 0.5 },
}

function Fx.sound(name: string)
	if Fx.muted then
		return
	end
	local def = SOUNDS[name]
	if not def then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = def[1]
	s.PlaybackSpeed = def[2]
	s.Volume = def[3]
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 4)
end

return Fx
