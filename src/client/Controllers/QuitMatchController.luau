local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

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
local active = false

local function quit()
	if not active then
		return
	end
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
	})
	button.Visible = false
	button.Parent = screenGui

	button.MouseButton1Click:Connect(quit)
end

function QuitMatchController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(function(state: string)
		active = state == "Racing" or state == "Spectating"
		button.Visible = active
		button.Text = if state == "Spectating" then "Stop Watching (Backspace)" else "Leave Match (Backspace)"
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= QUIT_KEY then
			return
		end
		quit()
	end)
end

return QuitMatchController
