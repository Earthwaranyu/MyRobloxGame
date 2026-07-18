local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Sole authority over Humanoid.WalkSpeed. Clients used to set this directly
-- (SprintController), which is a classic Roblox speedhack: anything a client
-- sets on its own Humanoid replicates as-is, so a hacked client could just
-- set WalkSpeed to 500 and win every race for free Elo/points. Now the
-- client only ever sends intent ("shift is held or not") and the server
-- decides the actual number.
local MovementService = {}

-- A legitimate shift press/release can't happen faster than this; anything
-- beyond it is either a broken client or a script spamming the remote, so
-- it's dropped rather than acted on.
local MIN_INTENT_INTERVAL = 0.05

local lastIntentTime: { [number]: number } = {}

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function applySprint(player: Player, isSprinting: boolean)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = if isSprinting then Constants.SprintSpeed else Constants.WalkSpeed
	end
end

function MovementService.Init()
	local sprintIntentRemote = Net.CreateRemoteEvent(RemoteNames.SetSprintIntent)

	sprintIntentRemote.OnServerEvent:Connect(function(player: Player, isSprinting: boolean)
		if typeof(isSprinting) ~= "boolean" then
			return
		end

		local now = os.clock()
		local userId = player.UserId
		if lastIntentTime[userId] and now - lastIntentTime[userId] < MIN_INTENT_INTERVAL then
			return
		end
		lastIntentTime[userId] = now

		applySprint(player, isSprinting)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			applySprint(player, false)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastIntentTime[player.UserId] = nil
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			applySprint(player, false)
		end)
	end
end

return MovementService
