local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)
local Weather = require(Shared.Weather)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local MobileMenu = require(script.Parent.Parent.MobileMenu)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- The private-server host panel (see HostControlService for what it is for and
-- why it is only these three controls).
--
-- Built ONLY for the owner of a private server, and not at all anywhere else.
-- A disabled or hidden button that everyone can see would advertise the
-- feature to people who cannot use it every time they open the lobby, which is
-- a worse advert than the store page -- and in a public server the panel would
-- be permanently dead. So the controller asks once, and stops if the answer is
-- no.
local HostControlsController = {}

local player = Players.LocalPlayer

local TOGGLE_WIDTH, TOGGLE_HEIGHT = 140, 48
local TOGGLE_X, TOGGLE_Y = 240, 200

local PANEL_WIDTH, PANEL_HEIGHT = 460, 470
local PANEL_PAD = 18
local RIBBON_WIDTH, RIBBON_HEIGHT = 200, 44

local SECTION_TEXT = 15
local OPTION_HEIGHT = 40
local OPTION_GAP = 8

-- Current server-wide setting, mirrored from HostControlsChanged so the
-- selected option can be highlighted. Nil means "whatever the game would
-- normally do", which is a real, selectable choice here rather than an absence.
local current: { StageId: string?, Weather: string? } = { StageId = nil, Weather = nil }

local stageButtons: { [string]: (boolean) -> () } = {}
local weatherButtons: { [string]: (boolean) -> () } = {}

-- "Random" and "Default" are keyed under this rather than under nil, because a
-- table cannot be keyed by nil and those two options need to be highlightable
-- exactly like the others.
local NONE_KEY = "\0none"

local function refreshSelection()
	for key, setSelected in stageButtons do
		setSelected(key == (current.StageId or NONE_KEY))
	end
	for key, setSelected in weatherButtons do
		setSelected(key == (current.Weather or NONE_KEY))
	end
end

-- One row of choices. Returns the y the caller should continue below.
--
-- Selection is shown by recolouring rather than by a tick or a border: the
-- buttons are small and a marker inside one would compete with its label,
-- while the whole row recolouring at once reads instantly at a glance.
local function buildRow(
	parent: GuiObject,
	title: string,
	y: number,
	options: { { Key: string, Label: string } },
	registry: { [string]: (boolean) -> () },
	onPick: (string?) -> ()
): number
	local heading = Widgets.Label(title, UDim2.new(1, -PANEL_PAD * 2, 0, 20), UDim2.fromOffset(PANEL_PAD, y), {
		TextSize = SECTION_TEXT,
		Color = Theme.Color.TextMuted,
	})
	heading.Parent = parent
	y += 26

	local perRow = 3
	local usable = PANEL_WIDTH - PANEL_PAD * 2
	local width = (usable - OPTION_GAP * (perRow - 1)) / perRow

	for index, option in options do
		local column = (index - 1) % perRow
		local row = math.floor((index - 1) / perRow)
		local button, setActive = Widgets.Button(
			option.Label,
			UDim2.fromOffset(width, OPTION_HEIGHT),
			UDim2.fromOffset(PANEL_PAD + column * (width + OPTION_GAP), y + row * (OPTION_HEIGHT + OPTION_GAP)),
			{ TextSize = 14, Variant = "Secondary" }
		)
		button.Parent = parent

		-- Widgets.Button's own setActive, which swaps the Primary and Secondary
		-- palettes. Reused as-is so a selected option here looks exactly like
		-- every other active control in the game rather than inventing a second
		-- visual language for the same idea.
		registry[option.Key] = setActive

		button.MouseButton1Click:Connect(function()
			onPick(if option.Key == NONE_KEY then nil else option.Key)
		end)
	end

	local rows = math.ceil(#options / perRow)
	return y + rows * (OPTION_HEIGHT + OPTION_GAP) + 10
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HostControlsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local toggleButton =
		Widgets.Button("Host", UDim2.fromOffset(TOGGLE_WIDTH, TOGGLE_HEIGHT), UDim2.fromOffset(TOGGLE_X, TOGGLE_Y), {
			Icon = function(holder, color)
				MenuIcons.Populate(holder, "Settings", color)
			end,
		})
	toggleButton.Parent = screenGui
	Widgets.BindRail(toggleButton, TOGGLE_WIDTH, TOGGLE_HEIGHT, 3, "Left", TOGGLE_X)
	-- 8 because 1-7 are already claimed (Settings, mute, Invite, Profile,
	-- Inventory, Party, Gacha) and the drawer sorts on this number.
	MobileMenu.Adopt(toggleButton, 8)

	local panel, openPanel, closePanel = Widgets.Modal(
		"Host",
		UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		UDim2.new(0.5, -PANEL_WIDTH / 2, 0, 90),
		{ DisplayOrder = 30 }
	)

	local ribbon = Widgets.Ribbon(
		"HOST CONTROLS",
		UDim2.fromOffset(RIBBON_WIDTH, RIBBON_HEIGHT),
		UDim2.new(0.5, 0, 0, -RIBBON_HEIGHT / 2)
	)
	ribbon.Parent = panel

	local y = Widgets.ModalContentTop(PANEL_PAD)

	local hint = Widgets.Label(
		"Your server, your rules. Races here don't count for rank.",
		UDim2.new(1, -PANEL_PAD * 2, 0, 18),
		UDim2.fromOffset(PANEL_PAD, y),
		{ TextSize = 13, Color = Theme.Color.TextMuted, Align = Enum.TextXAlignment.Center }
	)
	hint.Parent = panel
	y += 26

	local stageOptions = { { Key = NONE_KEY, Label = "Random" } }
	for _, stage in Stages do
		table.insert(stageOptions, { Key = stage.Id, Label = stage.Name })
	end
	y = buildRow(panel, "STAGE", y, stageOptions, stageButtons, function(value)
		Net.GetRemoteEvent(RemoteNames.SetHostControl):FireServer("StageId", value)
	end)

	local weatherOptions = { { Key = NONE_KEY, Label = "Default" } }
	for _, name in Weather.PresetOrder do
		table.insert(weatherOptions, { Key = name, Label = name })
	end
	y = buildRow(panel, "WEATHER", y, weatherOptions, weatherButtons, function(value)
		Net.GetRemoteEvent(RemoteNames.SetHostControl):FireServer("Weather", value)
	end)

	local startButton = Widgets.Button(
		"START RACE NOW",
		UDim2.new(1, -PANEL_PAD * 2, 0, 46),
		UDim2.fromOffset(PANEL_PAD, y + 4),
		{ TextSize = 16, Variant = "Success" }
	)
	startButton.Parent = panel
	startButton.MouseButton1Click:Connect(function()
		Net.GetRemoteEvent(RemoteNames.StartRaceNow):FireServer()
		-- Closed here rather than left to the player. Unlike the stage and
		-- weather buttons -- which they may well want to press several of --
		-- this one ends the reason to be looking at the panel, and the map
		-- reveal it triggers plays behind it. Leaving it up hid the very thing
		-- the button had just started.
		closePanel()
	end)

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			openPanel()
		end
	end)
	MobileMenu.ReopenWhenClosed(toggleButton, panel)

	refreshSelection()
end

function HostControlsController.Init()
	-- Everyone gets told the settings, host or not, so a guest's client applies
	-- nothing but stays in step if it ever needs to show them. Connected before
	-- the ownership check so the very first broadcast cannot be missed.
	Net.GetRemoteEvent(RemoteNames.HostControlsChanged).OnClientEvent:Connect(function(settings)
		if typeof(settings) == "table" then
			current = settings
			refreshSelection()
		end
	end)

	task.spawn(function()
		local info = Net.GetRemoteFunction(RemoteNames.GetHostControls):InvokeServer()
		if typeof(info) ~= "table" or not info.Enabled or not info.IsHost then
			return
		end
		if typeof(info.Settings) == "table" then
			current = info.Settings
		end
		buildUI()
	end)
end

return HostControlsController
