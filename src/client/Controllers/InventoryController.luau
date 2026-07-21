local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Net = require(Shared.Net)
local RarityColors = require(Shared.RarityColors)
local RemoteNames = require(Shared.RemoteNames)

local AbilityIcons = require(script.Parent.Parent.AbilityIcons)
local CategoryIcons = require(script.Parent.Parent.CategoryIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Standalone "which ability is equipped" panel -- used to live as the
-- Inventory tab inside GachaController's own panel, split out into its own
-- HUD button so equipping doesn't require detouring through the gacha-pull
-- panel to get there.
local InventoryController = {}

local player = Players.LocalPlayer
local RARITY_COLOR = RarityColors

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()
local abilityList: ScrollingFrame

-- Same row look GachaController's old Inventory tab used -- swatch + icon +
-- name/status + an Equip button (or a locked marker if not owned yet), one
-- per ability in Abilities.luau.
local function buildAbilityRow(info: Abilities.AbilityInfo, profile): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 58)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.new(0, 6, 1, -12)
	swatch.Position = UDim2.fromOffset(6, 6)
	swatch.BackgroundColor3 = RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted
	swatch.BorderSizePixel = 0
	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(1, 0)
	swatchCorner.Parent = swatch
	swatch.Parent = row

	local owned = table.find(profile.OwnedAbilities, info.Id) ~= nil
	local equipped = profile.EquippedAbility == info.Id

	-- Sits in the gap between the rarity swatch and the name text -- same
	-- rationale as the gacha reel card's icon.
	local icon = AbilityIcons.Create(info.Id, 40, UDim2.fromOffset(16, 9), RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted)
	icon.Parent = row

	local nameLabel = Widgets.Label(info.Name, UDim2.new(0.55, -62, 0, 22), UDim2.fromOffset(64, 6), {
		TextSize = 16,
	})
	nameLabel.Parent = row

	local subText
	if equipped then
		subText = "Equipped"
	elseif owned then
		subText = "Owned"
	elseif info.PullWeight then
		subText = ("%s  ·  %d%% pull odds"):format(info.Rarity, info.PullWeight)
	else
		subText = info.Rarity
	end

	local subLabel = Widgets.Label(subText, UDim2.new(0.55, -62, 0, 18), UDim2.fromOffset(64, 30), {
		TextSize = 13,
		Bold = false,
		Color = if equipped
			then Theme.Color.Success
			elseif owned then Theme.Color.TextSecondary
			else RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted,
	})
	subLabel.Parent = row

	if owned then
		local actionButton = Widgets.Button(if equipped then "Equipped" else "Equip", UDim2.fromScale(0.32, 0.66), UDim2.fromScale(0.65, 0.17), {
			Variant = if equipped then "Success" else "Primary",
			TextSize = 14,
		})
		actionButton.Parent = row
		if equipped then
			actionButton.Active = false
			actionButton.AutoButtonColor = false
		else
			actionButton.MouseButton1Click:Connect(function()
				local success = Net.GetRemoteFunction(RemoteNames.EquipAbility):InvokeServer(info.Id)
				if success then
					InventoryController.Refresh()
				end
			end)
		end
	else
		local lockedLabel = Widgets.Label("🔒 Locked", UDim2.fromScale(0.32, 0.66), UDim2.fromScale(0.65, 0.17), {
			TextSize = 14,
			Align = Enum.TextXAlignment.Center,
			Color = Theme.Color.TextMuted,
		})
		lockedLabel.Parent = row
	end

	return row
end

-- Re-fetches the profile fresh every time (same reasoning GachaController's
-- own Refresh has -- ownership/equip can change from a gacha pull that
-- happened while this panel wasn't even open), so this only ever needs
-- calling right as the panel opens, not kept live-synced while closed.
function InventoryController.Refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	for _, child in abilityList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for i, info in Abilities do
		local row = buildAbilityRow(info, profile)
		row.LayoutOrder = i
		row.Parent = abilityList
	end
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "InventoryGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Directly below LeaderboardController's toggle button (same X, same
	-- 8px-gap-below-a-48px-button convention used throughout this stack),
	-- and to the left of PartyController's toggle (same row).
	local toggleButton = Widgets.Button("Inventory", UDim2.fromOffset(220, 48), UDim2.fromOffset(10, 116), {
		-- Reuses the same icon the old Inventory tab drew in its tab strip
		-- (see CategoryIcons) -- same concept, no need for a second icon.
		Icon = function(holder, color)
			CategoryIcons.Populate(holder, "Inventory", holder.Size.X.Offset, color)
		end,
	})
	toggleButton.Parent = screenGui

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	panel, openPanel, closePanel = Widgets.Modal("Inventory", UDim2.fromOffset(380, 480), UDim2.new(0.5, -190, 0.5, -240), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("INVENTORY", UDim2.fromOffset(220, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	abilityList = Instance.new("ScrollingFrame")
	abilityList.Size = UDim2.new(1, -16, 1, -60)
	abilityList.Position = UDim2.fromOffset(8, 52)
	abilityList.BackgroundTransparency = 1
	abilityList.BorderSizePixel = 0
	abilityList.CanvasSize = UDim2.new(0, 0, 0, 0)
	abilityList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	abilityList.ScrollBarThickness = 5
	abilityList.ScrollBarImageColor3 = Theme.Color.AccentA
	abilityList.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 6)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = abilityList

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			openPanel()
			InventoryController.Refresh()
		end
	end)
end

function InventoryController.Init()
	buildUI()
end

return InventoryController
