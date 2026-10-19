-- Server: Welt vorbereiten (Wasser, Wolken) und Spielfortschritt samt Skin-Auswahl per DataStore speichern.
-- Gespielt wird auf dem Client; der Server speichert nur, was der Spieler freigeschaltet und ausgerüstet hat.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Shared = ReplicatedStorage:WaitForChild("Krawall")
local Config = require(Shared:WaitForChild("Config"))
local Skins = require(Shared:WaitForChild("Skins"))

-- Kein Avatar: das Spiel wird mit Maus, Tastatur oder Touch über eine freie Kamera gesteuert
Players.CharacterAutoLoads = false

local remote = Instance.new("RemoteFunction")
remote.Name = "KrawallProgress"
remote.Parent = ReplicatedStorage

-- Wasser rund um die schwebenden Spielfelder und ein paar Wolken
task.spawn(function()
	local terrain = workspace.Terrain
	pcall(function()
		terrain:FillBlock(CFrame.new(0, -7, 0), Vector3.new(640, 10, 640), Enum.Material.Water)
	end)
	terrain.WaterTransparency = 0.55
	terrain.WaterWaveSize = 0.18
	terrain.WaterWaveSpeed = 8
	terrain.WaterReflectance = 0.35
	pcall(function()
		local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
		clouds.Cover = 0.55
		clouds.Density = 0.6
		clouds.Parent = terrain
	end)
end)

local store = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("KrawallKoenigreich_v1")
	end)
	if ok then
		store = result
	end
end

local cache = {} -- UserId -> Daten
local dirty = {} -- UserId -> true, wenn noch nicht gespeichert

local function defaults()
	return { won = 0, best = {}, skins = table.clone(Skins.DEFAULTS) }
end

-- Nur bekannte Felder mit gültigen Werten übernehmen
local function sanitize(data, base)
	local out = defaults()
	if base then
		out.won = base.won
		out.best = table.clone(base.best)
		out.skins = table.clone(base.skins)
	end
	if type(data) ~= "table" then
		return out
	end
	local won = tonumber(data.won)
	if won then
		out.won = math.clamp(math.floor(won), out.won, #Config.LEVELS)
	end
	if type(data.best) == "table" then
		for i = 1, #Config.LEVELS do
			local b = data.best[tostring(i)]
			if type(b) == "table" and tonumber(b.score) and tonumber(b.turn) then
				out.best[tostring(i)] = { score = math.clamp(math.floor(b.score), 1, 3), turn = math.clamp(math.floor(b.turn), 1, 99) }
			end
		end
	end
	if type(data.skins) == "table" then
		for heroKind in pairs(Skins.DEFAULTS) do
			local id = data.skins[heroKind]
			if type(id) == "string" and Skins.isUnlocked(heroKind, id, out.won) then
				out.skins[heroKind] = id
			end
		end
	end
	return out
end

local function load(player: Player)
	local data = nil
	if store then
		local ok, result = pcall(function()
			return store:GetAsync("p_" .. player.UserId)
		end)
		if ok then
			data = result
		else
			warn("Krawall: Fortschritt konnte nicht geladen werden (in Studio ist das normal, solange API-Zugriff aus ist): " .. tostring(result))
		end
	end
	cache[player.UserId] = sanitize(data)
	return cache[player.UserId]
end

local function save(userId: number)
	local data = cache[userId]
	if not store or not data or not dirty[userId] then
		return
	end
	dirty[userId] = nil
	local ok, err = pcall(function()
		store:SetAsync("p_" .. userId, data)
	end)
	if not ok then
		dirty[userId] = true
		warn("Krawall: Speichern fehlgeschlagen: " .. tostring(err))
	end
end

remote.OnServerInvoke = function(player: Player, action: string, data)
	if action == "load" then
		return cache[player.UserId] or load(player)
	elseif action == "save" then
		local current = cache[player.UserId] or load(player)
		cache[player.UserId] = sanitize(data, current)
		dirty[player.UserId] = true
		return true
	end
	return nil
end

Players.PlayerRemoving:Connect(function(player)
	save(player.UserId)
	cache[player.UserId] = nil
	dirty[player.UserId] = nil
end)

game:BindToClose(function()
	for userId in pairs(dirty) do
		save(userId)
	end
end)

-- regelmäßig speichern, statt bei jeder Änderung (DataStore-Limits)
task.spawn(function()
	while true do
		task.wait(30)
		for userId in pairs(dirty) do
			save(userId)
		end
	end
end)
