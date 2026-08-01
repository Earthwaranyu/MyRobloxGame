local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Responsive = require(script.Parent.Parent.Responsive)
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

-- Reference geometry -- see Responsive, which scales these rather than wrapping
-- the panel in a UIScale.
local TILE_SIZE = 84
local TILE_GAP = 10
local KEY_LABEL_WIDTH, KEY_LABEL_HEIGHT, KEY_LABEL_INSET, KEY_TEXT = 20, 16, 6, 13
local LOCK_HEIGHT, LOCK_TEXT = 18, 13
local TOGGLE_WIDTH, TOGGLE_HEIGHT = 140, 48
local TOGGLE_X, TOGGLE_Y = 240, 60
local PANEL_WIDTH, PANEL_HEIGHT, PANEL_TOP = 400, 210, 116
local RIBBON_WIDTH, RIBBON_HEIGHT = 180, 40
local PANEL_PAD = 8
local HINT_HEIGHT, HINT_TOP, HINT_TEXT = 16, 6, 12
local GRID_TOP = 32

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
	-- Sized by the grid's CellSize, which layout() keeps current -- this is just
	-- the initial value so a tile is never briefly the wrong size.
	tile.Size = UDim2.fromOffset(Responsive.Tap(TILE_SIZE), Responsive.Tap(TILE_SIZE))
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

	-- The little "3" in the corner is the keyboard shortcut, so it is meaningless
	-- on a device with no number row -- and worse than meaningless on a tile
	-- small enough that the digit competes with the emote glyph for space.
	local keyLabel = Widgets.Label(
		tostring(index),
		UDim2.fromOffset(Responsive.Px(KEY_LABEL_WIDTH), Responsive.Px(KEY_LABEL_HEIGHT)),
		UDim2.fromOffset(Responsive.Px(KEY_LABEL_INSET), Responsive.Px(4)),
		{
			TextSize = Responsive.Text(KEY_TEXT),
			Color = Theme.Color.TextMuted,
		}
	)
	keyLabel.Visible = not Responsive.IsTouch()
	keyLabel.Parent = tile

	local lockLabel = Widgets.Label("R$", UDim2.new(1, -12, 0, Responsive.Px(LOCK_HEIGHT)), UDim2.new(0, 0, 1, -22), {
		TextSize = Responsive.Text(LOCK_TEXT),
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

	local toggleButton =
		Widgets.Button("Emotes", UDim2.fromOffset(TOGGLE_WIDTH, TOGGLE_HEIGHT), UDim2.fromOffset(TOGGLE_X, TOGGLE_Y), {
			Icon = function(holder, color)
				MenuIcons.Populate(holder, "Emotes", color)
			end,
		})
	toggleButton.Parent = screenGui
	Widgets.BindRail(toggleButton, 140, 48, 1, "Left", 240)

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	panel, openPanel, closePanel = Widgets.Modal(
		"Emote",
		UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		UDim2.new(0.5, -PANEL_WIDTH / 2, 0, PANEL_TOP),
		{ DisplayOrder = 30 }
	)

	local ribbon = Widgets.Ribbon(
		"EMOTES",
		UDim2.fromOffset(RIBBON_WIDTH, RIBBON_HEIGHT),
		UDim2.new(0.5, 0, 0, -RIBBON_HEIGHT / 2)
	)
	ribbon.Parent = panel

	-- "Press 1-8 anytime" is a keyboard instruction. On touch there is no number
	-- row, so it described a control the player does not have -- and on touch the
	-- tiles are not merely a "browse surface" (see the module header) but the only
	-- way to fire an emote at all, which is worth saying instead.
	local hintText = if Responsive.IsTouch() then "Tap an emote to play it" else "Press 1-8 anytime"
	local hint =
		Widgets.Label(hintText, UDim2.new(1, -PANEL_PAD * 2, 0, HINT_HEIGHT), UDim2.fromOffset(PANEL_PAD, HINT_TOP), {
			TextSize = HINT_TEXT,
			Color = Theme.Color.TextMuted,
			Align = Enum.TextXAlignment.Center,
		})
	hint.Parent = panel

	-- Scrolls rather than being a fixed grid area. A UIGridLayout wraps onto new
	-- rows as emotes are added, and any row past the frame's height was simply
	-- invisible and unreachable -- the same failure that hid Stage 4 on the
	-- leaderboard, just on the vertical axis. AutomaticCanvasSize means the
	-- canvas tracks whatever the layout actually produces.
	local grid = Instance.new("ScrollingFrame")
	grid.Size = UDim2.new(1, -PANEL_PAD * 2, 1, -(GRID_TOP + 4))
	grid.Position = UDim2.fromOffset(PANEL_PAD, GRID_TOP)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = 4
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.Parent = panel

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(TILE_SIZE, TILE_SIZE)
	layout.CellPadding = UDim2.fromOffset(TILE_GAP, TILE_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	for i, emote in Emotes do
		buildTile(emote, i).Parent = grid
	end

	-- The panel is 400 wide at reference, which is most of a phone held in
	-- landscape, so it scales with everything else. The tiles are the exception
	-- that goes the other way: at 84 they are already comfortably above the touch
	-- minimum, and Tap() only stops the small-screen scale factor from taking
	-- them below it -- a grid of emotes is exactly the kind of thing that gets
	-- fat-fingered.
	--
	-- The grid reflows on its own once CellSize changes (UIGridLayout wraps, and
	-- AutomaticCanvasSize tracks the result), so narrow screens end up with fewer
	-- columns and more rows to scroll rather than a clipped row.
	local function relayout()
		-- Through PlacePanel rather than sizing itself, so it picks up the phone
		-- floors: a hand-sized panel came out 16% of an 801x334 screen, leaving
		-- room for a single row of emotes on the device with the most screen to
		-- spare.
		local viewport = Responsive.ViewportSize()
		local panelWidth, panelHeight =
			Responsive.PlacePanel(panel, PANEL_WIDTH, PANEL_HEIGHT, 0, Responsive.Px(PANEL_TOP))
		panel.Position = UDim2.fromOffset(
			math.round((viewport.X - panelWidth) / 2),
			Responsive.ClampY(math.round((viewport.Y - panelHeight) / 2), panelHeight)
		)

		local ribbonHeight = Responsive.Px(RIBBON_HEIGHT)
		ribbon.Size = UDim2.fromOffset(Responsive.Px(RIBBON_WIDTH), ribbonHeight)
		ribbon.Position = UDim2.new(0.5, 0, 0, -ribbonHeight / 2)

		local pad = Responsive.Px(PANEL_PAD)
		local gridTop = Responsive.Px(GRID_TOP)
		hint.Size = UDim2.new(1, -pad * 2, 0, Responsive.Px(HINT_HEIGHT))
		hint.Position = UDim2.fromOffset(pad, Responsive.Px(HINT_TOP))
		hint.TextSize = Responsive.Text(HINT_TEXT)

		-- Below the modal's close button, not under it. The ✕ is anchored to the
		-- panel's top-right corner INSIDE the panel (a CanvasGroup clips, so it
		-- cannot straddle the edge), and the grid used to start above its bottom
		-- edge -- so the ✕ sat on top of the first row of emote tiles.
		local headerBottom = math.max(gridTop, Responsive.Tap(34) + pad * 2)
		grid.Size = UDim2.new(1, -pad * 2, 1, -(headerBottom + Responsive.Px(4)))
		grid.Position = UDim2.fromOffset(pad, headerBottom)

		local cell = Responsive.Tap(TILE_SIZE)
		layout.CellSize = UDim2.fromOffset(cell, cell)
		layout.CellPadding = UDim2.fromOffset(Responsive.Px(TILE_GAP), Responsive.Px(TILE_GAP))

		-- The toggle is owned by Widgets.BindRail (see buildUI). Two layout
		-- callbacks writing the same button's position fight, and which one wins
		-- depends on observer order -- that is how it ended up 3pt off the TOP of
		-- the screen on the emulator.
	end
	Responsive.Observe(relayout)

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
