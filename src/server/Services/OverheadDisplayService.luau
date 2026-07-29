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
	billboard.Size = UDim2.fromOffset(168, 40)
	billboard.StudsOffset = Vector3.new(0, 2.6, 0)
	billboard.MaxDistance = 100
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(15, 16, 22)
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = backdrop

	local stroke = Instance.new("UIStroke")
	stroke.Name = "RankStroke"
	stroke.Thickness = 1.5
	stroke.Transparency = 0.2
	stroke.Parent = backdrop

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(0.92, 0.86)
	label.Position = UDim2.fromScale(0.04, 0.07)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.2
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = backdrop

	return billboard
end

function OverheadDisplayService.Refresh(player: Player)
	local character = player.Character

	-- Roblox's own nameplate is turned off, for two reasons.
	--
	-- It duplicates this billboard, which already carries the player's name --
	-- so every character was wearing two nameplates saying the same thing.
	--
	-- And it's the click target for Roblox's built-in profile page, which is a
	-- SECOND, competing way to look someone up: one click for Roblox's page,
	-- double-click for ProfileCardController's. That one shows strictly more
	-- (rank, win rate, equipped ability, W/L, playtime, best time per stage,
	-- and the 1v1 / party buttons), so the native page isn't worth keeping a
	-- separate gesture for -- removing the nameplate leaves the double-click
	-- card as the single route to another player's details.
	--
	-- Also closes a smaller hole: RaceVisibilityController blocks clicks during
	-- a race so you can't identify racers you can't see, and a native nameplate
	-- is exactly the sort of thing that would have quietly reopened it.
	--
	-- Done before the head guard below: the nameplate should go even in the
	-- rare case the billboard can't be built, or a character would briefly wear
	-- the native plate with nothing replacing it.
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

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
	local backdrop = billboard:FindFirstChild("Backdrop") :: Frame
	local label = backdrop:FindFirstChild("Label") :: TextLabel
	local stroke = backdrop:FindFirstChild("RankStroke") :: UIStroke

	-- Published as a replicated attribute rather than drawn into this billboard.
	-- The streak flame flickers and sheds embers, and animating that server-side
	-- would mean replicating a property change per frame per player; as an
	-- attribute it costs one small update per race and every client animates its
	-- own copy. See StreakFlameController for the drawing.
	player:SetAttribute("WinStreak", profile.WinStreak)

	local rankColor = RankTiers.GetColorForElo(profile.Elo)
	-- Name included, not just rank/elo -- without it there was no way to
	-- visually tell two characters apart in the 3D world at all (confirmed
	-- source of real confusion: Studio's simulated test accounts render
	-- identical default avatars, so "who am I actually looking at" had no
	-- answer besides trusting UI text elsewhere on screen).
	label.Text = ("%s  •  %s %d"):format(player.Name, RankTiers.GetRankForElo(profile.Elo), profile.Elo)
	label.TextColor3 = rankColor
	stroke.Color = rankColor
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
