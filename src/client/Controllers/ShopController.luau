local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local PointBundles = require(Shared.PointBundles)
local RemoteNames = require(Shared.RemoteNames)
local Trails = require(Shared.Trails)
local RankTiers = require(Shared.RankTiers)

local CategoryIcons = require(script.Parent.Parent.CategoryIcons)
local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

local ShopController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local pointsLabel: TextLabel
local rankLabel: TextLabel
local itemsList: ScrollingFrame
local vipButton: TextButton
local vipOwned = false

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

-- The button used to always say "Get VIP" and fire the SAME purchase prompt
-- forever, even for a player who already owns it -- clicking it just kept
-- re-opening Roblox's own purchase dialog with nothing in this UI ever
-- reflecting that they'd already bought it. Re-checked here (not just once
-- at Init) since MonetizationService's own ownership check is itself
-- asynchronous server-side.
local function refreshVipButton()
	local status = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()
	vipOwned = (status and status.HasVIP) or false

	if vipOwned then
		vipButton.Text = "👑 VIP Active — 2x Points Everywhere"
		vipButton.Active = false
		vipButton.AutoButtonColor = false
	else
		vipButton.Text = "👑 Get VIP — 2x Points Everywhere"
		vipButton.Active = true
		vipButton.AutoButtonColor = true
	end
end

function ShopController.Refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	refreshVipButton()

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
	local toggleButton = Widgets.Button("Shop", UDim2.fromOffset(130, 48), UDim2.new(1, -140, 0, 60), {
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Shop", color)
		end,
	})
	toggleButton.Parent = toggleGui

	-- Own ScreenGui + backdrop + close-X, not a bare Widgets.Panel toggled by
	-- this one button -- a panel closable ONLY via the button that opened it
	-- is a named player-facing complaint (no click-outside, no X). See
	-- Widgets.Modal's doc comment for the DisplayOrder/ZIndex reasoning too.
	local shopScreenGui: ScreenGui
	panel, openPanel, closePanel, _, shopScreenGui = Widgets.Modal("Shop", UDim2.fromOffset(380, 460), UDim2.new(1, -390, 0, 116), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("TRAIL SHOP", UDim2.fromOffset(220, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	rankLabel = Widgets.Label("", UDim2.new(0.6, -16, 0, 20), UDim2.fromOffset(8, 26), {
		TextSize = 15,
	})
	rankLabel.Parent = panel

	pointsLabel = Widgets.Label("", UDim2.new(0.4, -16, 0, 20), UDim2.new(0.6, 0, 0, 26), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Candy.Gold.Face,
	})
	pointsLabel.Parent = panel

	-- Left tab strip (Trails / Points), same reference-image category-strip
	-- layout language as GachaController's own tab strip -- see its doc
	-- comment for why this is scoped to switching between THIS panel's own
	-- sections rather than merging Shop/Gacha/Settings into one mega-panel.
	local tabStrip, _selectTab, onTabSelected = Widgets.TabStrip({
		{ Id = "Trails", BuildIcon = function(holder, color)
			CategoryIcons.Populate(holder, "Trails", holder.AbsoluteSize.X, color)
		end },
		{ Id = "Points", BuildIcon = function(holder, color)
			CategoryIcons.Populate(holder, "Points", holder.AbsoluteSize.X, color)
		end },
	}, UDim2.new(1, -462, 0, 168))
	tabStrip.Parent = shopScreenGui
	tabStrip.Visible = panel.Visible
	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		tabStrip.Visible = panel.Visible
	end)

	local trailsContent = Instance.new("Frame")
	trailsContent.Name = "TrailsContent"
	trailsContent.Size = UDim2.new(1, -16, 1, -54)
	trailsContent.Position = UDim2.fromOffset(8, 46)
	trailsContent.BackgroundTransparency = 1
	trailsContent.Parent = panel

	local pointsContent = Instance.new("Frame")
	pointsContent.Name = "PointsContent"
	pointsContent.Size = UDim2.new(1, -16, 1, -54)
	pointsContent.Position = UDim2.fromOffset(8, 46)
	pointsContent.BackgroundTransparency = 1
	pointsContent.Visible = false
	pointsContent.Parent = panel

	onTabSelected(function(id: string)
		trailsContent.Visible = id == "Trails"
		pointsContent.Visible = id == "Points"
	end)

	vipButton = Widgets.Button("👑 Get VIP — 2x Points Everywhere", UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 0), {
		Variant = "Danger",
		TextSize = 14,
	})
	vipButton.Parent = pointsContent
	vipButton.MouseButton1Click:Connect(function()
		if not vipOwned then
			Net.GetRemoteEvent(RemoteNames.PromptVIPPurchase):FireServer()
		end
	end)

	local pointsHeader = Widgets.Label("GET POINTS", UDim2.new(1, 0, 0, 16), UDim2.fromOffset(0, 40), {
		TextSize = 12,
		Color = Theme.Color.TextMuted,
	})
	pointsHeader.Parent = pointsContent

	local BUNDLE_WIDTH = 108
	for i, bundle in PointBundles do
		local bundleButton = Widgets.Button(
			bundle.Label .. " · R$",
			UDim2.fromOffset(BUNDLE_WIDTH, 34),
			UDim2.fromOffset((i - 1) * (BUNDLE_WIDTH + 8), 58),
			{ Variant = "Secondary", TextSize = 13 }
		)
		bundleButton.Parent = pointsContent
		bundleButton.MouseButton1Click:Connect(function()
			Net.GetRemoteEvent(RemoteNames.PromptPointsPurchase):FireServer(bundle.RobuxProductId)
		end)
	end

	itemsList = Instance.new("ScrollingFrame")
	itemsList.Size = UDim2.new(1, 0, 1, 0)
	itemsList.Position = UDim2.fromOffset(0, 0)
	itemsList.BackgroundTransparency = 1
	itemsList.BorderSizePixel = 0
	itemsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	itemsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	itemsList.ScrollBarThickness = 5
	itemsList.ScrollBarImageColor3 = Theme.Color.AccentA
	itemsList.Parent = trailsContent

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

	-- NOT MarketplaceService.PromptGamePassPurchaseFinished directly -- that
	-- fires independently on the client and the server, with no guaranteed
	-- ordering against the server actually updating its own ownedCache (see
	-- MonetizationService's doc comment on statusChangedRemote). This remote
	-- only fires AFTER that cache write, so refreshVipButton here can never
	-- read a stale "not owned" result. Runs regardless of panel.Visible (the
	-- button still exists, just off-screen) so it's correct the moment the
	-- panel is next opened even if the purchase happened while it was closed.
	Net.GetRemoteEvent(RemoteNames.MonetizationStatusChanged).OnClientEvent:Connect(refreshVipButton)
end

return ShopController
