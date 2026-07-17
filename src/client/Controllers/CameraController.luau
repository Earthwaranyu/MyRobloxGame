local Players = game:GetService("Players")

local MatchStateController = require(script.Parent.MatchStateController)

local CameraController = {}

local player = Players.LocalPlayer

local function applyState(state: string)
	if state == "Racing" then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
	end
end

function CameraController.Init()
	MatchStateController.StateChanged:Connect(applyState)
	applyState(MatchStateController.CurrentState)
end

return CameraController
