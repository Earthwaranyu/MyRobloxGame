local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- Racing is first-person, and Roblox locks the mouse cursor there for
-- camera look (see QuitMatchController), so clicking a picker tile isn't a
-- reliable way to fire an emote mid-race. Number keys 1-8 are the real
-- interaction path -- always live, panel open or not -- the panel is just a
-- browse/preview/buy surface for when the mouse IS free (lobby).
local KEY_TO_INDEX: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
}

local EmoteController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()
local ownedEmotes: { [string]: boolean } = {}
local tileLockLabels: { [string]: TextLabel } = {}

local function refreshOwnership()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	ownedEmotes = {}
	if profile and profile.OwnedEmotes then
		for _, id in profile.OwnedEmotes do
			ownedEmotes[id] = true
		end
	end

	for id, label in tileLockLabels do
		local emote
		for _, e in Emotes do
			if e.Id == id then
				emote = e
				break
			end
		end
		local locked = emote and emote.RobuxProductId and not ownedEmotes[id]
		label.Visible = locked == true
	end
end

local function isUnlocked(emote): boolean
	return emote.RobuxProductId == nil or ownedEmotes[emote.Id] == true
end

local function triggerEmote(emote)
	if isUnlocked(emote) then
		Net.GetRemoteEvent(RemoteNames.PlayEmote):FireServer(emote.Id)
	else
		Net.GetRemoteEvent(RemoteNames.PromptEmotePurchase):FireServer(emote.Id)
	end
end

local function buildTile(emote, index: number): Frame
	local tile = Instance.new("Frame")
	tile.Name = "Tile_" .. emote.Id
	tile.Size = UDim2.fromOffset(84, 84)
	tile.BackgroundColor3 = Theme.Color.PanelLight
	tile.BorderSizePixel = 0
	tile.LayoutOrder = index

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = tile

	local button = Instance.new("TextButton")
	button.BackgroundTransparency = 1
	button.Size = UDim2.fromScale(1, 1)
	button.Text = ""
	button.Parent = tile

	local icon = Instance.new("TextLabel")
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(0.62, 0.62)
	icon.Position = UDim2.fromScale(0.19, 0.08)
	icon.Text = emote.Icon
	icon.TextScaled = true
	icon.Font = Theme.Font.Body
	icon.Parent = tile

	local keyLabel = Widgets.Label(tostring(index), UDim2.fromOffset(20, 16), UDim2.fromOffset(6, 4), {
		TextSize = 13,
		Color = Theme.Color.TextMuted,
	})
	keyLabel.Parent = tile

	local lockLabel = Widgets.Label("R$", UDim2.new(1, -12, 0, 18), UDim2.new(0, 0, 1, -22), {
		TextSize = 13,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Warning,
	})
	lockLabel.Visible = false
	lockLabel.Parent = tile
	tileLockLabels[emote.Id] = lockLabel

	button.MouseButton1Click:Connect(function()
		triggerEmote(emote)
	end)

	return tile
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "EmoteGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local toggleButton = Widgets.Button("Emotes", UDim2.fromOffset(140, 48), UDim2.fromOffset(240, 60))
	toggleButton.Parent = screenGui

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	panel, openPanel, closePanel = Widgets.Modal("Emote", UDim2.fromOffset(400, 210), UDim2.new(0.5, -200, 0, 116), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("EMOTES", UDim2.fromOffset(180, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	local hint = Widgets.Label("Press 1-8 anytime", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 6), {
		TextSize = 12,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	hint.Parent = panel

	local grid = Instance.new("Frame")
	grid.Size = UDim2.new(1, -16, 1, -36)
	grid.Position = UDim2.fromOffset(8, 32)
	grid.BackgroundTransparency = 1
	grid.Parent = panel

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(84, 84)
	layout.CellPadding = UDim2.fromOffset(10, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	for i, emote in Emotes do
		buildTile(emote, i).Parent = grid
	end

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			refreshOwnership()
			openPanel()
		end
	end)
end

function EmoteController.Init()
	buildUI()
	refreshOwnership()

	-- Ownership only used to get re-checked when the panel was opened, so a
	-- purchase completing while it was already open (or between opens) left
	-- the lock icon showing until the player closed and reopened the panel
	-- themselves. PurchaseGranted (see PurchaseService) fires the moment the
	-- server actually grants it -- not just when the purchase dialog closes,
	-- which can happen slightly before the grant if refreshing off that
	-- instead -- so this can't show stale "still locked" right after buying.
	Net.GetRemoteEvent(RemoteNames.PurchaseGranted).OnClientEvent:Connect(refreshOwnership)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		local index = KEY_TO_INDEX[input.KeyCode]
		local emote = index and Emotes[index]
		if emote then
			triggerEmote(emote)
		end
	end)
end

return EmoteController
