-- Helden-Skins. Jeder Held hat vier Outfits; "unlock" ist der Kampf, der dafür gewonnen sein muss (0 = sofort).
-- Farben als Hex, Materialien als Enum.Material-Namen. Reine Daten, damit Server und Tests sie ohne Roblox-APIs lesen können.

local Skins = {}

Skins.HEROES = {
	leo = {
		{
			id = "abenteurer",
			name = "Abenteurer",
			desc = "Rote Tunika und goldbetresste Zipfelmütze. Der Leo, den alle kennen.",
			unlock = 0,
			shirt = "#e8473f",
			pants = "#3a2f55",
			skin = "#ffd3a8",
			accent = "#ffc63d",
			hat = "zipfel",
			hatColor = "#e8473f",
			weapon = "#8b93a6",
			glow = "#ff9a3d",
		},
		{
			id = "feuerritter",
			name = "Feuerritter",
			desc = "Glühende Rüstung aus dem Vulkan, Helm mit Flammenkamm.",
			unlock = 1,
			shirt = "#7a1d1d",
			pants = "#2a1a1a",
			skin = "#ffd3a8",
			accent = "#ff7a1a",
			hat = "ritter",
			hatColor = "#c9c9d6",
			weapon = "#2b2b33",
			glow = "#ff5a00",
			material = "Metal",
			neonAccent = true,
			effect = "fire",
		},
		{
			id = "kapitaen",
			name = "Kapitän Leo",
			desc = "Dreispitz, Augenklappe und goldene Knöpfe. Ahoi!",
			unlock = 2,
			shirt = "#1f3f8f",
			pants = "#f2efe6",
			skin = "#ffd3a8",
			accent = "#ffc63d",
			hat = "dreispitz",
			hatColor = "#1a1a22",
			weapon = "#6b4a2a",
			glow = "#ffd84a",
			eyepatch = true,
		},
		{
			id = "sternenheld",
			name = "Sternenheld",
			desc = "Leuchtet wie ein Komet und trägt eine Krone aus Sternen.",
			unlock = 3,
			shirt = "#2a1d6b",
			pants = "#130c33",
			skin = "#ffe0bd",
			accent = "#7df9ff",
			hat = "sternkrone",
			hatColor = "#ffe14a",
			weapon = "#e9ecff",
			glow = "#7df9ff",
			neonAccent = true,
			effect = "sparkles",
		},
	},
	bruna = {
		{
			id = "brecherin",
			name = "Brecherin",
			desc = "Stahlhelm, Schulterpolster und eine Donnerbüchse aus Messing.",
			unlock = 0,
			shirt = "#22b3a2",
			pants = "#2c2244",
			skin = "#f2c29b",
			accent = "#c8923a",
			hat = "stahlhelm",
			hatColor = "#a9bccb",
			weapon = "#c8923a",
			glow = "#7ff2e2",
		},
		{
			id = "lavaschmiedin",
			name = "Lavaschmiedin",
			desc = "Schmiedeschürze und Hörnerhelm mit glühenden Spitzen.",
			unlock = 1,
			shirt = "#2a2226",
			pants = "#1a1416",
			skin = "#f2c29b",
			accent = "#ff6a1a",
			hat = "hoernerhelm",
			hatColor = "#3a3236",
			weapon = "#3a3236",
			glow = "#ff6a1a",
			neonAccent = true,
			effect = "smoke",
		},
		{
			id = "eiswaechterin",
			name = "Eiswächterin",
			desc = "Rüstung aus ewigem Eis und eine Krone aus Eiszapfen.",
			unlock = 2,
			shirt = "#9fe3ff",
			pants = "#3d6e9a",
			skin = "#f6dccb",
			accent = "#e8fbff",
			hat = "eiskrone",
			hatColor = "#bff3ff",
			weapon = "#d8f6ff",
			glow = "#bff3ff",
			material = "Ice",
			effect = "snow",
		},
		{
			id = "goldbruna",
			name = "Goldene Bruna",
			desc = "Massives Gold vom Helm bis zur Büchse. Nur für Siegerinnen.",
			unlock = 3,
			shirt = "#ffc63d",
			pants = "#8a5a12",
			skin = "#f2c29b",
			accent = "#fff1b0",
			hat = "stahlhelm",
			hatColor = "#ffd84a",
			weapon = "#ffd84a",
			glow = "#fff1b0",
			material = "Foil",
			effect = "sparkles",
		},
	},
	pip = {
		{
			id = "spaeherin",
			name = "Späherin",
			desc = "Fliegerbrille, Blatt auf dem Kopf und eine lange Fernrohrflinte.",
			unlock = 0,
			shirt = "#a6d93b",
			pants = "#3a5a22",
			skin = "#ffd3a8",
			accent = "#ff9d2a",
			hat = "blatt",
			hatColor = "#7fd23b",
			weapon = "#3b3f52",
			glow = "#d8ff6a",
		},
		{
			id = "schattenninja",
			name = "Schattenninja",
			desc = "Lautlos, schwarz gekleidet, mit wehendem roten Schal.",
			unlock = 1,
			shirt = "#1c1a24",
			pants = "#121018",
			skin = "#ffd3a8",
			accent = "#e8303f",
			hat = "ninja",
			hatColor = "#1c1a24",
			weapon = "#e8303f",
			glow = "#ff4a5a",
			material = "Fabric",
		},
		{
			id = "astronautin",
			name = "Astronautin",
			desc = "Raumanzug mit Glashelm und Sauerstoff-Rucksack.",
			unlock = 2,
			shirt = "#f2f2f5",
			pants = "#c9ccd6",
			skin = "#ffd3a8",
			accent = "#ff7a2f",
			hat = "glashelm",
			hatColor = "#bfe8ff",
			weapon = "#6b7088",
			glow = "#9fe8ff",
			backpack = true,
		},
		{
			id = "regenbogen",
			name = "Regenbogen-Pip",
			desc = "Jede Farbe auf einmal und ein leuchtender Irokese.",
			unlock = 3,
			shirt = "#ff5fd2",
			pants = "#4fb4ff",
			skin = "#ffd3a8",
			accent = "#ffe14a",
			hat = "regenbogen",
			hatColor = "#ff5a5a",
			weapon = "#ffffff",
			glow = "#ff5fd2",
			rainbow = true,
			neonAccent = true,
			effect = "sparkles",
		},
	},
}

-- Standard-Skin je Held (erster Eintrag)
Skins.DEFAULTS = {}
for heroKind, list in pairs(Skins.HEROES) do
	Skins.DEFAULTS[heroKind] = list[1].id
end

function Skins.get(heroKind: string, id: string?)
	local list = Skins.HEROES[heroKind]
	if not list then
		return nil
	end
	for _, s in ipairs(list) do
		if s.id == id then
			return s
		end
	end
	return list[1]
end

-- Ist der Skin bei "won" gewonnenen Kämpfen verfügbar?
function Skins.isUnlocked(heroKind: string, id: string, won: number): boolean
	local s = Skins.get(heroKind, id)
	return s ~= nil and s.id == id and won >= s.unlock
end

-- Skins, die genau durch den Sieg in Kampf "level" neu dazukommen
function Skins.unlockedBy(level: number)
	local out = {}
	for _, heroKind in ipairs({ "leo", "bruna", "pip" }) do
		for _, s in ipairs(Skins.HEROES[heroKind]) do
			if s.unlock == level then
				table.insert(out, { hero = heroKind, skin = s })
			end
		end
	end
	return out
end

return Skins
