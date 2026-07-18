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

	-- OverheadDisplayService's rank tag sits at StudsOffset 2.6. Both are
	-- fixed-pixel-size BillboardGuis, so being only 1 stud apart made them
	-- visually collide on screen at anything but point-blank range -- the
	-- gap here needs to be generous, not just "technically above it".
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EmoteBubble"
	billboard.Size = UDim2.fromOffset(56, 56)
	billboard.StudsOffset = Vector3.new(0, 4.9, 0)
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local circle = Instance.new("Frame")
	circle.Size = UDim2.fromScale(1, 1)
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
