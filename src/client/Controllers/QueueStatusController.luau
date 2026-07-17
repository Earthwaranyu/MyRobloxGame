local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)
local MatchStateController = require(script.Parent.MatchStateController)

local QueueStatusController = {}

local player = Players.LocalPlayer

local container: Frame
local numberLabel: TextLabel
local numberScale: UIScale
local goLabel: TextLabel
local goScale: UIScale

-- Server sends the remaining seconds once; ticking down locally avoids
-- relying on the client and server clocks (os.clock()) being in sync.
local endTime: number? = nil
local lastShownSecond: number? = nil

local function pulse(scale: UIScale)
	scale.Scale = 1.35
	TweenService:Create(scale, Theme.Anim.Pop, { Scale = 1 }):Play()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "QueueStatusGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 5
	screenGui.Parent = player:WaitForChild("PlayerGui")

	container = Instance.new("Frame")
	container.Name = "CountdownContainer"
	container.Size = UDim2.fromOffset(320, 130)
	container.Position = UDim2.new(0.5, -160, 0.22, 0)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = screenGui

	local caption = Widgets.Label("RACE STARTING IN", UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
		Align = Enum.TextXAlignment.Center,
	})
	caption.Parent = container

	numberLabel = Widgets.Label("", UDim2.new(1, 0, 0, 90), UDim2.fromOffset(0, 26), {
		Font = Theme.Font.Display,
		TextSize = 72,
		Color = Theme.Color.AccentB,
		Align = Enum.TextXAlignment.Center,
	})
	numberLabel.TextStrokeTransparency = 0.6
	numberLabel.Parent = container

	numberScale = Instance.new("UIScale")
	numberScale.Parent = numberLabel

	goLabel = Widgets.Label("GO!", UDim2.fromOffset(400, 120), UDim2.new(0.5, -200, 0.3, 0), {
		Font = Theme.Font.Display,
		TextSize = 90,
		Color = Theme.Color.Success,
		Align = Enum.TextXAlignment.Center,
	})
	goLabel.TextStrokeTransparency = 0.5
	goLabel.Visible = false
	goLabel.Parent = screenGui

	goScale = Instance.new("UIScale")
	goScale.Parent = goLabel

	RunService.RenderStepped:Connect(function()
		if not endTime then
			return
		end

		local remaining = endTime - os.clock()
		if remaining <= 0 then
			container.Visible = false
			endTime = nil
			lastShownSecond = nil
			return
		end

		local shownSecond = math.ceil(remaining)
		numberLabel.Text = tostring(shownSecond)
		if shownSecond ~= lastShownSecond then
			lastShownSecond = shownSecond
			pulse(numberScale)
			Sounds.Play("Tick")
		end
	end)
end

local function flashGo()
	goLabel.Visible = true
	goLabel.TextTransparency = 0
	goScale.Scale = 0.6
	Sounds.Play("Go")

	TweenService:Create(goScale, Theme.Anim.Pop, { Scale = 1.15 }):Play()
	task.delay(0.5, function()
		local fadeTween = TweenService:Create(goLabel, Theme.Anim.Smooth, { TextTransparency = 1 })
		fadeTween.Completed:Once(function()
			goLabel.Visible = false
			goLabel.TextTransparency = 0
		end)
		fadeTween:Play()
	end)
end

function QueueStatusController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	remote.OnClientEvent:Connect(function(secondsRemaining: number?)
		if not secondsRemaining then
			endTime = nil
			lastShownSecond = nil
			container.Visible = false
			return
		end

		endTime = os.clock() + secondsRemaining
		lastShownSecond = nil
		container.Visible = true
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" then
			flashGo()
		end
	end)
end

return QueueStatusController
