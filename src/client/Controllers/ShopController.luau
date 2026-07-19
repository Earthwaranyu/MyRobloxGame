local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local PointBundles = require(Shared.PointBundles)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)
local RankTiers = require(Shared.RankTiers)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

local ShopController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local pointsLabel: TextLabel
local rankLabel: TextLabel
local itemsList: ScrollingFrame

local function swatchColor(trail): Color3
	if not trail.HasEffect or not trail.Color then
		return Theme.Color.TextMuted
	end
	return trail.Color.Keypoints[1].Value
end

local function buildItemRow(trailId: string, trail, profile): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 54)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.new(0, 6, 1, -12)
	swatch.Position = UDim2.fromOffset(6, 6)
	swatch.BackgroundColor3 = swatchColor(trail)
	swatch.BorderSizePixel = 0
	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(1, 0)
	swatchCorner.Parent = swatch
	swatch.Parent = row

	local owned = table.find(profile.OwnedTrails, trailId) ~= nil
	local equipped = profile.EquippedTrail == trailId
	local canAfford = profile.Points >= trail.PointsCost
	local showRobuxButton = not owned and trail.RobuxProductId ~= nil

	local nameLabel = Widgets.Label(trail.Name, UDim2.new(0.55, -20, 0, 22), UDim2.fromOffset(22, 6), {
		TextSize = 16,
	})
	nameLabel.Parent = row

	local subLabel = Widgets.Label(
		if equipped then "Equipped" elseif owned then "Owned" else ("%d points"):format(trail.PointsCost),
		UDim2.new(0.55, -20, 0, 18),
		UDim2.fromOffset(22, 28),
		{
			TextSize = 13,
			Bold = false,
			Color = if equipped then Theme.Color.Success elseif owned then Theme.Color.TextSecondary else Theme.Color.Warning,
		}
	)
	subLabel.Parent = row

	local actionText
	local actionVariant
	if equipped then
		actionText = "Unequip"
		actionVariant = "Success"
	elseif owned then
		actionText = "Equip"
		actionVariant = "Primary"
	else
		actionText = "Buy"
		actionVariant = if canAfford then "Primary" else "Secondary"
	end

	local actionWidth = if showRobuxButton then 0.22 else 0.32
	local actionX = if showRobuxButton then 0.5 else 0.65

	local actionButton = Widgets.Button(actionText, UDim2.fromScale(actionWidth, 0.66), UDim2.fromScale(actionX, 0.17), {
		Variant = actionVariant,
		TextSize = 14,
	})
	actionButton.Name = "ActionButton"
	actionButton.Parent = row

	if not owned and not canAfford then
		actionButton.Active = false
		actionButton.AutoButtonColor = false
	end

	if showRobuxButton then
		local robuxButton = Widgets.Button("R$ Buy", UDim2.fromScale(0.24, 0.66), UDim2.fromScale(0.75, 0.17), {
			Variant = "Secondary",
			TextSize = 14,
		})
		robuxButton.Name = "RobuxButton"
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
			subLabel.Text = message
			if success then
				task.wait(0.4)
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

	local rankName = RankTiers.GetRankForElo(profile.Elo)
	rankLabel.Text = ("%s  •  %d elo"):format(rankName, profile.Elo)
	rankLabel.TextColor3 = Theme.GetRankColor(rankName)
	pointsLabel.Text = ("%d points"):format(profile.Points)

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

local openPanel: () -> ()
local closePanel: () -> ()

local function buildUI()
	local toggleGui = Instance.new("ScreenGui")
	toggleGui.Name = "ShopToggleGui"
	toggleGui.ResetOnSpawn = false
	toggleGui.Parent = player:WaitForChild("PlayerGui")

	-- y = 60 clears Roblox's default top bar (chat/leaderboard/settings icons).
	-- See LeaderboardController for why this is taller than it looks like it
	-- needs to be.
	local toggleButton = Widgets.Button("Shop", UDim2.fromOffset(130, 48), UDim2.new(1, -140, 0, 60))
	toggleButton.Parent = toggleGui

	-- Own ScreenGui + backdrop + close-X, not a bare Widgets.Panel toggled by
	-- this one button -- a panel closable ONLY via the button that opened it
	-- is a named player-facing complaint (no click-outside, no X). See
	-- Widgets.Modal's doc comment for the DisplayOrder/ZIndex reasoning too.
	panel, openPanel, closePanel = Widgets.Modal("Shop", UDim2.fromOffset(380, 440), UDim2.new(1, -390, 0, 116), {
		DisplayOrder = 30,
	})

	local title = Widgets.Label("TRAIL SHOP", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 6), {
		TextSize = 20,
	})
	title.Parent = panel

	rankLabel = Widgets.Label("", UDim2.new(0.6, -16, 0, 20), UDim2.fromOffset(8, 38), {
		TextSize = 15,
	})
	rankLabel.Parent = panel

	pointsLabel = Widgets.Label("", UDim2.new(0.4, -16, 0, 20), UDim2.new(0.6, 0, 0, 38), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Color.Warning,
	})
	pointsLabel.Parent = panel

	local vipButton = Widgets.Button("👑 Get VIP — 2x Points Everywhere", UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 62), {
		Variant = "Danger",
		TextSize = 14,
	})
	vipButton.Parent = panel
	vipButton.MouseButton1Click:Connect(function()
		Net.GetRemoteEvent(RemoteNames.PromptVIPPurchase):FireServer()
	end)

	local pointsHeader = Widgets.Label("GET POINTS", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 98), {
		TextSize = 12,
		Color = Theme.Color.TextMuted,
	})
	pointsHeader.Parent = panel

	local BUNDLE_WIDTH = 116
	for i, bundle in PointBundles do
		local bundleButton = Widgets.Button(
			bundle.Label .. " · R$",
			UDim2.fromOffset(BUNDLE_WIDTH, 34),
			UDim2.fromOffset(8 + (i - 1) * (BUNDLE_WIDTH + 8), 116),
			{ Variant = "Secondary", TextSize = 13 }
		)
		bundleButton.Parent = panel
		bundleButton.MouseButton1Click:Connect(function()
			Net.GetRemoteEvent(RemoteNames.PromptPointsPurchase):FireServer(bundle.RobuxProductId)
		end)
	end

	itemsList = Instance.new("ScrollingFrame")
	itemsList.Size = UDim2.new(1, -16, 1, -190)
	itemsList.Position = UDim2.fromOffset(8, 158)
	itemsList.BackgroundTransparency = 1
	itemsList.BorderSizePixel = 0
	itemsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	itemsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	itemsList.ScrollBarThickness = 5
	itemsList.ScrollBarImageColor3 = Theme.Color.AccentA
	itemsList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = itemsList

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			openPanel()
			ShopController.Refresh()
		end
	end)
end

function ShopController.Init()
	buildUI()

	-- Same class of bug as EmoteController: the R$ buy button only ever got
	-- PromptRobuxPurchase started server-side -- nothing here found out when
	-- the trail was actually granted, so "Buy" kept showing until the player
	-- closed and reopened the shop. PurchaseGranted (see PurchaseService)
	-- fires the moment the grant actually happens, not just when the dialog
	-- closes (ProcessReceipt can lag slightly behind that), so this can't
	-- show a stale "Buy" right after a purchase that already went through.
	Net.GetRemoteEvent(RemoteNames.PurchaseGranted).OnClientEvent:Connect(function()
		if panel.Visible then
			ShopController.Refresh()
		end
	end)

	-- VIP ownership is just an in-memory cache flip server-side (see
	-- MonetizationService), no DataStore write to lag behind, so trusting
	-- this prompt-finished event directly is safe here.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchasedPlayer: Player, _gamePassId: number, wasPurchased: boolean)
		if wasPurchased and purchasedPlayer == player and panel.Visible then
			ShopController.Refresh()
		end
	end)
end

return ShopController
