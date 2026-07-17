local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Trails = require(Shared.Trails)

-- Renders whatever trail a player has equipped (server-owned truth lives in
-- PlayerDataService; ShopService mirrors it onto the character as the
-- "EquippedTrail" attribute so this works for every character, not just the
-- local player's).
local TrailVisualsController = {}

local function buildTrailEffect(character: Model): Trail?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end

	-- Offset behind and outside the torso (+Z is a character's back) so the
	-- ribbon renders clear of the body mesh instead of inside it.
	local top = Instance.new("Attachment")
	top.Name = "TrailAttachmentTop"
	top.Position = Vector3.new(0, 0.9, 1)
	top.Parent = root

	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailAttachmentBottom"
	bottom.Position = Vector3.new(0, -0.9, 1)
	bottom.Parent = root

	local trail = Instance.new("Trail")
	trail.Name = "EquippedTrailEffect"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.5
	trail.MinLength = 0.05
	trail.Enabled = false
	trail.Parent = root

	return trail
end

local function applyTrail(trail: Trail, trailId: string?)
	local data = trailId and Trails[trailId]
	if not data or not data.HasEffect then
		trail.Enabled = false
		return
	end

	trail.Color = data.Color or trail.Color
	trail.WidthScale = NumberSequence.new(data.Width0 or 1, data.Width1 or 0)
	trail.Enabled = true
end

local function watchCharacter(character: Model)
	local trail = buildTrailEffect(character)
	if not trail then
		return
	end

	local function sync()
		applyTrail(trail, character:GetAttribute("EquippedTrail"))
	end

	character:GetAttributeChangedSignal("EquippedTrail"):Connect(sync)
	sync()
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

function TrailVisualsController.Init()
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return TrailVisualsController
