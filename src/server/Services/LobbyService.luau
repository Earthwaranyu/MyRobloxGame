local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local LobbyService = {}

local playerStates = {}
local matchStateRemote: RemoteEvent

-- state is "Lobby" (third person) or "Racing" (first person).
function LobbyService.SetPlayerState(player: Player, state: string)
	playerStates[player.UserId] = state
	matchStateRemote:FireClient(player, state)
end

function LobbyService.GetPlayerState(player: Player): string
	return playerStates[player.UserId] or "Lobby"
end

function LobbyService.Init()
	matchStateRemote = Net.CreateRemoteEvent(RemoteNames.MatchStateChanged)

	Players.PlayerAdded:Connect(function(player)
		playerStates[player.UserId] = "Lobby"
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerStates[player.UserId] = nil
	end)
end

return LobbyService
