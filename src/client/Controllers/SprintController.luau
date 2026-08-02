local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local Theme = require(script.Parent.Parent.Theme)
local Responsive = require(script.Parent.Parent.Responsive)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

local SprintController = {}

-- PAIR_WIDTH is SPRINT + gap + DASH (150 + 10 + 200), the group whose midpoint
-- sits on the screen centre -- see the placement comment in buildUI.
local SPRINT_WIDTH, SPRINT_HEIGHT, SPRINT_BOTTOM = 150, 44, 224

-- The phone action row: SPRINT, PLAY and DASH side by side on one line.
-- PlayButtonController and AbilityController read the same Responsive.ActionRow,
-- which owns the widths, the gap and the x positions, so the three cannot drift
-- apart and none of them can wander onto the movement pad.
local PAIR_WIDTH = 360

-- Exposed so purely cosmetic client features (wind effect, etc.) can react
-- to sprinting without re-implementing shift-key detection themselves.
SprintController.Sprinting = false
SprintController.SprintingChanged = Signal.new()

local player = Players.LocalPlayer
local sprintIntentRemote: RemoteEvent
local button: TextButton
local buttonHeld = false

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local READY_TEXT_COLOR = Color3.fromRGB(24, 24, 28)

local function updateButtonVisual(isSprinting: boolean)
	if not button then
		return
	end
	if isSprinting then
		Widgets.SetButtonColors(button, Theme.Candy.Green.Face, Theme.Candy.Green.Shadow, Color3.new(1, 1, 1))
	else
		Widgets.SetButtonColors(button, READY_COLOR, Theme.Candy.White.Shadow, READY_TEXT_COLOR)
	end
end

-- Actually setting Humanoid.WalkSpeed used to happen right here on the
-- client. That's a real speedhack vector -- anything a client sets on its
-- own Humanoid replicates as-is, so a hacked client could set WalkSpeed to
-- any number it wants and win every race. This now only tells the server
-- "shift is held or not"; MovementService is the one that actually decides
-- (and enforces) the resulting speed.
local function setSprinting(isSprinting: boolean)
	if SprintController.Sprinting ~= isSprinting then
		SprintController.Sprinting = isSprinting
		SprintController.SprintingChanged:Fire(isSprinting)
		sprintIntentRemote:FireServer(isSprinting)
		updateButtonVisual(isSprinting)
	end
end

local function isSprintKey(keyCode: Enum.KeyCode): boolean
	return keyCode == Enum.KeyCode.LeftShift or keyCode == Enum.KeyCode.RightShift
end

-- Sprint was keyboard-only (Shift) until this button existed -- every other
-- keybind mechanic in this game (dash, emotes, quit match) already has a
-- visible on-screen button that doubles as a touch target, but this one
-- didn't, which meant mobile players had no way to sprint at all. Several
-- stages are tuned assuming sprint is available (see the tutorial copy), so
-- that wasn't just missing polish -- some jumps were likely unbeatable on
-- mobile. Hold-to-sprint with a pointer, tap-to-toggle on touch -- see the
-- input handlers at the bottom of this function for why the two differ.
local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SprintGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits left of AbilityController's DASH button, mirrored spacing, so the
	-- two read as one small ability bar. No explicit TextSize (see
	-- GachaController's Pull/Lucky buttons for why) -- letting
	-- defaultTextSize's own >=18 threshold apply keeps this crisp instead of
	-- soft.
	-- x = -180 pairs with AbilityController's DASH at -20: the two buttons plus
	-- the 10px gap between them are 360 wide (150 + 10 + 200), so starting at
	-- -180 puts the PAIR's midpoint on the screen centre. The old -235/-75 gave
	-- the same spacing but centred neither -- the group ran -235..125, sitting
	-- visibly left of the PLAY button it stacks above.
	button = Widgets.Button(
		"SPRINT",
		UDim2.fromOffset(SPRINT_WIDTH, SPRINT_HEIGHT),
		UDim2.new(0.5, -180, 1, -SPRINT_BOTTOM),
		{
			Variant = "Secondary",
		}
	)
	button.Parent = screenGui

	-- Two arrangements. On anything roomy, SPRINT and DASH are a centred pair two
	-- rows above PLAY. On a phone that does not fit -- 334pt of height cannot
	-- take two rail rows plus three stacked action rows, and the top of the stack
	-- collided with the Emotes button -- so the three share ONE row instead,
	-- sized and placed by Responsive.ActionRow to fit the clear strip between the
	-- movement pad and the jump button.
	Responsive.Observe(function()
		local px = Responsive.Px
		local height = Responsive.Tap(SPRINT_HEIGHT)
		local width, x, row, rowWidth
		if Responsive.Tier() == "Phone" then
			-- First element of the shared phone action row (SPRINT, PLAY, DASH).
			-- The WIDTH comes from there too, not from SPRINT_WIDTH: the row is
			-- fitted to the clear strip between the movement pad and the jump
			-- button, and a button that kept its authored width would push the
			-- row back over the pad.
			local actionRow = Responsive.ActionRow()
			width, x, rowWidth = actionRow.Widths[1], actionRow.Positions[1], actionRow.Total
			row = 0
		else
			local pairWidth = px(PAIR_WIDTH)
			width, rowWidth = px(SPRINT_WIDTH), pairWidth
			x = Responsive.ClearCorners(math.round((Responsive.ViewportSize().X - pairWidth) / 2), pairWidth)
			row = 2
		end
		Widgets.Relayout(
			button,
			UDim2.fromOffset(width, height),
			UDim2.fromOffset(x, Responsive.BottomRowY(row, height, rowWidth))
		)
	end)

	-- HOLD on a mouse, TOGGLE on touch -- and the difference is the other half of
	-- "I press sprint and I can't move".
	--
	-- Hold-to-sprint asks for a finger that stays put for the whole sprint. A
	-- phone player has two thumbs, and both are already spoken for: the left one
	-- drives the movement pad, the right one the jump button. The only way to
	-- keep SPRINT held is to park the steering thumb on it, at which point you
	-- are sprinting and not steering -- which is what the button felt like even
	-- after moving it off the pad. A toggle costs one tap and gives the thumb
	-- straight back.
	--
	-- Shift keeps its hold behaviour (see the UserInputService handlers in Init):
	-- a key held down has no such cost, and changing it would be a regression for
	-- everyone already used to it.
	if Responsive.IsTouch() then
		button.MouseButton1Click:Connect(function()
			setSprinting(not SprintController.Sprinting)
		end)
	else
		button.MouseButton1Down:Connect(function()
			buttonHeld = true
			setSprinting(true)
		end)
		button.MouseButton1Up:Connect(function()
			buttonHeld = false
			setSprinting(false)
		end)
		-- A drag off the button while still holding doesn't reliably fire
		-- MouseButton1Up on Roblox -- without this, a pointer sliding off would
		-- leave sprint stuck on with no way to cancel it.
		button.MouseLeave:Connect(function()
			if buttonHeld then
				buttonHeld = false
				setSprinting(false)
			end
		end)
	end
end

function SprintController.Init()
	sprintIntentRemote = Net.GetRemoteEvent(RemoteNames.SetSprintIntent)
	buildUI()

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

	-- Hidden while Spectating -- there's nothing to sprint when you're
	-- watching someone else race, and leaving the button on screen (as if
	-- still usable) is exactly what made spectating read as broken.
	MatchStateController.StateChanged:Connect(function(state: string)
		button.Visible = state ~= "Spectating"
		-- Unconditional, not just when the button is being held: on touch it is a
		-- toggle, so sprint can be latched ON with nothing holding it -- and
		-- hiding the button would then leave it latched with no way to switch it
		-- back off.
		if state == "Spectating" then
			buttonHeld = false
			setSprinting(false)
		end
	end)
	button.Visible = MatchStateController.CurrentState ~= "Spectating"
end

return SprintController
