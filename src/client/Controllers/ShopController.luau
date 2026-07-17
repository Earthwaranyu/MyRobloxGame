local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)
local RankTiers = require(Shared.RankTiers)

local Widgets = require(script.Parent.Parent.Widgets)

local ShopController = {}

local player = Players.LocalPlayer

local panel: Frame
local pointsLabel: TextLabel
local eloLabel: TextLabel
local itemsList: ScrollingFrame

local function buildItemRow(trailId: string, trail, profile): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 50)
	row.BackgroundColor3 = Color3.fromRGB(45, 45, 54)
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local nameLabel = Widgets.Label(trail.Name, UDim2.new(0.6, -8, 1, 0), UDim2.fromOffset(8, 0))
	nameLabel.Parent = row

	local owned = table.find(profile.OwnedTrails, trailId) ~= nil
	local equipped = profile.EquippedTrail == trailId
	local canAfford = profile.Points >= trail.PointsCost
	local showRobuxButton = not owned and trail.RobuxProductId ~= nil

	local actionText
	if equipped then
		actionText = "Unequip"
	elseif owned then
		actionText = "Equip"
	else
		actionText = ("Buy (%d pts)"):format(trail.PointsCost)
	end

	local actionWidth = if showRobuxButton then 0.27 else 0.35
	local actionX = if showRobuxButton then 0.44 else 0.63

	local actionButton = Widgets.Button(actionText, UDim2.fromScale(actionWidth, 0.7), UDim2.fromScale(actionX, 0.15))
	actionButton.Name = "ActionButton"
	actionButton.Parent = row

	if equipped then
		actionButton.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
	elseif not owned and not canAfford then
		actionButton.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
		actionButton.Active = false
	end

	if showRobuxButton then
		local robuxButton = Widgets.Button("Buy R$", UDim2.fromScale(0.27, 0.7), UDim2.fromScale(0.72, 0.15))
		robuxButton.Name = "RobuxButton"
		robuxButton.BackgroundColor3 = Color3.fromRGB(0, 162, 255)
		robuxButton.Parent = row

		robuxButton.MouseButton1Click:Connect(function()
			Net.GetRemoteEvent(RemoteNames.PromptRobuxPurchase):FireServer(trailId)
		end)
	end

	actionButton.MouseButton1Click:Connect(function()
		if equipped then
			local success = Net.GetRemoteFunction(RemoteNames.EquipTrail):InvokeServer("")
			if success then
				ShopController.Refresh()
			end
		elseif owned then
			local success = Net.GetRemoteFunction(RemoteNames.EquipTrail):InvokeServer(trailId)
			if success then
				ShopController.Refresh()
			end
		else
			local success, message = Net.GetRemoteFunction(RemoteNames.PurchaseTrail):InvokeServer(trailId)
			actionButton.Text = message
			if success then
				task.wait(0.5)
				ShopController.Refresh()
			end
		end
	end)

	return row
end

function ShopController.Refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	pointsLabel.Text = ("Points: %d"):format(profile.Points)
	eloLabel.Text = ("%s (%d elo)"):format(RankTiers.GetRankForElo(profile.Elo), profile.Elo)

	for _, child in itemsList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Table iteration order is unspecified, so sort for a stable display order.
	local trailIds = {}
	for trailId in Trails do
		table.insert(trailIds, trailId)
	end
	table.sort(trailIds)

	for i, trailId in trailIds do
		local row = buildItemRow(trailId, Trails[trailId], profile)
		row.LayoutOrder = i
		row.Parent = itemsList
	end
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShopGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- y = 60 clears Roblox's default top bar (chat/leaderboard/settings icons).
	local toggleButton = Widgets.Button("Shop", UDim2.fromOffset(100, 36), UDim2.new(1, -110, 0, 60))
	toggleButton.Parent = screenGui

	panel = Widgets.Panel(UDim2.fromOffset(360, 420), UDim2.new(1, -370, 0, 106))
	panel.Parent = screenGui

	local title = Widgets.Label("Trail Shop", UDim2.new(1, -16, 0, 28), UDim2.fromOffset(8, 4))
	title.TextSize = 22
	title.Parent = panel

	pointsLabel = Widgets.Label("Points: 0", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 36))
	pointsLabel.TextSize = 16
	pointsLabel.Parent = panel

	eloLabel = Widgets.Label("", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 54))
	eloLabel.TextSize = 16
	eloLabel.Parent = panel

	itemsList = Instance.new("ScrollingFrame")
	itemsList.Size = UDim2.new(1, -16, 1, -94)
	itemsList.Position = UDim2.fromOffset(8, 86)
	itemsList.BackgroundTransparency = 1
	itemsList.BorderSizePixel = 0
	itemsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	itemsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	itemsList.ScrollBarThickness = 6
	itemsList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = itemsList

	toggleButton.MouseButton1Click:Connect(function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			ShopController.Refresh()
		end
	end)
end

function ShopController.Init()
	buildUI()
end

return ShopController
