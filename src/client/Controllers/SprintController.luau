local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Signal = require(Shared.Signal)

local SprintController = {}

-- Exposed so purely cosmetic client features (wind effect, etc.) can react
-- to sprinting without re-implementing shift-key detection themselves.
SprintController.Sprinting = false
SprintController.SprintingChanged = Signal.new()

local player = Players.LocalPlayer

local function getHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function setSprinting(isSprinting: boolean)
	local humanoid = getHumanoid()
	if humanoid then
		humanoid.WalkSpeed = if isSprinting then Constants.SprintSpeed else Constants.WalkSpeed
	end

	if SprintController.Sprinting ~= isSprinting then
		SprintController.Sprinting = isSprinting
		SprintController.SprintingChanged:Fire(isSprinting)
	end
end

local function isSprintKey(keyCode: Enum.KeyCode): boolean
	return keyCode == Enum.KeyCode.LeftShift or keyCode == Enum.KeyCode.RightShift
end

function SprintController.Init()
	player.CharacterAdded:Connect(function()
		setSprinting(false)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and isSprintKey(input.KeyCode) then
			setSprinting(true)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if isSprintKey(input.KeyCode) then
			setSprinting(false)
		end
	end)
end

return SprintController
