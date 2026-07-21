local Players = game:GetService("Players")

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
end

return CameraController
