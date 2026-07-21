local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Weather = require(Shared.Weather)

local Ambience = require(script.Parent.Parent.Ambience)
local MatchStateController = require(script.Parent.MatchStateController)

-- Swaps the single music bed between the lobby's track and an even more
-- hyped-up race track as the player moves between "Lobby" and "Racing" (see
-- MatchStateController). Also drives the occasional thunder/owl one-shot
-- weather accents layered on top of whichever bed is currently playing.
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
		Ambience.CrossfadeBed("race", Weather.Race.MusicSoundId, Weather.Race.MusicVolume, fadeTime)
		-- Weather still drives the occasional thunder/owl accent, just not
		-- the main bed anymore -- that's the race track now.
		local preset = pendingStageId and Weather.GetForStage(pendingStageId)
		if preset then
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

	-- Player stays in the "Lobby" state for the whole pre-race countdown
	-- (see MatchService.startSession -- the group is already teleported to
	-- the stage but "Racing" only flips once the countdown hits zero), so
	-- without this the lobby track would otherwise just keep playing under
	-- the "RACE STARTING IN" ticker. Cutting the music out here instead lets
	-- the countdown's own tick/GO! sounds land in silence -- easier to focus
	-- on -- and applyState's crossfade into the race track takes over the
	-- instant "Racing" actually fires.
	local preRaceRemote = Net.GetRemoteEvent(RemoteNames.PreRaceCountdown)
	preRaceRemote.OnClientEvent:Connect(function()
		Ambience.StopBed()
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		applyState(state)
	end)
	applyState(MatchStateController.CurrentState, 0.05)
end

return AmbienceController
