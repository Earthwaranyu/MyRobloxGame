local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local MatchStateController = {}

MatchStateController.StateChanged = Signal.new()
MatchStateController.CurrentState = "Lobby"

function MatchStateController.Init()
	local remote = Net.GetRemoteEvent(RemoteNames.MatchStateChanged)
	remote.OnClientEvent:Connect(function(newState: string)
		MatchStateController.CurrentState = newState
		MatchStateController.StateChanged:Fire(newState)
	end)
end

return MatchStateController
