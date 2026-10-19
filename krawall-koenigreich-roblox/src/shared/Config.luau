-- Spieldaten für Krawall-Königreich: Helden, Gegner und Level.
-- Reine Daten ohne Roblox-APIs, damit Rules.luau auch außerhalb von Roblox getestet werden kann.

local Config = {}

Config.TILE = 4 -- Studs pro Spielfeld
Config.JUMP = 3 -- Reichweite des Teamsprungs (Felder)
Config.STOMP_DMG = 30
Config.FALL_DMG = 50
Config.BUMP_DMG = 10
Config.BURN_DMG = 15
Config.SHOCK_DMG = 25

Config.EFFECT_NAMES = { burn = "Brand", push = "Rückstoß", honey = "Honig" }

Config.HERO_ORDER = { "leo", "bruna", "pip" }

Config.HEROES = {
	leo = {
		name = "Leo",
		role = "Anführer",
		color = "#ef4b3f",
		hp = 120,
		move = 5,
		dash = 25,
		weapon = { name = "Funkenblaster", range = 6, min = 30, max = 38, effect = "burn", chance = 0.30 },
		tech = {
			id = "overwatch",
			name = "Wachsamkeit",
			cd = 2,
			desc = "Schießt im Gegnerzug auf den ersten Gegner, der sich in Reichweite bewegt.",
		},
	},
	bruna = {
		name = "Bruna",
		role = "Brecherin",
		color = "#22b3a2",
		hp = 160,
		move = 4,
		dash = 35,
		weapon = { name = "Donnerbüchse", range = 3.2, min = 52, max = 66, effect = "push", chance = 0.40, push = 2 },
		tech = {
			id = "shield",
			name = "Bollwerk",
			cd = 3,
			radius = 3,
			desc = "Helden im Umkreis von 3 Feldern erleiden bis zu deinem nächsten Zug nur halben Schaden.",
		},
	},
	pip = {
		name = "Pip",
		role = "Späherin",
		color = "#a6d93b",
		hp = 100,
		move = 6,
		dash = 15,
		weapon = { name = "Fernrohrflinte", range = 9, min = 34, max = 44, effect = "honey", chance = 0.35 },
		tech = {
			id = "heal",
			name = "Heilwelle",
			cd = 3,
			radius = 3,
			amount = 45,
			desc = "Heilt Helden im Umkreis von 3 Feldern um 45 LP und löscht Brand.",
		},
	},
}

Config.ENEMIES = {
	grunt = { name = "Krawallo", hp = 80, move = 4, color = "#9a5cf0", weapon = { name = "Knallrohr", range = 5.5, min = 20, max = 28 } },
	sniper = { name = "Schleuderer", hp = 60, move = 4, color = "#2fbf8a", weapon = { name = "Weitschleuder", range = 8.5, min = 26, max = 34 } },
	brute = {
		name = "Brummer",
		hp = 150,
		move = 4,
		color = "#ff7a3d",
		weapon = { name = "Rammfaust", range = 1.5, min = 40, max = 50, effect = "push", chance = 0.6, push = 1, melee = true },
	},
	king = {
		name = "Krawall-König",
		hp = 320,
		move = 3,
		color = "#c23cd6",
		boss = true,
		weapon = { name = "Zepterkanone", range = 7, min = 30, max = 40, effect = "burn", chance = 0.3 },
	},
}

Config.ENEMY_CODES = { g = "grunt", s = "sniper", b = "brute", K = "king" }

-- Kartenlegende: . Boden  # Steinmauer (volle Deckung)  o Kiste (halbe Deckung)  ~ Wasser
-- 1/2/3 Leo/Bruna/Pip  g Krawallo  s Schleuderer  b Brummer  K König  r Verstärkungspunkt
Config.LEVELS = {
	{
		name = "Pilzwiese",
		goal = "Besiege alle Krawallos",
		par = 5,
		blurb = "Drei Krawallos auf offener Wiese. Ideal, um Deckung und Teamsprung zu üben.",
		theme = {
			floor = "grass",
			a = "#7cc95a",
			b = "#6fbd4e",
			side = "#8a5a33",
			decor = "meadow",
			clock = 14,
			brightness = 2.4,
			ambient = "#8d9aa8",
			atmosphere = "#cfe9ff",
			decay = "#9fc4e8",
			water = "#2f9fe0",
		},
		map = {
			"~~....g....~~",
			"~...o...o...~",
			"..g.......g..",
			"...##...##...",
			".............",
			".o...o.o...o.",
			"....#...#....",
			"..o.......o..",
			"......#......",
			".....o.o.....",
			"..o.......o..",
			"...1..2..3...",
			"~~.........~~",
		},
	},
	{
		name = "Ruinenbrücke",
		goal = "Besiege alle Krawallos",
		par = 6,
		blurb = "Ein Fluss teilt das Feld. Schleuderer schießen von weit hinten, der Brummer rennt über die Brücken.",
		theme = {
			floor = "grass",
			a = "#a9c95a",
			b = "#9cbd50",
			side = "#7d5634",
			decor = "ruins",
			clock = 16.4,
			brightness = 2.2,
			ambient = "#9a9280",
			atmosphere = "#ffe9c4",
			decay = "#d9b98a",
			water = "#2a8fc7",
		},
		map = {
			"~~...#..#...~~",
			"~.o...s.....o~",
			"...g..oo..g...",
			".#....b.....#.",
			"~~~..~~~~..~~~",
			"~~~..~~~~..~~~",
			"..o........o..",
			"....#....#....",
			".o....oo....o.",
			"......##......",
			"..............",
			"..o..1.2.3..o.",
			"~............~",
		},
	},
	{
		name = "Thronhof",
		goal = "Besiege den Krawall-König und seine Garde",
		par = 10,
		blurb = "Der König teilt Schockwellen aus und ruft Verstärkung, sobald er angeschlagen ist.",
		theme = {
			floor = "stone",
			a = "#bdb6aa",
			b = "#aea79b",
			side = "#5d4a6e",
			decor = "castle",
			clock = 17.7,
			brightness = 1.8,
			ambient = "#8a6f8a",
			atmosphere = "#ffb38a",
			decay = "#6a4a8a",
			water = "#3a5fb0",
		},
		map = {
			"~~~...#.#...~~~",
			"~~.r...K...r.~~",
			"~...o.....o...~",
			"..g..##.##..g..",
			"......o.o......",
			".#..s......b.#.",
			"..o.........o..",
			"~~~..~~.~~..~~~",
			"....o.....o....",
			".##....#....##.",
			"...o.......o...",
			"......o.o......",
			"....1..2..3....",
			"~.............~",
			"~~~.........~~~",
		},
	},
}

return Config
