local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Shown while state == "Spectating" (see MatchService.PlayerReachedFinish /
-- LeaveSpectate): finishing/losing a race no longer yanks you straight back
-- to the lobby if others are still racing. The camera work here is just
-- Player.CameraSubject pointed at whichever racer is selected -- Roblox's
-- own built-in third-person camera (mouse orbit, zoom, smoothing, all of it)
-- then follows THAT Humanoid instead of your own, for free. No custom
-- camera-following code needed.
local SpectateController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local statusLabel: TextLabel
local racerRow: Frame

local currentRacers: { Player } = {}
local watchedPlayer: Player? = nil
local racerButtons: { [Player]: TextButton } = {}

local function ownHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Same green Widgets.Button's "Success" variant actually paints buttons with
-- (Theme.Color.Success is a brighter mint meant for TEXT on a dark panel,
-- not a button fill -- pairing it with light text here would repeat the
-- exact low-contrast mistake this game's buttons went through earlier).
local WATCHED_COLOR = Color3.fromRGB(45, 175, 100)

local function refreshButtonHighlights()
	for racer, button in racerButtons do
		button.BackgroundColor3 = if racer == watchedPlayer then WATCHED_COLOR else Theme.Color.PanelLight
	end
end

local function watch(target: Player)
	watchedPlayer = target
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- Humanoid might not exist for a split second around a respawn; falling
	-- back to the root part still gives Roblox's camera something valid to
	-- frame instead of silently doing nothing.
	player.CameraSubject = humanoid or (character and character:FindFirstChild("HumanoidRootPart"))
	refreshButtonHighlights()
end

local function restoreOwnCamera()
	watchedPlayer = nil
	player.CameraSubject = ownHumanoid()
end

local function buildRacerButton(racer: Player): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(110, 34)
	button.BackgroundColor3 = Theme.Color.PanelLight
	button.BorderSizePixel = 0
	button.Text = racer.Name
	button.Font = Theme.Font.Heading
	button.TextSize = 14
	button.TextColor3 = Theme.Color.TextPrimary
	button.AutoButtonColor = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	button.MouseButton1Click:Connect(function()
		watch(racer)
	end)

	return button
end

local function refreshRacerRow()
	for racer, button in racerButtons do
		if not table.find(currentRacers, racer) then
			button:Destroy()
			racerButtons[racer] = nil
		end
	end

	for i, racer in currentRacers do
		local button = racerButtons[racer]
		if not button then
			button = buildRacerButton(racer)
			button.Parent = racerRow
			racerButtons[racer] = button
		end
		button.LayoutOrder = i
	end

	refreshButtonHighlights()
end

local function onSpectateStatus(racers: { Player })
	currentRacers = racers

	statusLabel.Text = if #racers == 1 then "1 racer still going" else ("%d racers still going"):format(#racers)

	-- Keep watching the same racer if they're still going; otherwise (they
	-- just finished/quit, or this is the first update) pick someone so the
	-- spectator always sees *something* rather than a frozen empty view.
	if not (watchedPlayer and table.find(racers, watchedPlayer)) then
		if racers[1] then
			watch(racers[1])
		end
	end

	refreshRacerRow()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SpectateGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Same slot RaceHudController's race timer panel uses -- "Racing" and
	-- "Spectating" are mutually exclusive states, so there's no overlap.
	panel = Widgets.Panel(UDim2.fromOffset(400, 130), UDim2.new(0.5, -200, 0, 56))
	panel.Parent = screenGui

	local title = Widgets.Label("SPECTATING", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 8), {
		TextSize = 15,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = panel

	statusLabel = Widgets.Label("Watching the finish...", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 30), {
		Font = Theme.Font.Heading,
		TextSize = 17,
		Align = Enum.TextXAlignment.Center,
	})
	statusLabel.Parent = panel

	local hint = Widgets.Label("Click a name to switch who you're watching:", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 58), {
		TextSize = 11,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	hint.Parent = panel

	racerRow = Instance.new("Frame")
	racerRow.Size = UDim2.new(1, -16, 0, 34)
	racerRow.Position = UDim2.fromOffset(8, 78)
	racerRow.BackgroundTransparency = 1
	racerRow.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = racerRow
end

function SpectateController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Spectating" then
			Widgets.Open(panel)
		else
			if panel.Visible then
				Widgets.Close(panel)
			end
			if watchedPlayer then
				restoreOwnCamera()
			end
			currentRacers = {}
		end
	end)

	Net.GetRemoteEvent(RemoteNames.SpectateStatus).OnClientEvent:Connect(onSpectateStatus)
end

return SpectateController
