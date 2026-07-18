local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Weather = require(Shared.Weather)

local Ambience = require(script.Parent.Parent.Ambience)
local MatchStateController = require(script.Parent.MatchStateController)

-- Swaps the single music/ambience bed between the lobby's exciting song and
-- the current stage's weather atmosphere (rain, crickets, birdsong...) as the
-- player moves between "Lobby" and "Racing" (see MatchStateController). Also
-- drives the occasional thunder/owl one-shot accents layered on top.
local AmbienceController = {}

local pendingStageId: string? = nil
local accentThread: thread? = nil

local function stopAccentLoop()
	if accentThread then
		task.cancel(accentThread)
		accentThread = nil
	end
end

local function startAccentLoop(preset: Weather.WeatherPreset)
	stopAccentLoop()
	local soundId = preset.AccentSoundId
	if not soundId then
		return
	end

	local volume = preset.AccentVolume or 0.5
	local minWait = preset.AccentIntervalMin or 20
	local maxWait = preset.AccentIntervalMax or 40

	accentThread = task.spawn(function()
		while true do
			task.wait(minWait + math.random() * (maxWait - minWait))
			Ambience.PlayOneShot(soundId, volume)
		end
	end)
end

local function applyState(state: string, fadeTime: number?)
	if state == "Racing" then
		local preset = pendingStageId and Weather.GetForStage(pendingStageId)
		if preset then
			Ambience.CrossfadeBed("weather:" .. pendingStageId, preset.AmbientSoundId, preset.AmbientVolume, fadeTime)
			startAccentLoop(preset)
		end
	else
		stopAccentLoop()
		Ambience.CrossfadeBed("lobby", Weather.Lobby.MusicSoundId, Weather.Lobby.MusicVolume, fadeTime)
	end
end

function AmbienceController.Init()
	local mapRemote = Net.GetRemoteEvent(RemoteNames.MapSelected)
	mapRemote.OnClientEvent:Connect(function(stageId: string)
		pendingStageId = stageId
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		applyState(state)
	end)
	applyState(MatchStateController.CurrentState, 0.05)
end

return AmbienceController
