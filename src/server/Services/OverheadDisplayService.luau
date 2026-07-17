local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local RankTiers = require(Shared.RankTiers)

local PlayerDataService = require(script.Parent.PlayerDataService)

-- Server-owned BillboardGui above each character's head, so rank/elo is
-- visible to every client, not just the owning player.
local OverheadDisplayService = {}

local function buildBillboard(head: BasePart): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EloDisplay"
	billboard.Size = UDim2.fromOffset(160, 36)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.MaxDistance = 100
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	return billboard
end

function OverheadDisplayService.Refresh(player: Player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	local attempts = 0
	while not profile and attempts < 100 do
		task.wait()
		profile = PlayerDataService.GetProfile(player)
		attempts += 1
	end
	if not profile then
		return
	end

	local billboard = head:FindFirstChild("EloDisplay") :: BillboardGui? or buildBillboard(head :: BasePart)
	local label = billboard:FindFirstChild("Label") :: TextLabel
	label.Text = ("%s (%d)"):format(RankTiers.GetRankForElo(profile.Elo), profile.Elo)
end

function OverheadDisplayService.Init()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			OverheadDisplayService.Refresh(player)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			OverheadDisplayService.Refresh(player)
		end)
		if player.Character then
			OverheadDisplayService.Refresh(player)
		end
	end
end

return OverheadDisplayService
