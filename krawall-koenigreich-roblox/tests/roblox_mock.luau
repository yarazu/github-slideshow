-- Minimale Nachbildung der Roblox-API für Headless-Tests mit dem Luau-Interpreter.
-- Wird von tools/run_client_test.py vor den Spielskripten in eine Testdatei gebündelt.
-- Unbekannte Eigenschaften, Methoden und Enum-Werte lösen Fehler aus, damit Tippfehler auffallen.

local Mock = { errors = {}, warnings = {}, now = 0, nextHit = nil, guiAt = {} }

local function report(kind, msg)
	table.insert(if kind == "warn" then Mock.warnings else Mock.errors, msg)
	print("[" .. kind .. "] " .. msg)
end

-- ------------------------------------------------------------------ Vector3 / Vector2

local Vector3 = {}
local V3MT = {}
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3MT)
end
local function isV3(v)
	return getmetatable(v) == V3MT
end
V3MT.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(v.X / m, v.Y / m, v.Z / m)
	elseif k == "Lerp" then
		return function(a, b, t)
			return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
		end
	elseif k == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	elseif k == "Cross" then
		return function(a, b)
			return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
		end
	end
	error("Vector3 hat kein Feld " .. tostring(k), 2)
end
V3MT.__add = function(a, b)
	assert(isV3(a) and isV3(b), "Vector3 + erwartet zwei Vector3")
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3MT.__sub = function(a, b)
	assert(isV3(a) and isV3(b), "Vector3 - erwartet zwei Vector3")
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3MT.__mul = function(a, b)
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3MT.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3MT.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V3MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3MT.__tostring = function(v)
	return string.format("%.2f, %.2f, %.2f", v.X, v.Y, v.Z)
end
Vector3.new = function(x, y, z)
	for _, c in ipairs({ x or 0, y or 0, z or 0 }) do
		assert(type(c) == "number" and c == c, "Vector3.new mit ungültigem Wert")
	end
	return v3(x, y, z)
end
Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)

local Vector2 = {}
local V2MT = {}
local function v2(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2MT)
end
V2MT.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y)
	end
	error("Vector2 hat kein Feld " .. tostring(k), 2)
end
V2MT.__add = function(a, b)
	return v2(a.X + b.X, a.Y + b.Y)
end
V2MT.__sub = function(a, b)
	return v2(a.X - b.X, a.Y - b.Y)
end
V2MT.__mul = function(a, b)
	if type(a) == "number" then
		return v2(a * b.X, a * b.Y)
	end
	return v2(a.X * b, a.Y * b)
end
Vector2.new = function(x, y)
	return v2(x, y)
end
Vector2.zero = v2(0, 0)

-- ------------------------------------------------------------------ CFrame (Position + Rotationsmatrix)

local CFrame = {}
local CFMT = {}
local function cf(x, y, z, r)
	return setmetatable({ _x = x, _y = y, _z = z, _r = r }, CFMT)
end
local IDR = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function matmul(a, b)
	local o = {}
	for i = 0, 2 do
		for j = 0, 2 do
			local s = 0
			for k = 0, 2 do
				s += a[i * 3 + k + 1] * b[k * 3 + j + 1]
			end
			o[i * 3 + j + 1] = s
		end
	end
	return o
end
local function rotv(r, v)
	return v3(r[1] * v.X + r[2] * v.Y + r[3] * v.Z, r[4] * v.X + r[5] * v.Y + r[6] * v.Z, r[7] * v.X + r[8] * v.Y + r[9] * v.Z)
end
CFMT.__index = function(c, k)
	if k == "Position" then
		return v3(c._x, c._y, c._z)
	elseif k == "X" then
		return c._x
	elseif k == "Y" then
		return c._y
	elseif k == "Z" then
		return c._z
	elseif k == "LookVector" then
		return v3(-c._r[3], -c._r[6], -c._r[9])
	elseif k == "Rotation" then
		return cf(0, 0, 0, c._r)
	elseif k == "VectorToWorldSpace" then
		return function(self, v)
			return rotv(self._r, v)
		end
	elseif k == "PointToWorldSpace" then
		return function(self, v)
			return rotv(self._r, v) + v3(self._x, self._y, self._z)
		end
	end
	error("CFrame hat kein Feld " .. tostring(k), 2)
end
CFMT.__mul = function(a, b)
	if getmetatable(b) == CFMT then
		local p = rotv(a._r, v3(b._x, b._y, b._z))
		return cf(p.X + a._x, p.Y + a._y, p.Z + a._z, matmul(a._r, b._r))
	elseif isV3(b) then
		return rotv(a._r, b) + v3(a._x, a._y, a._z)
	end
	error("CFrame * erwartet CFrame oder Vector3", 2)
end
CFMT.__add = function(a, b)
	assert(isV3(b), "CFrame + erwartet Vector3")
	return cf(a._x + b.X, a._y + b.Y, a._z + b.Z, a._r)
end
CFMT.__sub = function(a, b)
	assert(isV3(b), "CFrame - erwartet Vector3")
	return cf(a._x - b.X, a._y - b.Y, a._z - b.Z, a._r)
end
CFrame.new = function(x, y, z)
	if x == nil then
		return cf(0, 0, 0, IDR)
	end
	if isV3(x) then
		return cf(x.X, x.Y, x.Z, IDR)
	end
	assert(type(x) == "number" and type(y) == "number" and type(z) == "number", "CFrame.new erwartet Zahlen")
	return cf(x, y, z, IDR)
end
CFrame.identity = cf(0, 0, 0, IDR)
CFrame.Angles = function(rx, ry, rz)
	assert(type(rx) == "number" and type(ry) == "number" and type(rz) == "number", "CFrame.Angles erwartet Zahlen")
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local Rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local Rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return cf(0, 0, 0, matmul(matmul(Rx, Ry), Rz))
end
CFrame.lookAt = function(at, target)
	assert(isV3(at) and isV3(target), "CFrame.lookAt erwartet Vector3")
	local look = (target - at).Unit
	local right = look:Cross(v3(0, 1, 0)).Unit
	local up = right:Cross(look)
	return cf(at.X, at.Y, at.Z, { right.X, up.X, -look.X, right.Y, up.Y, -look.Y, right.Z, up.Z, -look.Z })
end

-- ------------------------------------------------------------------ Color3, UDim, UDim2, sonstige Datentypen

local Color3 = {}
local C3MT = {}
local function c3(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, C3MT)
end
C3MT.__index = function(c, k)
	if k == "Lerp" then
		return function(a, b, t)
			assert(getmetatable(b) == C3MT, "Color3:Lerp erwartet Color3")
			return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
		end
	end
	error("Color3 hat kein Feld " .. tostring(k), 2)
end
C3MT.__eq = function(a, b)
	return math.abs(a.R - b.R) < 1e-6 and math.abs(a.G - b.G) < 1e-6 and math.abs(a.B - b.B) < 1e-6
end
Color3.new = function(r, g, b)
	return c3(r or 0, g or 0, b or 0)
end
Color3.fromRGB = function(r, g, b)
	return c3(r / 255, g / 255, b / 255)
end
Color3.fromHex = function(h)
	assert(type(h) == "string", "Color3.fromHex erwartet Text")
	local s = string.gsub(h, "^#", "")
	assert(#s == 6 and string.match(s, "^%x+$"), "ungültige Hex-Farbe: " .. h)
	return c3(tonumber(string.sub(s, 1, 2), 16) / 255, tonumber(string.sub(s, 3, 4), 16) / 255, tonumber(string.sub(s, 5, 6), 16) / 255)
end

local UDim = {}
UDim.new = function(s, o)
	return { Scale = s or 0, Offset = o or 0 }
end
local UDim2 = {}
local U2MT = {}
U2MT.__index = function(_, k)
	error("UDim2 hat kein Feld " .. tostring(k), 2)
end
local function u2(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }, U2MT)
end
UDim2.new = function(xs, xo, ys, yo)
	return u2(xs or 0, xo or 0, ys or 0, yo or 0)
end
UDim2.fromOffset = function(x, y)
	assert(type(x) == "number" and type(y) == "number", "UDim2.fromOffset erwartet Zahlen")
	return u2(0, x, 0, y)
end
UDim2.fromScale = function(x, y)
	assert(type(x) == "number" and type(y) == "number", "UDim2.fromScale erwartet Zahlen")
	return u2(x, 0, y, 0)
end

local TweenInfo = {
	new = function(...)
		return { args = { ... } }
	end,
}

local RaycastParams = {
	new = function()
		return { FilterType = nil, FilterDescendantsInstances = {} }
	end,
}

local Random = {}
Random.new = function(seed)
	local s = seed or 12345
	local r = {}
	local function nxt()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
	function r:NextNumber(a, b)
		local v = nxt()
		if a then
			return a + (b - a) * v
		end
		return v
	end
	function r:NextInteger(a, b)
		return a + math.floor(nxt() * (b - a + 1))
	end
	return r
end

-- ------------------------------------------------------------------ Enum (nur bekannte Werte)

local ENUMS = {
	Material = { "SmoothPlastic", "Neon", "Metal", "Ice", "Foil", "Fabric", "Glass", "ForceField", "Grass", "Ground", "Slate", "Brick", "WoodPlanks", "Wood", "Marble", "Cobblestone", "Water" },
	PartType = { "Ball", "Block", "Cylinder" },
	SurfaceType = { "Smooth" },
	MeshType = { "Head", "Sphere" },
	NormalId = { "Front" },
	Font = { "FredokaOne", "GothamMedium", "GothamBold" },
	HighlightDepthMode = { "AlwaysOnTop", "Occluded" },
	RaycastFilterType = { "Include", "Exclude" },
	CoreGuiType = { "Backpack", "Health", "EmotesMenu", "PlayerList", "Chat" },
	RenderPriority = { "Camera" },
	UserInputState = { "Begin", "Change", "End" },
	CameraType = { "Scriptable" },
	KeyCode = { "One", "Two", "Three", "Tab", "N", "Q", "E", "L", "F", "T", "Return", "P", "H", "X", "W", "A", "S", "D", "Up", "Down", "Left", "Right", "LeftShift" },
	UserInputType = { "MouseButton1", "MouseButton2", "MouseButton3", "Touch", "Keyboard", "MouseMovement", "MouseWheel" },
	AutomaticSize = { "X", "Y", "XY", "None" },
	TextXAlignment = { "Left", "Center", "Right" },
	TextYAlignment = { "Top", "Center", "Bottom" },
	FillDirection = { "Horizontal", "Vertical" },
	HorizontalAlignment = { "Left", "Center", "Right" },
	VerticalAlignment = { "Top", "Center", "Bottom" },
	SortOrder = { "LayoutOrder" },
	ZIndexBehavior = { "Sibling" },
	ApplyStrokeMode = { "Border", "Contextual" },
	EasingStyle = { "Back", "Quad" },
	EasingDirection = { "Out", "In" },
}
local Enum = {}
for typeName, items in pairs(ENUMS) do
	local t = {}
	for i, name in ipairs(items) do
		t[name] = { EnumType = typeName, Name = name, Value = if typeName == "RenderPriority" then 200 else i }
	end
	Enum[typeName] = setmetatable(t, {
		__index = function(_, k)
			error("Enum." .. typeName .. "." .. tostring(k) .. " gibt es nicht (oder fehlt im Mock)", 2)
		end,
	})
end
setmetatable(Enum, {
	__index = function(_, k)
		error("Enum." .. tostring(k) .. " gibt es nicht (oder fehlt im Mock)", 2)
	end,
})

-- ------------------------------------------------------------------ Scheduler & Signale

local scheduled = {} -- {co, at, args}

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		report("error", tostring(err) .. "\n" .. debug.traceback(co))
	end
end

local Signal = {}
Signal.__index = Signal
local function newSignal(name)
	return setmetatable({ name = name, conns = {}, waiters = {} }, Signal)
end
function Signal:Connect(fn)
	assert(type(fn) == "function", "Connect erwartet Funktion")
	local c = { fn = fn, connected = true }
	table.insert(self.conns, c)
	function c:Disconnect()
		c.connected = false
	end
	return c
end
function Signal:Wait()
	local co = coroutine.running()
	table.insert(self.waiters, co)
	return coroutine.yield()
end
function Signal:Fire(...)
	for _, c in ipairs(table.clone(self.conns)) do
		if c.connected then
			-- Verbindungen laufen wie in Roblox in eigenen Threads
			local co = coroutine.create(c.fn)
			resume(co, ...)
		end
	end
	local waiters = self.waiters
	self.waiters = {}
	for _, co in ipairs(waiters) do
		resume(co, ...)
	end
end

local task = {}
function task.spawn(f, ...)
	local co = if type(f) == "thread" then f else coroutine.create(f)
	resume(co, ...)
	return co
end
function task.delay(t, f, ...)
	local co = coroutine.create(f)
	table.insert(scheduled, { co = co, at = Mock.now + (t or 0), args = table.pack(...) })
	return co
end
function task.wait(t)
	local co = coroutine.running()
	table.insert(scheduled, { co = co, at = Mock.now + (t or 0.03), args = table.pack() })
	coroutine.yield()
	return t
end
function task.defer(f, ...)
	return task.delay(0, f, ...)
end

-- ------------------------------------------------------------------ Instanzen

local PROPS = {}
for _, p in ipairs({
	"Name", "Anchored", "CanCollide", "CanQuery", "CanTouch", "CastShadow", "Shape", "Size", "CFrame", "Color", "Material",
	"TopSurface", "BottomSurface", "Transparency", "MeshType", "Scale", "Texture", "Face", "Enabled", "FillColor", "OutlineColor",
	"FillTransparency", "OutlineTransparency", "DepthMode", "Adornee", "StudsOffsetWorldSpace", "AlwaysOnTop", "LightInfluence",
	"MaxDistance", "Font", "Text", "TextSize", "TextColor3", "BackgroundColor3", "BackgroundTransparency", "Position", "AnchorPoint",
	"AutomaticSize", "Visible", "LayoutOrder", "TextXAlignment", "TextYAlignment", "TextWrapped", "RichText", "TextTransparency",
	"BorderSizePixel", "AutoButtonColor", "ZIndex", "CornerRadius", "Thickness", "ApplyStrokeMode", "PaddingTop", "PaddingRight",
	"PaddingBottom", "PaddingLeft", "FillDirection", "Padding", "SortOrder", "HorizontalAlignment", "VerticalAlignment", "CellSize",
	"CellPadding", "ResetOnSpawn", "IgnoreGuiInset", "ZIndexBehavior", "DisplayOrder", "Ambient", "LightColor", "LightDirection",
	"FieldOfView", "CurrentCamera", "CameraType", "SoundId", "PlaybackSpeed", "Volume", "Range", "Brightness", "Heat", "SecondaryColor",
	"Opacity", "RiseVelocity", "SparkleColor", "ClockTime", "OutdoorAmbient", "GlobalShadows", "EnvironmentDiffuseScale",
	"EnvironmentSpecularScale", "Density", "Offset", "Decay", "Glare", "Haze", "Saturation", "Contrast", "WaterColor",
	"WaterTransparency", "WaterWaveSize", "WaterWaveSpeed", "WaterReflectance", "Cover", "CharacterAutoLoads", "OnServerInvoke",
	"WorldPivot", "LocalPlayer", "UserId", "ViewportSize",
}) do
	PROPS[p] = true
end

local IS_A = {
	Part = { "BasePart", "PVInstance" },
	Model = { "PVInstance" },
	Frame = { "GuiObject" },
	TextLabel = { "GuiObject" },
	TextButton = { "GuiObject", "GuiButton" },
	ViewportFrame = { "GuiObject" },
	ScreenGui = { "LayerCollector" },
	BillboardGui = { "LayerCollector" },
	Script = { "BaseScript", "LuaSourceContainer" },
	LocalScript = { "BaseScript", "Script", "LuaSourceContainer" },
	ModuleScript = { "LuaSourceContainer" },
}

local EVENTS = { Activated = true, MouseButton1Down = true, MouseButton1Up = true, MouseLeave = true, PlayerRemoving = true }

local DEFAULTS = {
	Transparency = 0,
	BackgroundTransparency = 0,
	Visible = true,
	Enabled = true,
	Text = "",
	TextTransparency = 0,
}

local InstanceMT = {}
local METHODS = {}

local function newInstance(class)
	local self = setmetatable({ __class = class, __props = { Name = class }, __children = {}, __attrs = {}, __signals = {} }, InstanceMT)
	if class == "Part" then
		self.__props.CFrame = CFrame.new()
		self.__props.Size = Vector3.new(4, 1, 2)
		self.__props.Color = Color3.new(0.6, 0.6, 0.6)
	elseif class == "Frame" or class == "TextLabel" or class == "TextButton" or class == "ViewportFrame" then
		self.__props.AbsoluteSize = Vector2.new(220, 90)
		self.__props.Size = UDim2.new()
	end
	return self
end

InstanceMT.__index = function(self, k)
	if k == "ClassName" then
		return rawget(self, "__class")
	elseif k == "Parent" then
		return rawget(self, "__parent")
	end
	local m = METHODS[k]
	if m then
		return m
	end
	if EVENTS[k] then
		local sigs = rawget(self, "__signals")
		sigs[k] = sigs[k] or newSignal(k)
		return sigs[k]
	end
	local v = rawget(self, "__props")[k]
	if v ~= nil then
		return v
	end
	for _, c in ipairs(rawget(self, "__children")) do
		if c.Name == k then
			return c
		end
	end
	if DEFAULTS[k] ~= nil then
		return DEFAULTS[k]
	end
	error("Mock: " .. rawget(self, "__class") .. "." .. tostring(k) .. " ist unbekannt", 2)
end

InstanceMT.__newindex = function(self, k, v)
	if k == "Parent" then
		local old = rawget(self, "__parent")
		if old then
			local list = rawget(old, "__children")
			local i = table.find(list, self)
			if i then
				table.remove(list, i)
			end
		end
		rawset(self, "__parent", v)
		if v then
			table.insert(rawget(v, "__children"), self)
		end
		return
	end
	if not PROPS[k] then
		error("Mock: Eigenschaft " .. tostring(k) .. " an " .. rawget(self, "__class") .. " ist unbekannt", 2)
	end
	if k == "Size" and rawget(self, "__class") == "Part" then
		assert(isV3(v), "Part.Size muss Vector3 sein")
	end
	if k == "CFrame" then
		assert(getmetatable(v) == CFMT, "CFrame muss CFrame sein")
	end
	rawget(self, "__props")[k] = v
end

InstanceMT.__tostring = function(self)
	return rawget(self, "__class") .. "(" .. tostring(rawget(self, "__props").Name) .. ")"
end

function METHODS.Destroy(self)
	self.Parent = nil
	rawset(self, "__destroyed", true)
	for _, c in ipairs(table.clone(rawget(self, "__children"))) do
		c:Destroy()
	end
end
function METHODS.GetChildren(self)
	return table.clone(rawget(self, "__children"))
end
function METHODS.GetDescendants(self)
	local out = {}
	local function walk(i)
		for _, c in ipairs(rawget(i, "__children")) do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function METHODS.FindFirstChild(self, name)
	for _, c in ipairs(rawget(self, "__children")) do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function METHODS.FindFirstChildOfClass(self, class)
	for _, c in ipairs(rawget(self, "__children")) do
		if rawget(c, "__class") == class then
			return c
		end
	end
	return nil
end
function METHODS.WaitForChild(self, name, _timeout)
	return METHODS.FindFirstChild(self, name)
end
function METHODS.IsA(self, class)
	local c = rawget(self, "__class")
	if c == class or class == "Instance" then
		return true
	end
	for _, base in ipairs(IS_A[c] or {}) do
		if base == class then
			return true
		end
	end
	return false
end
function METHODS.IsDescendantOf(self, other)
	local p = rawget(self, "__parent")
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "__parent")
	end
	return false
end
function METHODS.SetAttribute(self, k, v)
	rawget(self, "__attrs")[k] = v
end
function METHODS.GetAttribute(self, k)
	return rawget(self, "__attrs")[k]
end
function METHODS.GetPropertyChangedSignal(self, prop)
	local sigs = rawget(self, "__signals")
	local k = "changed:" .. prop
	sigs[k] = sigs[k] or newSignal(k)
	return sigs[k]
end
function METHODS.PivotTo(self, c)
	assert(rawget(self, "__class") == "Model", "PivotTo nur für Model im Test")
	assert(getmetatable(c) == CFMT, "PivotTo erwartet CFrame")
	rawget(self, "__props").__pivot = c
end
function METHODS.ScaleTo(self, s)
	assert(type(s) == "number" and s > 0, "ScaleTo erwartet positive Zahl")
end
function METHODS.Play(_self) end
function METHODS.Stop(_self) end

-- ------------------------------------------------------------------ Welt & Dienste

local Instance = {
	new = function(class, parent)
		assert(parent == nil, "Instance.new mit Parent-Argument vermeiden")
		local known = {
			"Part", "Model", "Folder", "SpecialMesh", "Decal", "Highlight", "BillboardGui", "TextLabel", "TextButton", "Frame",
			"UIListLayout", "UIPadding", "UICorner", "UIStroke", "UIScale", "UIGridLayout", "ScreenGui", "ViewportFrame", "Camera",
			"PointLight", "Sound", "Fire", "Smoke", "Sparkles", "Atmosphere", "ColorCorrectionEffect", "Clouds", "RemoteFunction",
		}
		assert(table.find(known, class), "Mock: Instance.new(" .. tostring(class) .. ") nicht vorgesehen")
		return newInstance(class)
	end,
}

local game = newInstance("DataModel")
local workspace = newInstance("Workspace")
workspace.Parent = game
local camera = newInstance("Camera")
rawget(camera, "__props").ViewportSize = Vector2.new(1280, 720)
rawget(camera, "__props").CFrame = CFrame.new()
camera.Parent = workspace
rawget(workspace, "__props").CurrentCamera = camera
local terrain = newInstance("Terrain")
terrain.Parent = workspace
rawget(workspace, "__props").Terrain = terrain
rawset(Mock, "raycasts", 0)

local SERVICES = {}
local function service(name)
	local s = SERVICES[name]
	if not s then
		s = newInstance(name)
		s.Parent = game
		SERVICES[name] = s
	end
	return s
end

function METHODS.GetService(_self, name)
	local allowed = { "Players", "ReplicatedStorage", "RunService", "UserInputService", "StarterGui", "TweenService", "SoundService", "Debris", "Lighting", "DataStoreService" }
	assert(table.find(allowed, name), "Mock: Dienst " .. tostring(name) .. " nicht vorgesehen")
	return service(name)
end
function METHODS.BindToClose(_self, fn)
	Mock.closeFns = Mock.closeFns or {}
	table.insert(Mock.closeFns, fn)
end
function METHODS.FillBlock(_self, c, size, material)
	assert(getmetatable(c) == CFMT and isV3(size) and material.EnumType == "Material", "FillBlock-Argumente")
end
function METHODS.Raycast(_self, origin, dir, params)
	assert(isV3(origin) and isV3(dir) and type(params) == "table", "Raycast-Argumente")
	Mock.raycasts += 1
	local hit = Mock.nextHit
	if hit and not rawget(hit, "__destroyed") then
		return { Instance = hit, Position = hit.CFrame.Position }
	end
	return nil
end
function METHODS.ScreenPointToRay(_self, x, y)
	assert(type(x) == "number" and type(y) == "number", "ScreenPointToRay erwartet Zahlen")
	return { Origin = Vector3.new(0, 50, 50), Direction = Vector3.new(0, -1, -1).Unit }
end

-- Players
local Players = service("Players")
local localPlayer = newInstance("Player")
rawget(localPlayer, "__props").UserId = 4242
rawget(localPlayer, "__props").Name = "Tester"
localPlayer.Parent = Players
rawget(Players, "__props").LocalPlayer = localPlayer
local playerGui = newInstance("PlayerGui")
playerGui.Name = "PlayerGui"
playerGui.Parent = localPlayer
local playerScripts = newInstance("PlayerScripts")
playerScripts.Name = "PlayerScripts"
playerScripts.Parent = localPlayer
function METHODS.GetGuiObjectsAtPosition(_self, _x, _y)
	return Mock.guiAt
end

-- RunService
local RunService = service("RunService")
local renderStepped, heartbeat = newSignal("RenderStepped"), newSignal("Heartbeat")
rawget(RunService, "__signals").RenderStepped = renderStepped
rawget(RunService, "__signals").Heartbeat = heartbeat
EVENTS.RenderStepped = true
EVENTS.Heartbeat = true
local bound = {}
function METHODS.BindToRenderStep(_self, name, prio, fn)
	assert(type(name) == "string" and type(prio) == "number" and type(fn) == "function", "BindToRenderStep-Argumente")
	bound[name] = fn
end

-- UserInputService
local UIS = service("UserInputService")
for _, e in ipairs({ "InputBegan", "InputChanged", "InputEnded", "TouchPinch" }) do
	EVENTS[e] = true
	rawget(UIS, "__signals")[e] = newSignal(e)
end
Mock.keysHeld = {}
function METHODS.IsKeyDown(_self, kc)
	return Mock.keysHeld[kc] == true
end

local StarterGui = service("StarterGui")
function METHODS.SetCoreGuiEnabled(_self, t, on)
	assert(t.EnumType == "CoreGuiType" and type(on) == "boolean", "SetCoreGuiEnabled-Argumente")
end

local TweenService = service("TweenService")
function METHODS.Create(_self, obj, info, props)
	assert(type(info) == "table" and type(props) == "table", "TweenService:Create-Argumente")
	return {
		Play = function()
			for k, v in pairs(props) do
				obj[k] = v
			end
		end,
	}
end

local Debris = service("Debris")
function METHODS.AddItem(_self, inst, t)
	task.delay(t, function()
		inst:Destroy()
	end)
end

service("SoundService")
service("Lighting")

-- DataStore im Speicher
local DSS = service("DataStoreService")
Mock.storeData = {}
local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local o = {}
	for k, x in pairs(v) do
		o[k] = deepCopy(x)
	end
	return o
end
function METHODS.GetDataStore(_self, name)
	assert(type(name) == "string", "GetDataStore-Name")
	return {
		GetAsync = function(_, k)
			return deepCopy(Mock.storeData[k])
		end,
		SetAsync = function(_, k, v)
			Mock.storeData[k] = deepCopy(v)
		end,
	}
end

-- RemoteFunction: Client ruft direkt den Server-Handler auf (gleicher Prozess im Test)
function METHODS.InvokeServer(self, action, data)
	local fn = rawget(self, "__props").OnServerInvoke
	assert(fn, "kein OnServerInvoke gesetzt")
	return deepCopy(fn(localPlayer, action, deepCopy(data)))
end

local loaded = {}
local function require(m)
	assert(type(m) == "table" and rawget(m, "__class") == "ModuleScript", "require erwartet ModuleScript")
	if loaded[m] == nil then
		local loader = rawget(m, "__loader")
		assert(loader, "ModuleScript ohne Quelltext: " .. tostring(m))
		local result = loader(m)
		assert(result ~= nil, "Modul liefert nichts zurück: " .. tostring(m))
		loaded[m] = result
		if Mock.onRequire then
			Mock.onRequire(m, result)
		end
	end
	return loaded[m]
end

local function warn(...)
	local parts = {}
	for _, v in ipairs({ ... }) do
		table.insert(parts, tostring(v))
	end
	report("warn", table.concat(parts, " "))
end

-- ------------------------------------------------------------------ Test-Werkzeuge

function Mock.step(dt)
	Mock.now += dt
	renderStepped:Fire(dt)
	for _, fn in pairs(bound) do
		local ok, err = pcall(fn, dt)
		if not ok then
			report("error", "RenderStep: " .. tostring(err))
		end
	end
	heartbeat:Fire(dt)
	local due = {}
	for i = #scheduled, 1, -1 do
		if scheduled[i].at <= Mock.now then
			table.insert(due, 1, scheduled[i])
			table.remove(scheduled, i)
		end
	end
	for _, s in ipairs(due) do
		resume(s.co, table.unpack(s.args, 1, s.args.n))
	end
end

function Mock.run(seconds, dt)
	local d = dt or (1 / 30)
	local n = math.ceil(seconds / d)
	for _ = 1, n do
		Mock.step(d)
	end
end

function Mock.module(name, loader)
	local m = newInstance("ModuleScript")
	m.Name = name
	rawset(m, "__loader", loader)
	return m
end

function Mock.scriptInstance(class, name)
	local s = newInstance(class)
	s.Name = name
	return s
end

function Mock.input(userInputType, props)
	local i = { UserInputType = Enum.UserInputType[userInputType], Position = Vector3.new(400, 300, 0), KeyCode = nil }
	for k, v in pairs(props or {}) do
		i[k] = v
	end
	return i
end

Mock.UIS = UIS
Mock.Players = Players
Mock.playerGui = playerGui
Mock.workspace = workspace
Mock.ReplicatedStorage = service("ReplicatedStorage")
Mock.newInstance = newInstance
Mock.isDestroyed = function(i)
	return rawget(i, "__destroyed") == true
end
