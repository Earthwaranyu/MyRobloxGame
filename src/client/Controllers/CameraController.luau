local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MatchStateController = require(script.Parent.MatchStateController)

local CameraController = {}

local player = Players.LocalPlayer

-- Roblox's own engine default, restored after the force-zoom-out kick below
-- so players can still freely zoom in/out (including back to first person
-- manually) once they're away from Racing.
local DEFAULT_MIN_ZOOM = 0.5
-- Comfortably past Roblox's own third-person spawn distance (~12.5 studs)
-- so the kick below reliably reads as "back to third person."
local ZOOM_OUT_KICK = 16

-- Setting CameraMode back to Classic does NOT, on its own, restore the
-- camera's actual zoom distance -- confirmed in Studio: switching out of
-- LockFirstPerson left the camera still sitting ~1.7 studs from the
-- character (i.e. still visually first-person) until the player manually
-- scrolled out, because Roblox's built-in camera script tracks "current
-- zoom" as separate internal state that a CameraMode change alone doesn't
-- touch. Briefly raising CameraMinZoomDistance past that stuck distance
-- forces the camera script to clamp/push back out; restoring the default
-- afterward leaves zoom free again.
local function forceThirdPerson()
	player.CameraMinZoomDistance = ZOOM_OUT_KICK
	task.wait(0.3)
	player.CameraMinZoomDistance = DEFAULT_MIN_ZOOM
end

local previousState: string? = nil

local function applyState(state: string)
	if state == "Racing" then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		-- Covers Lobby AND Spectating: CameraMode is a different axis from
		-- CameraType/CameraSubject (which SpectateController separately
		-- drives while Spectating -- see that module) -- LockFirstPerson
		-- forces a near-zero zoom lock onto the LOCAL player's own character
		-- specifically and ignores CameraSubject entirely, so leaving it set
		-- from Racing left a just-finished player stuck staring at their own
		-- face no matter what SpectateController pointed CameraSubject at.
		-- This reset has to run for every non-Racing state, Spectating
		-- included, for SpectateController's camera control to mean anything.
		player.CameraMode = Enum.CameraMode.Classic
		-- Only kick the zoom when actually leaving Racing (finishing,
		-- getting bumped to spectate, ...) -- not on every non-Racing state
		-- application, which would also fire once at Init and yank the
		-- camera out for a player who hadn't even been in first person.
		if previousState == "Racing" then
			task.spawn(forceThirdPerson)
		end
	end
	previousState = state
end

function CameraController.Init()
	MatchStateController.StateChanged:Connect(applyState)
	applyState(MatchStateController.CurrentState)

	-- Player is still in the "Lobby" state for the whole pre-race countdown
	-- (see MatchService.startSession -- "Racing" only flips once it hits
	-- zero), so applyState above wouldn't lock the camera in first-person
	-- until GO. Forcing it here instead, right as the countdown starts, so
	-- the player is already looking through the character's eyes -- lined up
	-- with the server also freezing them in place for the same window (see
	-- MatchService's setFrozen) -- for the whole "RACE STARTING IN" beat.
	local preRaceRemote = Net.GetRemoteEvent(RemoteNames.PreRaceCountdown)
	preRaceRemote.OnClientEvent:Connect(function()
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end)
end

return CameraController
