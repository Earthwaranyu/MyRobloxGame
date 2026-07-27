local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
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

local function refresh(state: string)
	button.Visible = isActive()
	button.Text = if state == "Spectating" then "Stop Watching (Backspace)" else "Leave Match (Backspace)"
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

	-- Sits just right of RaceHudController's timer panel (240 wide, centered).
	button = Widgets.Button("Leave Match (Backspace)", UDim2.fromOffset(230, 48), UDim2.new(0.5, 140, 0, 56), {
		Variant = "Danger",
		TextSize = 15,
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Exit", color)
		end,
	})
	button.Visible = false
	button.Parent = screenGui

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
