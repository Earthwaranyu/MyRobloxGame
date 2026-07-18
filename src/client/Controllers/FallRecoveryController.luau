local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Stages are elevated (see Stages.luau difficulty tiers), so missing a jump
-- teleports the racer back to their last checkpoint server-side
-- (MatchService.PlayerFellOff); this is just the "why did I just move" cue.
local FallRecoveryController = {}

local player = Players.LocalPlayer

local toast: TextLabel

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FallRecoveryGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 6
	screenGui.Parent = player:WaitForChild("PlayerGui")

	toast = Widgets.Label("OOPS! Back to checkpoint", UDim2.fromOffset(400, 40), UDim2.new(0.5, -200, 0.34, 0), {
		Font = Theme.Font.Heading,
		TextSize = 22,
		Color = Theme.Color.Warning,
		Align = Enum.TextXAlignment.Center,
	})
	toast.TextStrokeColor3 = Color3.new(0, 0, 0)
	toast.TextStrokeTransparency = 0.3
	toast.TextTransparency = 1
	toast.Parent = screenGui
end

local function flashToast()
	Sounds.Play("Fall")
	toast.TextTransparency = 0
	TweenService:Create(toast, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
	}):Play()
end

function FallRecoveryController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.PlayerFell)
	remote.OnClientEvent:Connect(flashToast)
end

return FallRecoveryController
