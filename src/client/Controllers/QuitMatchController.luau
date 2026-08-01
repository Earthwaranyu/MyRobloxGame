local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Racing is first-person, and Roblox locks/hides the mouse cursor for camera
-- look in first-person, so a click-only button is unreachable while it
-- actually matters. Backspace is the real way out; the button just stays on
-- screen as a visible reminder of the key (and still works on the off
-- chance the cursor is free, e.g. an emote wheel or menu unlocked it).
-- Also doubles as "stop spectating" -- see MatchService.LeaveSpectate --
-- since a finished/spectating player has the exact same "get me out of
-- here" need, just without QuitMatch's Elo/streak implications (there are
-- none once you've already finished).
local QUIT_KEY = Enum.KeyCode.Backspace

-- Reference size, at the viewport the HUD was authored against. Responsive
-- scales both -- see layout() in buildUI.
local BASE_WIDTH = 230
local BASE_HEIGHT = 48

local QuitMatchController = {}

local player = Players.LocalPlayer

local button: TextButton
-- Set by the match state machine (Racing/Spectating).
local stateActive = false
-- Set independently for the pre-race countdown, which the state machine can't
-- express: the server doesn't flip anyone to "Racing" until the countdown
-- actually ends (see MatchService.beginRace), so for those
-- Constants.Match.CountdownSeconds you're teleported onto the stage, frozen in
-- place, and -- until now -- had no way out. The server side already accepted
-- a quit during that window (playerBusy is set from the moment you're
-- enqueued); it was only this client gate that made Backspace do nothing.
local countdownActive = false

local function isActive(): boolean
	return stateActive or countdownActive
end

-- The key hint is desktop-only, and not just to save width.
--
-- On a touch device there IS no Backspace, so "(Backspace)" told a phone player
-- to press a key their device does not have -- and on that device this button is
-- not a reminder of the real way out, it IS the only way out. The label reads as
-- an instruction either way; it just has to be a true one.
local function labelFor(state: string): string
	local action = if state == "Spectating" then "Stop Watching" else "Leave Match"
	if Responsive.IsTouch() then
		return action
	end
	return action .. " (Backspace)"
end

local function refresh(state: string)
	button.Visible = isActive()
	button.Text = labelFor(state)
end

local function quit()
	if not isActive() then
		return
	end
	countdownActive = false
	Net.GetRemoteEvent(RemoteNames.QuitMatch):FireServer()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "QuitMatchGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Beside the top-centre lane, clear of whichever card is in it. This used to
	-- be measured off RaceHudController's timer alone (240 wide), which is the
	-- neighbour once you are RACING -- but the button is on screen from the
	-- moment the pre-race countdown starts, and that neighbour is
	-- QueueStatusController's 300-wide card, so it was drawn over the card's
	-- right border for the whole countdown. Theme.TopLane.SideOffset is measured
	-- off the wider of the two.
	button = Widgets.Button(
		labelFor(MatchStateController.CurrentState),
		UDim2.fromOffset(BASE_WIDTH, BASE_HEIGHT),
		UDim2.new(0.5, Theme.TopLane.SideOffset, 0, Theme.TopLane.CardTop),
		{
			Variant = "Danger",
			TextSize = 15,
			Icon = function(holder, color)
				MenuIcons.Populate(holder, "Exit", color)
			end,
		}
	)
	button.Visible = false
	button.Parent = screenGui

	-- "Beside the lane" is a desktop layout, and on a phone it is off the screen.
	--
	-- The lane's card is 300 wide, so SideOffset puts this button's LEFT edge 182
	-- points right of centre and its right edge a further 230 out. That needs a
	-- viewport about 825 wide to land on screen at all; a phone in landscape is
	-- commonly 667. The button was simply not visible on the devices where it is
	-- the only way to leave a match.
	--
	-- So below the phone breakpoint it stops being a lane neighbour and moves
	-- under the lane, centred -- there is no room beside a card that is itself
	-- most of the screen width, and stacking is what the space allows.
	local function layout()
		local lane = Responsive.Lane(Theme)
		local width = Responsive.Px(BASE_WIDTH)
		-- Tap() rather than Px(): on touch this button is the entire exit path,
		-- so it holds the 44pt minimum even when everything around it shrinks.
		local height = Responsive.Tap(BASE_HEIGHT)

		if Responsive.Tier() == "Phone" then
			Widgets.Relayout(
				button,
				UDim2.fromOffset(width, height),
				UDim2.new(0.5, -width / 2, 0, lane.CardTop + lane.CardHeight + lane.Gap)
			)
		else
			Widgets.Relayout(button, UDim2.fromOffset(width, height), UDim2.new(0.5, lane.SideOffset, 0, lane.CardTop))
		end
	end
	Responsive.Observe(layout)

	button.MouseButton1Click:Connect(quit)
end

function QuitMatchController.Init()
	buildUI()

	-- The countdown either turns into a real race (state -> Racing, which
	-- takes over from here) or is over anyway, so clearing the flag on ANY
	-- state change is enough -- no separate timer to keep in sync with the
	-- server's own.
	Net.GetRemoteEvent(RemoteNames.PreRaceCountdown).OnClientEvent:Connect(function()
		countdownActive = true
		refresh(MatchStateController.CurrentState)
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		stateActive = state == "Racing" or state == "Spectating"
		countdownActive = false
		refresh(state)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= QUIT_KEY then
			return
		end
		quit()
	end)
end

return QuitMatchController
