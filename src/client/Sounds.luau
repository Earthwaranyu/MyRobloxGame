-- Thin wrapper around a small set of client SFX. Uses engine-bundled
-- rbxasset:// sounds (shipped with the Roblox client, not catalog assets) so
-- there's nothing to own or moderate; swap SoundId values for custom uploads
-- later if you want a distinct audio identity.
local SoundService = game:GetService("SoundService")

local Sounds = {}

-- "rbxasset://sounds/bell.wav" was tried here and failed to load in-engine
-- ("Temp read failed") despite being a commonly cited built-in path, so
-- everything below sticks to the two rbxasset sounds verified to actually
-- load: electronicpingshort.wav and switch3.wav. Distinct events are told
-- apart by volume/pitch instead of by sound file.
local IDS = {
	Hover = "rbxasset://sounds/switch3.wav",
	Click = "rbxasset://sounds/electronicpingshort.wav",
	Tick = "rbxasset://sounds/electronicpingshort.wav",
	Go = "rbxasset://sounds/electronicpingshort.wav",
	Victory = "rbxasset://sounds/electronicpingshort.wav",
	Defeat = "rbxasset://sounds/switch3.wav",
	Purchase = "rbxasset://sounds/electronicpingshort.wav",
	RankUp = "rbxasset://sounds/electronicpingshort.wav",
}

local VOLUME = {
	Hover = 0.15,
	Click = 0.35,
	Tick = 0.3,
	Go = 0.7,
	Victory = 0.7,
	Defeat = 0.5,
	Purchase = 0.45,
	RankUp = 0.7,
}

local PITCH = {
	Defeat = 0.7,
	Go = 1.3,
	Victory = 1.5,
	RankUp = 1.8,
}

local pool: { [string]: Sound } = {}

local function getSound(name: string): Sound?
	local id = IDS[name]
	if not id then
		return nil
	end

	local sound = pool[name]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = id
		sound.Volume = VOLUME[name] or 0.5
		sound.PlaybackSpeed = PITCH[name] or 1
		sound.Parent = SoundService
		pool[name] = sound
	end
	return sound
end

function Sounds.Play(name: string)
	local sound = getSound(name)
	if sound then
		sound:Play()
	end
end

return Sounds
