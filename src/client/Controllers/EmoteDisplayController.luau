local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Clash Royale-style: a round icon bubble pops up above whoever played the
-- emote for a couple seconds, then fades. Purely visual/local -- the server
-- only validates ownership/cooldown and broadcasts who-played-what; every
-- client (including the emoter) builds its own bubble off that.
local EmoteDisplayController = {}

local DISPLAY_SECONDS = 2.2
local FADE_SECONDS = 0.3

-- The bubble sits BESIDE the rank plate, not stacked above it.
--
-- Stacking was the obvious arrangement and it put the bubble straight into the
-- top-centre HUD lane. The camera keeps the local player near the middle of the
-- screen, so "a bit above the head" is "a bit above the middle" -- which is
-- exactly where WaveClockController's NEXT WAVE tab, the race timer and the
-- queue card live (see Theme.TopLane). Measured on a phone: the bubble landed
-- on top of the wave clock, and going HIGHER to escape the rank plate and the
-- streak flame only pushed it further into the lane it needed to get out of.
--
-- Sideways has no such ceiling. Both this and the rank plate are fixed-PIXEL
-- billboards centred on the same point above the head, so parking the bubble
-- past the plate's own half-width keeps a constant gap at every distance --
-- there is no range at which the two drift into each other.
local BUBBLE_SIZE = 56
-- OverheadDisplayService builds the plate 168 wide, so it reaches 84 either
-- side of centre. StreakFlameController's badge (84 wide, StudsOffset 4.0) is
-- narrower than that, so clearing the plate clears the flame too.
local PLATE_HALF_WIDTH = 84
local PLATE_GAP = 6
-- Same StudsOffset the rank plate uses -- the bubble is now a neighbour of it
-- rather than another storey on top of it.
local PLATE_STUDS_OFFSET_Y = 2.6
-- Wide enough that the bubble, pinned to the right-hand edge, ends up clear of
-- the plate: half of it is the plate's reach plus the gap plus the bubble.
local BILLBOARD_WIDTH = (PLATE_HALF_WIDTH + PLATE_GAP + BUBBLE_SIZE) * 2

local emoteById: { [string]: any } = {}
for _, emote in Emotes do
	emoteById[emote.Id] = emote
end

local function showBubble(player: Player, emoteId: string)
	local emote = emoteById[emoteId]
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not emote or not head then
		return
	end

	local existing = head:FindFirstChild("EmoteBubble")
	if existing then
		existing:Destroy()
	end

	-- A transparent billboard the width of the whole plate-plus-bubble group,
	-- with the bubble pinned to its right-hand end -- see the constants above for
	-- why this is sideways rather than another storey above the rank plate.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EmoteBubble"
	billboard.Size = UDim2.fromOffset(BILLBOARD_WIDTH, BUBBLE_SIZE)
	billboard.StudsOffset = Vector3.new(0, PLATE_STUDS_OFFSET_Y, 0)
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local circle = Instance.new("Frame")
	circle.AnchorPoint = Vector2.new(1, 0.5)
	circle.Position = UDim2.fromScale(1, 0.5)
	circle.Size = UDim2.fromOffset(BUBBLE_SIZE, BUBBLE_SIZE)
	circle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	circle.BorderSizePixel = 0
	circle.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(20, 20, 24)
	stroke.Parent = circle

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.78, 0.78)
	label.Position = UDim2.fromScale(0.11, 0.11)
	label.BackgroundTransparency = 1
	label.Text = emote.Icon
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = circle

	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = circle

	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()

	task.delay(DISPLAY_SECONDS, function()
		if not billboard.Parent then
			return
		end
		TweenService:Create(circle, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(stroke, TweenInfo.new(FADE_SECONDS), { Transparency = 1 }):Play()
		TweenService:Create(label, TweenInfo.new(FADE_SECONDS), { TextTransparency = 1 }):Play()

		task.delay(FADE_SECONDS + 0.05, function()
			if billboard.Parent then
				billboard:Destroy()
			end
		end)
	end)
end

function EmoteDisplayController.Init()
	local remote = Net.GetRemoteEvent(RemoteNames.EmotePlayed)
	remote.OnClientEvent:Connect(showBubble)
end

return EmoteDisplayController
