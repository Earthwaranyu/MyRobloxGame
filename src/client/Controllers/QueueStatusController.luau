local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Widgets = require(script.Parent.Parent.Widgets)

local QueueStatusController = {}

local player = Players.LocalPlayer
local label: TextLabel

-- Server sends the remaining seconds once; ticking down locally avoids
-- relying on the client and server clocks (os.clock()) being in sync.
local endTime: number? = nil

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "QueueStatusGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	label = Widgets.Label("", UDim2.fromOffset(320, 32), UDim2.new(0.5, -160, 0, 60))
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 20
	label.Visible = false
	label.Parent = screenGui

	RunService.RenderStepped:Connect(function()
		if not endTime then
			return
		end

		local remaining = endTime - os.clock()
		if remaining <= 0 then
			label.Visible = false
			endTime = nil
			return
		end

		label.Text = ("Race starting in %ds"):format(math.ceil(remaining))
	end)
end

function QueueStatusController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	remote.OnClientEvent:Connect(function(secondsRemaining: number?)
		if not secondsRemaining then
			endTime = nil
			label.Visible = false
			return
		end

		endTime = os.clock() + secondsRemaining
		label.Visible = true
	end)
end

return QueueStatusController
