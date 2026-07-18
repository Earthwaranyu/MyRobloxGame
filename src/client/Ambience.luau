-- Background music/weather-bed player. Separate from Sounds.luau (which is a
-- pool of short, fixed-id UI SFX): this deals with a single long-running
-- looped track that crossfades between the lobby's exciting song and
-- whichever stage's weather ambience is currently relevant, plus occasional
-- one-shot accents (thunder, an owl hoot) layered on top of it.
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Ambience = {}

local DEFAULT_FADE = 1.2

local bed = Instance.new("Sound")
bed.Name = "AmbienceBed"
bed.Looped = true
bed.Volume = 0
bed.Parent = SoundService

local currentKey: string? = nil
local activeTween: Tween? = nil

local function tweenVolume(target: number, duration: number): Tween
	if activeTween then
		activeTween:Cancel()
	end
	local tween = TweenService:Create(bed, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Volume = target,
	})
	activeTween = tween
	tween:Play()
	return tween
end

-- Fades the current bed out, swaps the SoundId, then fades the new one in.
-- Calling this again with the same key while it's already playing is a no-op
-- so e.g. repeated MapSelected events for the same stage don't restart it.
function Ambience.CrossfadeBed(key: string, soundId: string, volume: number, fadeTime: number?)
	fadeTime = fadeTime or DEFAULT_FADE

	if currentKey == key then
		return
	end
	currentKey = key

	local fadeOut = tweenVolume(0, fadeTime)
	task.delay(fadeTime, function()
		if currentKey ~= key or activeTween ~= fadeOut then
			return
		end
		bed.SoundId = soundId
		bed:Play()
		tweenVolume(volume, fadeTime)
	end)
end

function Ambience.StopBed(fadeTime: number?)
	fadeTime = fadeTime or DEFAULT_FADE
	currentKey = nil

	local fadeOut = tweenVolume(0, fadeTime)
	task.delay(fadeTime, function()
		if currentKey == nil and activeTween == fadeOut then
			bed:Stop()
		end
	end)
end

-- Fire-and-forget accent (thunder rumble, owl hoot). Not part of the SFX
-- pool in Sounds.luau since the id varies per weather rather than being fixed.
function Ambience.PlayOneShot(soundId: string, volume: number)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = SoundService

	local destroyed = false
	local function cleanup()
		if not destroyed then
			destroyed = true
			sound:Destroy()
		end
	end

	sound.Ended:Connect(cleanup)
	sound:Play()
	-- Fallback in case the sound fails to load and Ended never fires.
	task.delay(15, cleanup)
end

return Ambience
