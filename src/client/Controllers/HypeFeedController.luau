local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Hype = require(Shared.Hype)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)

-- Renders HypeFeedService's server-wide announcements as a stack of toasts.
--
-- Read-only and non-interactive on purpose: this is the game telling you what
-- someone else just did, so there is nothing to click and nothing that can
-- steal a tap from the buttons underneath (every toast sets Active = false).
local HypeFeedController = {}

local player = Players.LocalPlayer

local TOAST_WIDTH = 440
local TOAST_HEIGHT = 52
local TOAST_HEIGHT_WITH_DETAIL = 72
local TOAST_GAP = 8
-- Below the top-centre HUD lane, which is already taken: the queue card
-- occupies y 24..128 in the lobby and RaceHudController's timer panel y
-- 56..160 during a race. Starting at 176 clears both, so a toast can never
-- land on top of the countdown or the race timer.
local STACK_TOP = 176
local VISIBLE_SECONDS = 4
-- More than this on screen at once and the stack starts reaching down into
-- the play area; the oldest is retired early to make room.
local MAX_VISIBLE = 3

local screenGui: ScreenGui
local active: { Frame } = {}

-- Icons are drawn from primitives rather than text glyphs: Roblox's Gotham
-- family has no symbol coverage and a missing glyph renders as a box (learned
-- the hard way on the queue card's cancel X).
--
-- Streak and Record delegate to MenuIcons, which already has a trophy and a
-- lightning bolt drawn to this game's icon language -- a hand-rolled flame
-- and bolt here read as anonymous blobs at 28px next to them. Rank is drawn
-- locally because nothing in MenuIcons points UP, and "up" is the whole
-- meaning of a promotion.
local function buildIcon(parent: Frame, kind: string, color: Color3)
	local holder = Instance.new("Frame")
	holder.Name = "Icon"
	holder.Size = UDim2.fromOffset(28, 28)
	holder.Position = UDim2.new(0, 14, 0.5, 0)
	holder.AnchorPoint = Vector2.new(0, 0.5)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	if kind == "Streak" then
		MenuIcons.Populate(holder, "Leaderboard", color)
		return
	elseif kind == "Record" then
		MenuIcons.Populate(holder, "Ability", color)
		return
	end

	-- Rank: a double chevron pointing up, each chevron two bars meeting at a
	-- point.
	for _, y in { 16, 24 } do
		for _, spec in { { 10, -45 }, { 19, 45 } } do
			local piece = Instance.new("Frame")
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.fromOffset(spec[1], y)
			piece.Size = UDim2.fromOffset(15, 5)
			piece.Rotation = spec[2]
			piece.BackgroundColor3 = color
			piece.BorderSizePixel = 0
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = piece
			piece.Parent = holder
		end
	end
end

-- Re-flows the stack so the newest sits at the top and the rest slide down
-- under it. Called on every add AND every removal, so a toast expiring out of
-- the middle closes the gap instead of leaving a hole.
local function reflow()
	local y = STACK_TOP
	for _, toast in active do
		TweenService:Create(toast, Theme.Anim.Smooth, { Position = UDim2.new(0.5, -TOAST_WIDTH / 2, 0, y) }):Play()
		y += toast.Size.Y.Offset + TOAST_GAP
	end
end

local function retire(toast: Frame)
	local index = table.find(active, toast)
	if not index then
		return -- already retired (expired and force-retired in the same frame)
	end
	table.remove(active, index)
	reflow()

	local fade = TweenService:Create(toast, Theme.Anim.Smooth, { BackgroundTransparency = 1 })
	for _, d in toast:GetDescendants() do
		if d:IsA("TextLabel") then
			TweenService:Create(d, Theme.Anim.Smooth, { TextTransparency = 1 }):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, Theme.Anim.Smooth, { BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, Theme.Anim.Smooth, { Transparency = 1 }):Play()
		end
	end
	fade:Play()
	-- Destroyed on a timer rather than on fade.Completed: a tween that never
	-- reports completion (see Widgets.Close for the same guard) would
	-- otherwise leak an invisible frame per announcement forever.
	task.delay(Theme.Anim.Smooth.Time + 0.1, function()
		toast:Destroy()
	end)
end

local function show(announcement: Hype.Announcement)
	local presentation = Hype.Describe(announcement)
	local hasDetail = presentation.Detail ~= nil
	local height = if hasDetail then TOAST_HEIGHT_WITH_DETAIL else TOAST_HEIGHT

	local toast = Instance.new("Frame")
	toast.Name = "HypeToast"
	toast.Size = UDim2.fromOffset(TOAST_WIDTH, height)
	-- Starts a little above its resting slot and slides down into place.
	toast.Position = UDim2.new(0.5, -TOAST_WIDTH / 2, 0, STACK_TOP - 20)
	toast.BackgroundColor3 = Color3.fromRGB(26, 27, 38)
	toast.BackgroundTransparency = 0.08
	toast.BorderSizePixel = 0
	-- Never eats input: the lobby buttons underneath must stay clickable.
	toast.Active = false
	toast.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Card
	corner.Parent = toast

	-- The stroke carries the announcement's colour (rank tier, streak orange,
	-- record blue) so the KIND of news is readable before the words are.
	local stroke = Instance.new("UIStroke")
	stroke.Color = presentation.Color
	stroke.Thickness = 2.5
	stroke.Parent = toast

	buildIcon(toast, presentation.Icon, presentation.Color)

	local headline = Instance.new("TextLabel")
	headline.Size = UDim2.new(1, -64, 0, if hasDetail then 26 else height)
	headline.Position = UDim2.fromOffset(54, if hasDetail then 10 else 0)
	headline.BackgroundTransparency = 1
	headline.Text = presentation.Headline
	headline.TextColor3 = presentation.Color
	headline.Font = Theme.Font.Display
	headline.TextSize = 20
	headline.TextXAlignment = Enum.TextXAlignment.Left
	headline.TextTruncate = Enum.TextTruncate.AtEnd
	headline.Parent = toast

	if hasDetail then
		local detail = Instance.new("TextLabel")
		detail.Size = UDim2.new(1, -64, 0, 22)
		detail.Position = UDim2.fromOffset(54, 38)
		detail.BackgroundTransparency = 1
		detail.Text = presentation.Detail
		detail.TextColor3 = Theme.Color.TextSecondary
		detail.Font = Theme.Font.Body
		detail.TextSize = 16
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.TextTruncate = Enum.TextTruncate.AtEnd
		detail.Parent = toast
	end

	-- Newest on top: everything already up shuffles down one slot.
	table.insert(active, 1, toast)
	while #active > MAX_VISIBLE do
		retire(active[#active])
	end
	reflow()

	task.delay(VISIBLE_SECONDS, function()
		retire(toast)
	end)
end

function HypeFeedController.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HypeFeedGui"
	screenGui.ResetOnSpawn = false
	-- Under the modals (Shop/Gacha/Party open at higher orders) so a toast
	-- can never land across a panel the player is actively reading.
	screenGui.DisplayOrder = 4
	screenGui.Parent = player:WaitForChild("PlayerGui")

	Net.GetRemoteEvent(RemoteNames.HypeAnnouncement).OnClientEvent:Connect(function(announcement: Hype.Announcement)
		if typeof(announcement) ~= "table" or not announcement.Kind then
			return
		end
		show(announcement)
	end)
end

return HypeFeedController
