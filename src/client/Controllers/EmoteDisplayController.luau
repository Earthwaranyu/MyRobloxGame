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

-- The bubble sits directly ABOVE the head, one storey up from the rank plate.
--
-- It used to be parked out to the right of the rank plate instead, to keep it
-- out of the top-centre HUD lane: the camera holds the local player near the
-- middle of the screen, so "above the head" is "above the middle", which is
-- where the NEXT WAVE tab, race timer and queue card live (see Theme.TopLane).
-- That was measured on a phone, where the screen is short enough for the two to
-- meet.
--
-- Overhead is what the game actually wants though -- emotes popping over your
-- head is the Clash Royale read the design calls for, and off to one side reads
-- as a notification rather than as something the character is doing. So it sits
-- overhead, and the lane clash is accepted as the cheaper cost: it needs a
-- short screen AND an emote AND something in the lane at the same moment, it
-- lasts DISPLAY_SECONDS, and the bubble draws over the top (AlwaysOnTop) rather
-- than being hidden by it.
local BUBBLE_SIZE = 56
-- One storey above the rank plate (StudsOffset 2.6, 40px tall -- see
-- OverheadDisplayService), which is the same 1.4-stud step the streak badge
-- already used to clear that plate. Close enough to read as part of the
-- character rather than as something hanging in the air over it.
--
-- This IS the streak badge's old slot, and it took it deliberately: an emote is
-- something the player just pressed a button for and should sit where they
-- look, while the streak flame is a passive badge that is equally legible one
-- storey higher. StreakFlameController moved up to 5.4 to make room -- the two
-- must not share a height, or a player emoting mid-streak gets both drawn on
-- top of each other.
local BUBBLE_STUDS_OFFSET_Y = 4.0

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

	-- Billboard is exactly the bubble now, centred on the head -- it no longer
	-- needs to be a wide invisible frame with the bubble pinned to one end.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EmoteBubble"
	billboard.Size = UDim2.fromOffset(BUBBLE_SIZE, BUBBLE_SIZE)
	billboard.StudsOffset = Vector3.new(0, BUBBLE_STUDS_OFFSET_Y, 0)
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local circle = Instance.new("Frame")
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
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
