local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Shown once automatically (server tells us via ShowTutorial the very first
-- time a fresh profile logs in) and re-openable anytime after that from
-- Settings -> "How to Play". Everything on this panel is otherwise only
-- discoverable by trial and error (sprint key, emote keys, quit key) -- a
-- brand-new player with zero explanation is exactly who churns in the first
-- 30 seconds.
local TutorialController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup

-- Reference geometry. PANEL_HEIGHT is now a MAXIMUM rather than a fixed size --
-- layoutPanel clamps it to the viewport and the rows scroll inside what's left.
local PANEL_WIDTH = 480
local PANEL_HEIGHT = 528
local PAD = 16
local TITLE_HEIGHT, TITLE_TEXT = 32, 24
local ROW_HEIGHT, ROW_GAP = 56, 4
local CLOSE_WIDTH, CLOSE_HEIGHT, CLOSE_TEXT = 260, 52, 18

-- Four of these six rows named a key -- SHIFT, Q, 1-8, Backspace -- which on a
-- touch device instructs the player to press something they do not have. This is
-- the game's ONLY explanation of its own controls, shown once on first join, on
-- a platform that skews heavily mobile: most of the players reading it were
-- being told to use a keyboard.
--
-- Each row carries both wordings and the right one is picked at build time. One
-- table rather than two, so a row can't be added for one platform and forgotten
-- on the other.
local ROWS = {
	{ Icon = "🏁", Title = "Race to win", Body = "Tap PLAY to race real players, or VS BOTS to practice solo." },
	{ Icon = "🏃", Title = "Hold SHIFT to sprint", TouchTitle = "Tap SPRINT to run", Body = "You'll need it to clear the harder jumps." },
	{ Icon = "💨", Title = "Press Q to dash", TouchTitle = "Tap DASH for a burst", Body = "A short burst of speed on a cooldown -- save it for a tricky jump." },
	{ Icon = "🏆", Title = "Elo & Points", Body = "Win real races for Elo and rank up. Points buy trails in the Shop." },
	{ Icon = "😀", Title = "Emotes", Body = "Press 1-8 anytime to show one off, even mid-race.", TouchBody = "Open Emotes and tap one to show it off, even mid-race." },
	{ Icon = "🚪", Title = "Need to bail?", Body = "Press Backspace anytime to leave a match.", TouchBody = "Tap Leave Match at the top of the screen to bail out." },
}

local function rowTitle(row): string
	return if Responsive.IsTouch() and row.TouchTitle then row.TouchTitle else row.Title
end

local function rowBody(row): string
	return if Responsive.IsTouch() and row.TouchBody then row.TouchBody else row.Body
end

local function buildRow(container: Frame, row, layoutOrder: number)
	local px, tx = Responsive.Px, Responsive.Text

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, px(ROW_HEIGHT))
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = layoutOrder
	frame.Parent = container

	local icon = Widgets.Label(row.Icon, UDim2.fromOffset(px(40), px(40)), UDim2.fromOffset(0, px(8)), {
		TextSize = tx(26),
		Align = Enum.TextXAlignment.Center,
	})
	icon.Parent = frame

	local title = Widgets.Label(rowTitle(row), UDim2.new(1, -px(52), 0, px(22)), UDim2.fromOffset(px(52), px(2)), {
		Font = Theme.Font.Heading,
		TextSize = tx(17),
	})
	title.Parent = frame

	local body = Widgets.Label(rowBody(row), UDim2.new(1, -px(52), 0, px(28)), UDim2.fromOffset(px(52), px(24)), {
		TextSize = tx(14),
		Color = Theme.Color.TextSecondary,
	})
	body.TextWrapped = true
	body.Parent = frame

	return frame
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TutorialGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 20
	screenGui.Parent = player:WaitForChild("PlayerGui")

	panel = Widgets.Panel(UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2))
	panel.Parent = screenGui

	local title = Widgets.Label("WELCOME TO THE RACE!", UDim2.new(1, -PAD * 2, 0, TITLE_HEIGHT), UDim2.fromOffset(PAD, PAD), {
		Font = Theme.Font.Display,
		TextSize = TITLE_TEXT,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.Warning,
	})
	title.Parent = panel

	-- A ScrollingFrame, where this used to be a plain Frame with a fixed 360pt
	-- height. That fixed height is why the panel had to be 528 tall, and 528 does
	-- not fit a phone -- the panel ran off BOTH edges of a 375pt viewport, taking
	-- the title off the top and the dismiss button off the bottom. Since this is
	-- a plain Panel with no backdrop, no click-outside and no auto-close, that
	-- left a first-time player on a phone with a tutorial they could not read and
	-- could not close.
	--
	-- Scrolling is what decouples "how much text there is" from "how tall the
	-- screen is", so the panel can now be sized to the viewport and the rows
	-- simply scroll inside whatever is left. Adding a seventh row can never push
	-- the button off the screen again.
	local rowsContainer = Instance.new("ScrollingFrame")
	rowsContainer.Size = UDim2.new(1, -PAD * 2, 1, -(TITLE_HEIGHT + PAD * 2 + CLOSE_HEIGHT + PAD * 2))
	rowsContainer.Position = UDim2.fromOffset(PAD, TITLE_HEIGHT + PAD * 2)
	rowsContainer.BackgroundTransparency = 1
	rowsContainer.BorderSizePixel = 0
	rowsContainer.CanvasSize = UDim2.new()
	rowsContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rowsContainer.ScrollBarThickness = 4
	rowsContainer.ScrollingDirection = Enum.ScrollingDirection.Y
	rowsContainer.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_GAP)
	layout.Parent = rowsContainer

	for i, row in ROWS do
		buildRow(rowsContainer, row, i)
	end

	local closeButton = Widgets.Button(
		"GOT IT, LET'S GO!",
		UDim2.fromOffset(CLOSE_WIDTH, CLOSE_HEIGHT),
		UDim2.new(0.5, -CLOSE_WIDTH / 2, 1, -(CLOSE_HEIGHT + PAD))
	, {
		Variant = "Success",
		TextSize = CLOSE_TEXT,
	})
	closeButton.Parent = panel
	closeButton.MouseButton1Click:Connect(function()
		Widgets.Close(panel)
	end)

	local function layoutPanel()
		local px = Responsive.Px
		local pad = px(PAD)
		local titleHeight = px(TITLE_HEIGHT)
		local closeHeight = Responsive.Tap(CLOSE_HEIGHT)

		-- Width can simply scale; height is clamped to what the screen can show.
		local width = math.min(px(PANEL_WIDTH), Responsive.ViewportSize().X - Responsive.ScreenMargin * 2)
		local height = Responsive.FitHeight(PANEL_HEIGHT, Responsive.ScreenMargin)
		local x = Responsive.ClampX(math.round((Responsive.ViewportSize().X - width) / 2), width)
		local y = Responsive.ClampY(math.round((Responsive.ViewportSize().Y - height) / 2), height)

		panel.Size = UDim2.fromOffset(width, height)
		panel.Position = UDim2.fromOffset(x, y)

		title.Size = UDim2.new(1, -pad * 2, 0, titleHeight)
		title.Position = UDim2.fromOffset(pad, pad)
		title.TextSize = Responsive.Text(TITLE_TEXT)

		rowsContainer.Size = UDim2.new(1, -pad * 2, 1, -(titleHeight + pad * 2 + closeHeight + pad * 2))
		rowsContainer.Position = UDim2.fromOffset(pad, titleHeight + pad * 2)
		layout.Padding = UDim.new(0, px(ROW_GAP))

		local closeWidth = px(CLOSE_WIDTH)
		Widgets.Relayout(
			closeButton,
			UDim2.fromOffset(closeWidth, closeHeight),
			UDim2.new(0.5, -closeWidth / 2, 1, -(closeHeight + pad))
		)

		-- Rows carry their own scaled internals, so they are rebuilt rather than
		-- re-measured -- same reasoning as PlayModePickerController.
		for _, child in rowsContainer:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for i, row in ROWS do
			buildRow(rowsContainer, row, i)
		end
	end
	Responsive.Observe(layoutPanel)
end

function TutorialController.Show()
	Sounds.Play("Purchase")
	Widgets.Open(panel)
end

function TutorialController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.ShowTutorial)
	remote.OnClientEvent:Connect(TutorialController.Show)
end

return TutorialController
