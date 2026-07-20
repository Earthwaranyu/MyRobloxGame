local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Net = require(Shared.Net)
local RarityColors = require(Shared.RarityColors)
local RemoteNames = require(Shared.RemoteNames)

local AbilityIcons = require(script.Parent.Parent.AbilityIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Whichever ability is currently equipped (Dash by default -- see
-- Abilities.luau -- or whatever was won from the gacha and equipped via the
-- inventory UI). Q is the real interaction -- same first-person mouse-lock
-- reasoning as QuitMatchController/EmoteController -- the button is a visible
-- reminder of the key and a cooldown readout, and still works on the rare
-- occasion the cursor is free. The actual effect (BodyVelocity, teleport,
-- speed override, cooldown enforcement) all lives server-side in
-- AbilityService; this only ever sends "use my ability now".
local ABILITY_KEY = Enum.KeyCode.Q

local AbilityController = {}

local player = Players.LocalPlayer

local button: TextButton
local iconHolder: Frame
local requestAbilityRemote: RemoteEvent
local flashFrame: Frame
local readyAt = 0

-- Sane default before the profile fetch in Init resolves -- Dash is always
-- owned/equippable so this can never point at nothing.
local currentAbility: Abilities.AbilityInfo = Abilities[1]

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local READY_SHADOW_COLOR = Theme.Candy.White.Shadow
local READY_TEXT_COLOR = Color3.fromRGB(24, 24, 28)
local COOLDOWN_COLOR = Theme.Color.PanelLight
local COOLDOWN_SHADOW_COLOR = Color3.fromRGB(20, 21, 30)

local function getAbilityById(id: string): Abilities.AbilityInfo?
	for _, info in Abilities do
		if info.Id == id then
			return info
		end
	end
	return nil
end

local function updateButton()
	local remaining = readyAt - os.clock()
	local displayName = currentAbility.Name:upper()
	local iconColor: Color3
	if remaining > 0 then
		button.Text = ("%s  %.1fs"):format(displayName, remaining)
		Widgets.SetButtonColors(button, COOLDOWN_COLOR, COOLDOWN_SHADOW_COLOR, Theme.Color.TextMuted)
		iconColor = Theme.Color.TextMuted
	else
		button.Text = ("%s (Q)"):format(displayName)
		Widgets.SetButtonColors(button, READY_COLOR, READY_SHADOW_COLOR, READY_TEXT_COLOR)
		iconColor = READY_TEXT_COLOR
	end
	AbilityIcons.Populate(iconHolder, currentAbility.Id, iconHolder.Size.X.Offset, iconColor)
end

-- How strong/long the flash is per rarity -- a free Common ability still
-- gets real feedback (this isn't the gacha reveal's "build anticipation by
-- staying quiet on Common" logic), it just doesn't hit as hard as using
-- something Legendary does. This was the concrete fix for "Meteor Dash feels
-- the same as normal Dash" -- same BodyVelocity shape, but a Legendary
-- activation should visibly announce itself more than the free baseline.
local RARITY_FLASH_INTENSITY = { Common = 0.18, Rare = 0.26, Epic = 0.36, Legendary = 0.5 }
local RARITY_FLASH_DURATION = { Common = 0.3, Rare = 0.32, Epic = 0.38, Legendary = 0.48 }

-- Quick full-screen color flash, purely a client-side "that just happened"
-- cue -- deliberately not touching camera.FieldOfView, since RunBobController
-- already drives that continuously while sprinting and a second controller
-- fighting it over the same property would just cause jitter. Tinted to the
-- equipped ability's rarity color (same palette the gacha UI uses -- see
-- RarityColors) rather than a fixed color every ability shared before.
local function playFlash()
	local rarity = currentAbility.Rarity
	local intensity = RARITY_FLASH_INTENSITY[rarity] or 0.18
	local duration = RARITY_FLASH_DURATION[rarity] or 0.3

	flashFrame.BackgroundColor3 = RarityColors[rarity] or Color3.fromRGB(140, 200, 255)
	flashFrame.BackgroundTransparency = 1 - intensity
	TweenService:Create(flashFrame, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

local function tryUseAbility()
	if os.clock() < readyAt then
		return
	end
	readyAt = os.clock() + currentAbility.CooldownSeconds
	updateButton()
	playFlash()
	requestAbilityRemote:FireServer()

	task.spawn(function()
		while os.clock() < readyAt do
			updateButton()
			task.wait(0.1)
		end
		updateButton()
	end)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AbilityGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- 190 wide, not 150 -- 150 was sized for "DASH (Q)" alone; once Meteor
	-- Dash (the longest name, plus a cooldown readout like "METEOR DASH
	-- 4.0s") needed to share the button with an icon too, the old width left
	-- no room for either. Sits directly above the VS BOTS button (see
	-- PlayButtonController), same 8px-gap convention used throughout this
	-- stack of bottom-center buttons. Left edge stays at -75 (unchanged from
	-- the original 150-wide button) -- SprintController's button sits
	-- immediately to the left with its own right edge at -85, so the extra
	-- width needs to extend rightward only; growing this symmetrically around
	-- the old center would push the left edge to -95, eating into Sprint's
	-- button. 200 (not 190) for extra breathing room around the worst-case
	-- cooldown readout, "METEOR DASH  12.0s".
	--
	-- Icon goes through opts.Icon (Widgets.Button's standard icon+label
	-- layout) instead of a hand-built iconHolder + UIPadding + TextXAlignment
	-- -- that hand-built version predates opts.Icon and positioned the icon
	-- independently of where the button's actual text renders, which after
	-- Widgets.Button switched to rendering ALL text through a child Label
	-- (see git log) left the icon and the now-centered Label overlapping
	-- (confirmed via screenshot: the icon sat on top of "M" in "METEOR").
	-- opts.Icon computes the label's left inset FROM the icon's real size/
	-- position, so the two can never drift out of sync again.
	button = Widgets.Button("DASH (Q)", UDim2.fromOffset(200, 44), UDim2.new(0.5, -75, 1, -224), {
		Variant = "Secondary",
		TextSize = 16,
		Icon = function(holder, color)
			AbilityIcons.Populate(holder, currentAbility.Id, holder.Size.X.Offset, color)
		end,
	})
	button.Parent = screenGui
	button.MouseButton1Click:Connect(tryUseAbility)

	-- The icon holder opts.Icon just built and parented onto `button`, named
	-- "Icon" by Widgets.Button -- kept so updateButton() can redraw it
	-- whenever the equipped ability or cooldown color changes.
	iconHolder = button:FindFirstChild("Icon") :: Frame

	local flashGui = Instance.new("ScreenGui")
	flashGui.Name = "DashFlashGui"
	flashGui.ResetOnSpawn = false
	flashGui.IgnoreGuiInset = true
	flashGui.DisplayOrder = 15
	flashGui.Parent = player:WaitForChild("PlayerGui")

	flashFrame = Instance.new("Frame")
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = Color3.fromRGB(140, 200, 255)
	flashFrame.BackgroundTransparency = 1
	flashFrame.BorderSizePixel = 0
	flashFrame.Active = false -- must not block clicks to anything underneath
	flashFrame.Parent = flashGui
end

function AbilityController.Init()
	buildUI()
	requestAbilityRemote = Net.GetRemoteEvent(RemoteNames.RequestAbility)

	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if profile and profile.EquippedAbility then
		currentAbility = getAbilityById(profile.EquippedAbility) or currentAbility
	end
	updateButton()

	-- Fired by AbilityService whenever this player's equip actually changes
	-- (see the inventory UI) -- refreshing the button's name/cooldown display
	-- immediately instead of only on next spawn.
	Net.GetRemoteEvent(RemoteNames.AbilityEquipped).OnClientEvent:Connect(function(abilityId: string)
		currentAbility = getAbilityById(abilityId) or currentAbility
		readyAt = 0
		updateButton()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= ABILITY_KEY then
			return
		end
		tryUseAbility()
	end)

	-- Mirrors AbilityService.ResetCooldown, which the server calls at the
	-- exact same "Racing" transition -- keeps the UI honest instead of
	-- showing a stale countdown left over from using it during the free
	-- pre-race warmup.
	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" then
			readyAt = 0
			updateButton()
		end
	end)
end

return AbilityController
