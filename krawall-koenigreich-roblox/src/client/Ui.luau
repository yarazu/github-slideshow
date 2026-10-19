-- Benutzeroberfläche: HUD im Kampf und Menüs (Titel, Garderobe mit 3D-Vorschau, Regeln, Pause, Ende).
-- Alles per Code gebaut; die Spiellogik hängt sich über die Handler-Funktionen an.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Models = require(script.Parent.Models)

local Ui = {}
Ui.__index = Ui

local function hex(c: string): Color3
	return Color3.fromHex(c)
end

local C = {
	ink = hex("#241a3a"),
	ink2 = hex("#33275a"),
	line = hex("#4b3a78"),
	deep = hex("#120c20"),
	paper = hex("#fff4dc"),
	muted = hex("#b9add6"),
	gold = hex("#ffc63d"),
	goldDeep = hex("#c97f0c"),
	violet = hex("#6d5bd0"),
	violetDeep = hex("#3f2f8f"),
	good = hex("#5fd068"),
	warn = hex("#ffc63d"),
	bad = hex("#ff5a5a"),
	foe = hex("#ff8aa3"),
}
Ui.C = C

local DISPLAY = Enum.Font.FredokaOne
local BODY = Enum.Font.GothamMedium
local BOLD = Enum.Font.GothamBold

local BUTTON_STYLES = {
	gold = { bg = C.gold, fg = hex("#3a2300"), deep = C.goldDeep },
	violet = { bg = C.violet, fg = Color3.new(1, 1, 1), deep = C.violetDeep },
	on = { bg = hex("#fff4dc"), fg = hex("#3a2300"), deep = hex("#c9b98f") },
	off = { bg = hex("#43375e"), fg = hex("#8f84a8"), deep = hex("#261d3b") },
	tool = { bg = C.ink, fg = C.paper, deep = C.deep },
}

local function make(class: string, props, children)
	local inst = Instance.new(class)
	local parent = nil
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(r: number)
	return make("UICorner", { CornerRadius = UDim.new(0, r) })
end

local function roundCorner()
	return make("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

local function stroke(color: Color3, th: number)
	return make("UIStroke", { Color = color, Thickness = th, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function textStroke(color: Color3, th: number)
	return make("UIStroke", { Color = color, Thickness = th, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual })
end

local function padding(t: number, r: number?, b: number?, l: number?)
	return make("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t),
		PaddingLeft = UDim.new(0, l or r or t),
	})
end

local function list(dir: Enum.FillDirection, gap: number, halign: Enum.HorizontalAlignment?, valign: Enum.VerticalAlignment?)
	return make("UIListLayout", {
		FillDirection = dir,
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = halign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = valign or Enum.VerticalAlignment.Top,
	})
end

local function label(props)
	local base = {
		BackgroundTransparency = 1,
		Font = BODY,
		TextColor3 = C.paper,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = true,
	}
	for k, v in pairs(props) do
		base[k] = v
	end
	return make("TextLabel", base)
end

-- auto-hoher Textblock in voller Breite
local function para(parent, text: string, size: number, color: Color3?, font: Enum.Font?, order: number?)
	return label({
		Parent = parent,
		Text = text,
		TextSize = size,
		TextColor3 = color or C.paper,
		Font = font or BODY,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
	})
end

local function panel(props)
	local f = make("Frame", props)
	f.BackgroundColor3 = C.ink
	f.BackgroundTransparency = 0.04
	f.BorderSizePixel = 0
	corner(16).Parent = f
	stroke(C.line, 2).Parent = f
	return f
end

-- Knopf mit "3D"-Schatten. Rückgabe: Steuerobjekt mit set(enabled, style) und setText(text)
local function button(parent, text: string, style: string, size: UDim2, order: number?, onClick: (() -> ())?)
	local holder = make("Frame", { Name = text, Size = size, BackgroundTransparency = 1, LayoutOrder = order or 0, Parent = parent })
	local shadow = make("Frame", { Size = UDim2.new(1, 0, 1, -4), Position = UDim2.fromOffset(0, 4), BorderSizePixel = 0, Parent = holder }, { corner(12) })
	local btn = make("TextButton", {
		Size = UDim2.new(1, 0, 1, -4),
		Font = DISPLAY,
		TextSize = 18,
		Text = text,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Parent = holder,
	}, { corner(12) })
	local state = { style = style, enabled = true, holder = holder, btn = btn }
	local function paint()
		local st = BUTTON_STYLES[if state.enabled then state.style else "off"]
		btn.BackgroundColor3 = st.bg
		btn.TextColor3 = st.fg
		shadow.BackgroundColor3 = st.deep
	end
	function state.set(_, enabled: boolean, styleName: string?)
		if styleName then
			state.style = styleName
		end
		state.enabled = enabled
		paint()
	end
	function state.setText(_, t: string)
		btn.Text = t
	end
	btn.MouseButton1Down:Connect(function()
		if state.enabled then
			btn.Position = UDim2.fromOffset(0, 3)
		end
	end)
	btn.MouseButton1Up:Connect(function()
		btn.Position = UDim2.new()
	end)
	btn.MouseLeave:Connect(function()
		btn.Position = UDim2.new()
	end)
	btn.Activated:Connect(function()
		btn.Position = UDim2.new()
		if state.enabled and onClick then
			onClick()
		end
	end)
	paint()
	return state
end

local function card(parent, width: number, name: string)
	local f = panel({
		Name = name,
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
	})
	padding(24, 28).Parent = f
	list(Enum.FillDirection.Vertical, 12).Parent = f
	return f
end

local function row(parent, height: number, gap: number, order: number?)
	local f = make("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1, LayoutOrder = order or 0, Parent = parent })
	list(Enum.FillDirection.Horizontal, gap).Parent = f
	return f
end

-- ------------------------------------------------------------------ construction

function Ui.new(handlers)
	local self = setmetatable({}, Ui)
	self.h = handlers
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.hud = make("ScreenGui", { Name = "KrawallHUD", ResetOnSpawn = false, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 5, Enabled = false, Parent = pg })
	self.menus = make("ScreenGui", { Name = "KrawallMenus", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 10, Parent = pg })
	self.hudScale = make("UIScale", { Parent = self.hud })
	self.menuScale = make("UIScale", { Parent = self.menus })

	self:buildHud()
	self:buildMenus()
	self:updateScale()
	local cam = workspace.CurrentCamera
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		self:updateScale()
	end)
	return self
end

function Ui:updateScale()
	local vp = workspace.CurrentCamera.ViewportSize
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 740), 0.5, 1.2)
	self.scale = s
	self.hudScale.Scale = s
	self.menuScale.Scale = math.clamp(math.min(vp.X / 900, vp.Y / 760), 0.45, 1.15)
end

-- ------------------------------------------------------------------ HUD

function Ui:buildHud()
	local hud = self.hud
	-- Level-Infos oben links
	local top = panel({ Parent = hud, Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(320, 0), AutomaticSize = Enum.AutomaticSize.Y })
	padding(10, 14, 12, 14).Parent = top
	list(Enum.FillDirection.Vertical, 3).Parent = top
	self.lvlNum = label({ Parent = top, Text = "KAMPF 1", Font = BOLD, TextSize = 12, TextColor3 = C.muted, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 1 })
	self.lvlName = label({ Parent = top, Text = "Pilzwiese", Font = DISPLAY, TextSize = 24, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 2 })
	local rl = row(top, 22, 8, 3)
	self.roundTxt = label({ Parent = rl, Text = "Runde 1", Font = BOLD, TextSize = 16, Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, TextYAlignment = Enum.TextYAlignment.Center })
	self.pill = label({
		Parent = rl,
		Text = "DEIN ZUG",
		Font = BOLD,
		TextSize = 12,
		TextColor3 = hex("#0f2a12"),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.good,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		LayoutOrder = 2,
	})
	padding(0, 9).Parent = self.pill
	roundCorner().Parent = self.pill
	self.goalTxt = para(top, "Ziel: Besiege alle Krawallos", 13, C.muted, BODY, 4)

	-- Werkzeugknöpfe oben rechts
	local tools = make("Frame", { Parent = hud, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(4 * 52 + 3 * 8, 50), BackgroundTransparency = 1 })
	list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right).Parent = tools
	button(tools, "?", "tool", UDim2.fromOffset(52, 50), 1, function()
		self.h.onHelp()
	end)
	self.speedBtn = button(tools, "1×", "tool", UDim2.fromOffset(52, 50), 2, function()
		self.h.onSpeed()
	end)
	self.soundBtn = button(tools, "Ton", "tool", UDim2.fromOffset(52, 50), 3, function()
		self.h.onSound()
	end)
	button(tools, "II", "tool", UDim2.fromOffset(52, 50), 4, function()
		self.h.onPause()
	end)

	-- Heldenkarten unten links
	local cards = make("Frame", { Parent = hud, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -12), Size = UDim2.fromOffset(260, 3 * 78 + 16), BackgroundTransparency = 1 })
	list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom).Parent = cards
	self.cardFrame = cards
	self.heroCards = {}

	-- Aktionsleiste unten rechts
	local ap = panel({ Parent = hud, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -12), Size = UDim2.fromOffset(600, 0), AutomaticSize = Enum.AutomaticSize.Y })
	padding(12, 14).Parent = ap
	list(Enum.FillDirection.Vertical, 10).Parent = ap
	self.info = para(ap, "", 14, C.paper, BODY, 1)
	local br = row(ap, 50, 8, 2)
	self.btnMove = button(br, "Laufen [L]", "gold", UDim2.fromOffset(122, 50), 1, function()
		self.h.onMode("move")
	end)
	self.btnAttack = button(br, "Angriff [F]", "gold", UDim2.fromOffset(128, 50), 2, function()
		self.h.onMode("attack")
	end)
	self.btnTech = button(br, "Technik [T]", "gold", UDim2.fromOffset(150, 50), 3, function()
		self.h.onTech()
	end)
	self.btnEnd = button(br, "Zug beenden", "violet", UDim2.fromOffset(150, 50), 4, function()
		self.h.onEndTurn()
	end)

	-- Tooltip
	self.tip = make("Frame", { Parent = hud, BackgroundColor3 = C.deep, BackgroundTransparency = 0.04, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), Visible = false, ZIndex = 20 }, { corner(12), stroke(C.line, 2), padding(8, 12) })
	self.tipLabel = label({ Parent = self.tip, Text = "", TextSize = 14, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), ZIndex = 21, TextWrapped = false })

	-- Banner
	self.banner = make("Frame", { Parent = hud, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.33), Size = UDim2.fromOffset(900, 120), BackgroundTransparency = 1, Visible = false })
	self.bannerScale = make("UIScale", { Parent = self.banner })
	self.bannerTitle = label({ Parent = self.banner, Text = "", Font = DISPLAY, TextSize = 68, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 78), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false })
	self.bannerTitleStroke = textStroke(hex("#5a2a06"), 4)
	self.bannerTitleStroke.Parent = self.bannerTitle
	self.bannerSub = label({ Parent = self.banner, Text = "", Font = BOLD, TextSize = 20, Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 0, 26), TextXAlignment = Enum.TextXAlignment.Center })
	textStroke(C.deep, 2).Parent = self.bannerSub
end

function Ui:buildHeroCards(heroList)
	for _, c in pairs(self.heroCards) do
		c.frame:Destroy()
	end
	self.heroCards = {}
	for i, u in ipairs(heroList) do
		local color = hex(u.def.color)
		local f = make("TextButton", { Parent = self.cardFrame, Size = UDim2.fromOffset(240, 78), BackgroundColor3 = C.ink, BackgroundTransparency = 0.04, AutoButtonColor = false, Text = "", LayoutOrder = i })
		corner(14).Parent = f
		local st = stroke(C.line, 2)
		st.Parent = f
		local face = make("Frame", { Parent = f, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(40, 40), BackgroundColor3 = color }, { roundCorner() })
		label({ Parent = face, Text = string.sub(u.name, 1, 1), Font = DISPLAY, TextSize = 22, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center })
		label({ Parent = f, Text = u.name, Font = DISPLAY, TextSize = 19, Position = UDim2.fromOffset(60, 8), Size = UDim2.fromOffset(100, 22) })
		local hp = label({ Parent = f, Text = "", Font = BOLD, TextSize = 13, TextColor3 = C.muted, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 11), Size = UDim2.fromOffset(80, 16), TextXAlignment = Enum.TextXAlignment.Right })
		local bar = make("Frame", { Parent = f, Position = UDim2.fromOffset(60, 33), Size = UDim2.new(1, -72, 0, 9), BackgroundColor3 = C.deep, BorderSizePixel = 0 }, { corner(5) })
		local fill = make("Frame", { Parent = bar, Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.good, BorderSizePixel = 0 }, { corner(5) })
		local pips = make("Frame", { Parent = f, Position = UDim2.fromOffset(10, 52), Size = UDim2.new(1, -20, 0, 18), BackgroundTransparency = 1 })
		list(Enum.FillDirection.Horizontal, 5).Parent = pips
		local function pip(text: string, order: number)
			local p = label({ Parent = pips, Text = text, Font = BOLD, TextSize = 11, BackgroundTransparency = 0, BackgroundColor3 = C.ink2, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, LayoutOrder = order, TextWrapped = false })
			padding(0, 7).Parent = p
			corner(6).Parent = p
			return p
		end
		local entry = {
			frame = f,
			stroke = st,
			hp = hp,
			fill = fill,
			color = color,
			pm = pip("LAUF", 1),
			pa = pip("SCHUSS", 2),
			pt = pip("TECHNIK", 3),
		}
		f.Activated:Connect(function()
			self.h.onSelectHero(i)
		end)
		self.heroCards[i] = entry
	end
end

-- data: Liste {hp, maxHp, alive, moved, attacked, techReady, cd, selected}
function Ui:setHeroes(data)
	for i, d in ipairs(data) do
		local c = self.heroCards[i]
		if c then
			c.hp.Text = d.hp .. "/" .. d.maxHp
			local r = d.hp / d.maxHp
			c.fill.Size = UDim2.fromScale(r, 1)
			c.fill.BackgroundColor3 = if r > 0.5 then C.good elseif r > 0.25 then C.warn else C.bad
			c.stroke.Color = if d.selected then c.color else C.line
			c.stroke.Thickness = if d.selected then 3 else 2
			c.frame.BackgroundColor3 = if d.alive then C.ink else hex("#2a2534")
			local function dim(p, used: boolean)
				p.TextTransparency = if used then 0.65 else 0
				p.BackgroundTransparency = if used then 0.6 else 0
			end
			dim(c.pm, d.moved or not d.alive)
			dim(c.pa, d.attacked or not d.alive)
			dim(c.pt, not d.techReady or not d.alive)
			c.pt.Text = if d.cd > 0 then "TECHNIK " .. d.cd else "TECHNIK"
		end
	end
end

function Ui:setLevel(li: number, L)
	self.lvlNum.Text = "KAMPF " .. li
	self.lvlName.Text = L.name
	self.goalTxt.Text = "Ziel: " .. L.goal
end

function Ui:setRound(round: number, phase: string)
	self.roundTxt.Text = "Runde " .. round
	if phase == "enemy" then
		self.pill.Text = "GEGNERZUG"
		self.pill.BackgroundColor3 = C.foe
		self.pill.TextColor3 = hex("#2a0710")
	else
		self.pill.Text = "DEIN ZUG"
		self.pill.BackgroundColor3 = C.good
		self.pill.TextColor3 = hex("#0f2a12")
	end
end

-- s: {move, attack, tech, endTurn = enabled-Flags; mode; techLabel; pulse}
function Ui:setActions(s)
	self.btnMove:set(s.move, if s.mode == "move" then "on" else "gold")
	self.btnAttack:set(s.attack, if s.mode == "attack" then "on" else "gold")
	self.btnTech:set(s.tech, if s.mode == "tech" then "on" else "gold")
	self.btnTech:setText(s.techLabel)
	self.btnEnd:set(s.endTurn, if s.pulse then "gold" else "violet")
	self.btnEnd:setText(if s.pulse then "Zug beenden!" else "Zug beenden")
end

function Ui:setInfo(text: string)
	self.info.Text = text
end

function Ui:showTip(text: string, x: number, y: number)
	self.tipLabel.Text = text
	self.tip.Visible = true
	local s = self.scale or 1
	local vp = workspace.CurrentCamera.ViewportSize
	local w, h = self.tip.AbsoluteSize.X, self.tip.AbsoluteSize.Y
	local px, py = x + 18, y + 18
	if px + w > vp.X - 8 then
		px = x - w - 14
	end
	if py + h > vp.Y - 70 then
		py = y - h - 14
	end
	self.tip.Position = UDim2.fromOffset(math.max(8, px) / s, math.max(8, py) / s)
end

function Ui:hideTip()
	self.tip.Visible = false
end

-- Großes Banner in der Bildschirmmitte (nicht blockierend)
function Ui:showBanner(title: string, sub: string?, foe: boolean?)
	self.bannerTitle.Text = title
	self.bannerSub.Text = sub or ""
	self.bannerTitle.TextColor3 = if foe then C.foe else C.gold
	self.bannerTitleStroke.Color = if foe then hex("#4a0a1a") else hex("#5a2a06")
	self.banner.Visible = true
	self.bannerScale.Scale = 0.6
	self.bannerTitle.TextTransparency = 0
	self.bannerSub.TextTransparency = 0
	self.bannerToken = (self.bannerToken or 0) + 1
	local token = self.bannerToken
	TweenService:Create(self.bannerScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(1.15, function()
		if token ~= self.bannerToken then
			return
		end
		TweenService:Create(self.bannerTitle, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		TweenService:Create(self.bannerSub, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		task.delay(0.32, function()
			if token == self.bannerToken then
				self.banner.Visible = false
			end
		end)
	end)
end

function Ui:setHudVisible(v: boolean)
	self.hud.Enabled = v
end

-- ------------------------------------------------------------------ menus

function Ui:buildMenus()
	local m = self.menus
	self.backdrop = make("Frame", { Parent = m, Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.deep, BackgroundTransparency = 0.4, BorderSizePixel = 0 })
	self.screens = {}
	self:buildTitle()
	self:buildSkins()
	self:buildHelp()
	self:buildPause()
	self:buildEnd()
end

function Ui:show(name: string?)
	self.menus.Enabled = name ~= nil
	for n, f in pairs(self.screens) do
		f.Visible = n == name
	end
	self.current = name
	if name ~= "skins" and self.previewConn then
		self.previewConn:Disconnect()
		self.previewConn = nil
	end
end

function Ui:buildTitle()
	local c = card(self.menus, 800, "title")
	self.screens.title = c
	para(c, "RUNDENTAKTIK IN 3D · 3 GEFECHTE · 12 HELDEN-SKINS", 13, C.muted, BOLD, 1)
	local logo1 = label({ Parent = c, Text = "KRAWALL", Font = DISPLAY, TextSize = 78, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 80), LayoutOrder = 2, TextWrapped = false })
	textStroke(hex("#5a2a06"), 4).Parent = logo1
	local logo2 = label({ Parent = c, Text = "KÖNIGREICH", Font = DISPLAY, TextSize = 56, TextColor3 = C.paper, Size = UDim2.new(1, 0, 0, 60), LayoutOrder = 3, TextWrapped = false })
	textStroke(C.violetDeep, 4).Parent = logo2
	para(c, "Die Krawallos haben das Königreich gestürmt. Führe Leo, Bruna und Pip durch drei Gefechte: in Deckung gehen, per Teamsprung übers Feld fliegen, Gegner im Sprint umrennen. Jeder Sieg schaltet neue Skins frei.", 16, hex("#e9e0fa"), BODY, 4)
	self.levelRow = row(c, 150, 10, 5)
	local br = row(c, 58, 10, 6)
	button(br, "Spielen", "gold", UDim2.fromOffset(170, 58), 1, function()
		self.h.onPlay()
	end)
	button(br, "Helden-Skins", "violet", UDim2.fromOffset(190, 58), 2, function()
		self.h.onOpenSkins()
	end)
	button(br, "So spielst du", "violet", UDim2.fromOffset(180, 58), 3, function()
		self.h.onHelp()
	end)
end

-- levels: Config.LEVELS, won: gewonnene Kämpfe, best: Bestwerte, pick: gewählter Kampf
function Ui:setLevels(levels, won: number, best, pick: number, enemyCounts)
	for _, ch in ipairs(self.levelRow:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	for i, L in ipairs(levels) do
		local locked = i > won + 1
		local b = make("TextButton", {
			Parent = self.levelRow,
			Size = UDim2.new(1 / 3, -7, 1, 0),
			BackgroundColor3 = if i == pick then hex("#3d2f68") else C.ink2,
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = i,
		})
		corner(14).Parent = b
		stroke(if i == pick then C.gold else C.line, 2).Parent = b
		padding(10, 12).Parent = b
		list(Enum.FillDirection.Vertical, 3).Parent = b
		para(b, "KAMPF " .. i .. (if locked then " · GESPERRT" else ""), 11, C.muted, BOLD, 1)
		para(b, L.name, 19, C.paper, DISPLAY, 2)
		para(b, L.blurb, 12, hex("#d9cff0"), BODY, 3)
		local meta = enemyCounts[i] .. " Gegner · Ziel " .. L.par .. " Runden"
		local bs = best[tostring(i)]
		if bs then
			meta ..= "\n<font color=\"#ffc63d\">Bestwert: " .. ({ "Geschafft", "Stark", "Meisterhaft" })[bs.score] .. " in " .. bs.turn .. " Runden</font>"
		end
		para(b, meta, 12, C.muted, BOLD, 4)
		if locked then
			for _, d in ipairs(b:GetDescendants()) do
				if d:IsA("TextLabel") then
					d.TextTransparency = 0.5
				end
			end
		end
		b.Activated:Connect(function()
			if not locked then
				self.h.onPickLevel(i)
			end
		end)
	end
end

-- ------------------------------------------------------------------ Garderobe

function Ui:buildSkins()
	local c = card(self.menus, 860, "skins")
	self.screens.skins = c
	para(c, "HELDEN-SKINS", 13, C.muted, BOLD, 1)
	local t = label({ Parent = c, Text = "Garderobe", Font = DISPLAY, TextSize = 46, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 50), LayoutOrder = 2, TextWrapped = false })
	textStroke(hex("#5a2a06"), 3).Parent = t
	para(c, "Jeder Held hat vier Outfits. Neue Skins schaltest du frei, indem du Kämpfe gewinnst. Der ausgerüstete Skin erscheint im Kampf.", 15, hex("#e9e0fa"), BODY, 3)
	local tabs = row(c, 48, 8, 4)
	self.skinTabs = {}
	for i, heroKind in ipairs({ "leo", "bruna", "pip" }) do
		self.skinTabs[heroKind] = button(tabs, ({ "Leo", "Bruna", "Pip" })[i], "violet", UDim2.fromOffset(130, 48), i, function()
			self.skinHero = heroKind
			self.skinFocus = nil
			self:refreshSkins()
		end)
	end
	local body = row(c, 340, 16, 5)
	local vpf = make("ViewportFrame", {
		Parent = body,
		Size = UDim2.fromOffset(300, 340),
		BackgroundColor3 = C.ink2,
		Ambient = Color3.fromRGB(165, 160, 190),
		LightColor = Color3.fromRGB(255, 244, 225),
		LightDirection = Vector3.new(-0.6, -1, 0.5),
		LayoutOrder = 1,
	}, { corner(16) })
	local vcam = Instance.new("Camera")
	vcam.FieldOfView = 38
	vcam.CFrame = CFrame.lookAt(Vector3.new(0, 3.4, -11), Vector3.new(0, 2.5, 0))
	vcam.Parent = vpf
	vpf.CurrentCamera = vcam
	self.viewport = vpf
	self.skinNameLabel = label({ Parent = vpf, Text = "", Font = DISPLAY, TextSize = 22, Position = UDim2.new(0, 0, 1, -40), Size = UDim2.new(1, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Center })
	textStroke(C.deep, 2).Parent = self.skinNameLabel
	local listFrame = make("Frame", { Parent = body, Size = UDim2.new(1, -316, 1, 0), BackgroundTransparency = 1, LayoutOrder = 2 })
	list(Enum.FillDirection.Vertical, 8).Parent = listFrame
	self.skinList = listFrame
	self.skinDesc = para(c, "", 15, C.paper, BODY, 6)
	local br = row(c, 56, 10, 7)
	self.equipBtn = button(br, "Ausrüsten", "gold", UDim2.fromOffset(180, 56), 1, function()
		if self.skinFocus then
			self.h.onEquip(self.skinHero, self.skinFocus)
		end
	end)
	button(br, "Zurück", "violet", UDim2.fromOffset(140, 56), 2, function()
		self.h.onCloseSkins()
	end)
	self.skinHero = "leo"
end

-- Garderobe öffnen; skins = Skins-Modul, progress = {won, skins = {held = id}}
function Ui:openSkins(skinsModule, progress)
	self.skinsModule = skinsModule
	self.progress = progress
	self.skinFocus = nil
	self:show("skins")
	self:refreshSkins()
	if self.previewConn then
		self.previewConn:Disconnect()
	end
	local t0 = os.clock()
	self.previewConn = RunService.RenderStepped:Connect(function()
		if self.previewModel then
			self.previewModel:PivotTo(CFrame.Angles(0, math.sin((os.clock() - t0) * 0.9) * 0.9, 0))
		end
	end)
end

function Ui:refreshSkins()
	local Skins = self.skinsModule
	local progress = self.progress
	if not Skins or not progress then
		return
	end
	local heroKind = self.skinHero
	local equipped = progress.skins[heroKind]
	self.skinFocus = self.skinFocus or equipped
	for kind, b in pairs(self.skinTabs) do
		b:set(true, if kind == heroKind then "gold" else "violet")
	end
	for _, ch in ipairs(self.skinList:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	local focusSkin = Skins.get(heroKind, self.skinFocus)
	for i, sk in ipairs(Skins.HEROES[heroKind]) do
		local unlocked = progress.won >= sk.unlock
		local focused = sk.id == focusSkin.id
		local b = make("TextButton", { Parent = self.skinList, Size = UDim2.new(1, 0, 0, 78), BackgroundColor3 = if focused then hex("#3d2f68") else C.ink2, AutoButtonColor = false, Text = "", LayoutOrder = i })
		corner(14).Parent = b
		stroke(if focused then C.gold else C.line, 2).Parent = b
		local sw = make("Frame", { Parent = b, Position = UDim2.fromOffset(12, 14), Size = UDim2.fromOffset(50, 50), BackgroundColor3 = hex(sk.shirt) }, { corner(10), stroke(C.deep, 2) })
		make("Frame", { Parent = sw, Position = UDim2.fromScale(0, 0.62), Size = UDim2.fromScale(1, 0.38), BackgroundColor3 = hex(sk.pants), BorderSizePixel = 0 }, { corner(8) })
		make("Frame", { Parent = sw, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.25), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = hex(sk.hatColor) }, { roundCorner(), stroke(C.deep, 1.5) })
		label({ Parent = b, Text = sk.name, Font = DISPLAY, TextSize = 20, Position = UDim2.fromOffset(76, 12), Size = UDim2.new(1, -90, 0, 24), TextColor3 = if unlocked then C.paper else C.muted })
		local status
		if sk.id == equipped then
			status = "<font color=\"#5fd068\">AUSGERÜSTET</font>"
		elseif unlocked then
			status = "FREIGESCHALTET"
		else
			status = "<font color=\"#ff8aa3\">GESPERRT</font> · Sieg in Kampf " .. sk.unlock
		end
		label({ Parent = b, Text = status, Font = BOLD, TextSize = 12, Position = UDim2.fromOffset(76, 42), Size = UDim2.new(1, -90, 0, 18), TextColor3 = C.muted })
		b.Activated:Connect(function()
			self.skinFocus = sk.id
			self:refreshSkins()
		end)
	end
	local unlocked = progress.won >= focusSkin.unlock
	self.skinDesc.Text = "<b>" .. focusSkin.name .. ":</b> " .. focusSkin.desc .. (if unlocked then "" else "  <font color=\"#ff8aa3\">Gewinne Kampf " .. focusSkin.unlock .. ", um ihn freizuschalten.</font>")
	self.skinNameLabel.Text = focusSkin.name
	self.equipBtn:set(unlocked and focusSkin.id ~= equipped, "gold")
	self.equipBtn:setText(if focusSkin.id == equipped then "Ausgerüstet" elseif unlocked then "Ausrüsten" else "Gesperrt")
	-- 3D-Vorschau neu bauen
	if self.previewModel then
		self.previewModel:Destroy()
	end
	local model = Models.hero(heroKind, focusSkin)
	model.Parent = self.viewport
	model:PivotTo(CFrame.new())
	self.previewModel = model
	if not unlocked then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Color = d.Color:Lerp(Color3.fromRGB(40, 32, 60), 0.75)
			end
		end
	end
end

-- ------------------------------------------------------------------ Regeln

function Ui:buildHelp()
	local c = card(self.menus, 880, "help")
	self.screens.help = c
	para(c, "SPIELREGELN", 13, C.muted, BOLD, 1)
	local t = label({ Parent = c, Text = "So spielst du", Font = DISPLAY, TextSize = 42, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 2, TextWrapped = false })
	textStroke(hex("#5a2a06"), 3).Parent = t
	local grid = make("Frame", { Parent = c, Size = UDim2.new(1, 0, 0, 4 * 86 + 3 * 10), BackgroundTransparency = 1, LayoutOrder = 3 })
	make("UIGridLayout", { Parent = grid, CellSize = UDim2.new(0.5, -8, 0, 86), CellPadding = UDim2.fromOffset(16, 10), SortOrder = Enum.SortOrder.LayoutOrder })
	local rules = {
		{ "#3fa8ff", "Laufen", "Blaue Felder zeigen, wie weit dein Held laufen kann. Erst laufen, dann angreifen: nach dem Schuss ist die Bewegung vorbei." },
		{ "#ffc63d", "Teamsprung", "Goldene Felder erreichst du über einen Verbündeten: er wirft dich bis zu 3 Felder weit, auch über Mauern." },
		{ "#ff8a2a", "Sprintangriff", "Oranger Umriss: Renne einmal pro Zug in einen Gegner. Danach darfst du weiterlaufen." },
		{ "#ff5fd2", "Sprungangriff", "Pinker Umriss: Springe per Teamsprung auf einen Gegner. 30 Schaden, danach endet die Bewegung." },
		{ "#5fd068", "Trefferchance", "100 % ohne Deckung, 50 % hinter Kisten, 0 % hinter Steinmauern. Flankiere von der Seite!" },
		{ "#c98a4b", "Kisten gehen kaputt", "Ein Fehlschuss auf ein Ziel hinter einer Kiste beschädigt sie. Nach zwei Treffern ist sie weg." },
		{ "#ff7a2f", "Super-Effekte", "Brand: 15 Schaden im nächsten Zug. Rückstoß: schiebt weg, Wasser kostet 50 LP. Honig: Gegner klebt fest." },
		{ "#5ee3d2", "Techniken", "Leo: Wachsamkeit (Reaktionsschuss). Bruna: Bollwerk (halber Schaden). Pip: Heilwelle. Danach Abklingzeit." },
	}
	for i, r in ipairs(rules) do
		local cell = make("Frame", { Parent = grid, BackgroundTransparency = 1, LayoutOrder = i })
		make("Frame", { Parent = cell, Size = UDim2.fromOffset(22, 22), Position = UDim2.fromOffset(0, 3), BackgroundColor3 = hex(r[1]) }, { corner(6) })
		label({ Parent = cell, Text = r[2], Font = DISPLAY, TextSize = 17, TextColor3 = C.gold, Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, -34, 0, 22) })
		label({ Parent = cell, Text = r[3], TextSize = 13, TextColor3 = hex("#e3daf5"), Position = UDim2.fromOffset(34, 24), Size = UDim2.new(1, -34, 1, -24) })
	end
	local keys = para(c,
		"<b>Maus:</b> Klick wählt und handelt · Ziehen mit rechter Maustaste dreht die Kamera · Mausrad zoomt · mittlere Maustaste verschiebt\n"
			.. "<b>Tasten:</b> 1–3 Held · Tab nächster Held · L Laufen · F Angriff · T Technik · Enter Zug beenden · X Abbrechen · Q/E drehen · WASD verschieben · P Pause\n"
			.. "<b>Touch:</b> Einmal tippen zeigt die Vorschau, nochmal tippen bestätigt · Wischen dreht · Zwei Finger zoomen",
		13, hex("#e3daf5"), BODY, 4)
	keys.BackgroundTransparency = 0
	keys.BackgroundColor3 = C.ink2
	corner(12).Parent = keys
	padding(10, 14).Parent = keys
	local br = row(c, 56, 10, 5)
	button(br, "Verstanden", "gold", UDim2.fromOffset(190, 56), 1, function()
		self.h.onCloseHelp()
	end)
end

-- ------------------------------------------------------------------ Pause & Ende

function Ui:buildPause()
	local c = card(self.menus, 520, "pause")
	self.screens.pause = c
	para(c, "PAUSE", 13, C.muted, BOLD, 1)
	local t = label({ Parent = c, Text = "Kurze Rast", Font = DISPLAY, TextSize = 42, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 2, TextWrapped = false })
	textStroke(hex("#5a2a06"), 3).Parent = t
	self.pauseInfo = para(c, "", 16, hex("#e9e0fa"), BODY, 3)
	local br = row(c, 56, 10, 4)
	button(br, "Weiter", "gold", UDim2.fromOffset(130, 56), 1, function()
		self.h.onResume()
	end)
	button(br, "Neu starten", "violet", UDim2.fromOffset(160, 56), 2, function()
		self.h.onRestart()
	end)
	button(br, "Hauptmenü", "violet", UDim2.fromOffset(150, 56), 3, function()
		self.h.onToTitle()
	end)
end

function Ui:showPause(text: string)
	self.pauseInfo.Text = text
	self:show("pause")
end

function Ui:buildEnd()
	local c = card(self.menus, 680, "ending")
	self.screens.ending = c
	self.endEyebrow = para(c, "", 13, C.muted, BOLD, 1)
	self.endTitle = label({ Parent = c, Text = "Sieg!", Font = DISPLAY, TextSize = 60, TextColor3 = C.gold, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 2, TextWrapped = false })
	self.endTitleStroke = textStroke(hex("#5a2a06"), 4)
	self.endTitleStroke.Parent = self.endTitle
	self.endRating = para(c, "", 17, C.paper, DISPLAY, 3)
	local stats = make("Frame", { Parent = c, Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, LayoutOrder = 4 })
	list(Enum.FillDirection.Horizontal, 10).Parent = stats
	self.endStats = {}
	for i = 1, 4 do
		local s = make("Frame", { Parent = stats, Size = UDim2.new(0.25, -8, 1, 0), BackgroundColor3 = C.ink2, LayoutOrder = i }, { corner(12), padding(8, 12) })
		local k = label({ Parent = s, Text = "", Font = BOLD, TextSize = 11, TextColor3 = C.muted, Size = UDim2.new(1, 0, 0, 14) })
		local v = label({ Parent = s, Text = "", Font = DISPLAY, TextSize = 28, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 32) })
		self.endStats[i] = { k = k, v = v }
	end
	self.endUnlock = para(c, "", 15, C.paper, BODY, 5)
	self.endUnlock.BackgroundTransparency = 0
	self.endUnlock.BackgroundColor3 = hex("#3d2f68")
	corner(12).Parent = self.endUnlock
	padding(10, 14).Parent = self.endUnlock
	self.endButtons = row(c, 56, 10, 6)
end

-- d: {eyebrow, title, won, rating, stats = {{k, v}...}, unlock = text?, buttons = {{text, style, fn}...}}
function Ui:showEnd(d)
	self.endEyebrow.Text = d.eyebrow
	self.endTitle.Text = d.title
	self.endTitle.TextColor3 = if d.won then C.gold else C.foe
	self.endTitleStroke.Color = if d.won then hex("#5a2a06") else hex("#4a0a1a")
	self.endRating.Text = d.rating
	for i, st in ipairs(d.stats) do
		self.endStats[i].k.Text = st[1]
		self.endStats[i].v.Text = st[2]
	end
	self.endUnlock.Visible = d.unlock ~= nil
	self.endUnlock.Text = d.unlock or ""
	for _, ch in ipairs(self.endButtons:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	for i, b in ipairs(d.buttons) do
		button(self.endButtons, b[1], b[2], UDim2.fromOffset(if b[2] == "gold" then 210 else 170, 56), i, b[3])
	end
	self:show("ending")
end

return Ui
