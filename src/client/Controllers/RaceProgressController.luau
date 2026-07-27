local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local AvatarThumbnail = require(script.Parent.Parent.AvatarThumbnail)
local Theme = require(script.Parent.Parent.Theme)
local MatchStateController = require(script.Parent.MatchStateController)

-- Vertical "race track" down the right edge of the screen: one marker per
-- racer, sliding from START at the bottom to FINISH at the top as they get
-- closer to the finish line. Position: N/M (RaceHudController) already says
-- WHERE you are in the pack, but not by how much -- this is the part that
-- makes a race feel like a race: you can see the leader pulling away, or
-- someone creeping up on you, while it's still possible to do something
-- about it.
--
-- Fed by MatchService's RaceProgressChanged broadcast (every
-- PROGRESS_BROADCAST_INTERVAL), which covers real matches, duels and bot
-- matches -- not practice, where there'd be nothing to compare against.
local RaceProgressController = {}

local player = Players.LocalPlayer

local TRACK_WIDTH = 12
local TRACK_HEIGHT = 300
-- Big enough for an avatar headshot to be recognizable at a glance while
-- you're actually racing, without the markers colliding when the field is
-- bunched up at the start.
local MARKER_SIZE = 34
-- Vertical padding above/below the track, leaving room for the endpoint caps
-- to sit centered on the track's ends without being clipped at the edges.
local TRACK_TOP = 18
-- Right edge, vertically centered, clear of QuitMatchController's button and
-- the mobile jump button in the bottom-right. Held far enough off the edge
-- that the endpoint pills, which hang ~70px to the RIGHT of the track, still
-- fit on screen.
local TRACK_POSITION = UDim2.new(1, -150, 0.5, -(TRACK_HEIGHT / 2 + TRACK_TOP))

type ProgressEntry = { UserId: number, Name: string, Progress: number }

local container: Frame
local track: Frame

-- userId -> the marker UI built for them, reused across updates so the
-- markers can tween between broadcasts instead of teleporting five times a
-- second. Rebuilt from scratch whenever a race starts.
local markers: { [number]: { Holder: Frame, Label: TextLabel } } = {}

local function buildTrack(parent: Frame)
	track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.fromOffset(TRACK_WIDTH, TRACK_HEIGHT)
	track.Position = UDim2.fromOffset(0, TRACK_TOP)
	track.BackgroundColor3 = Theme.Color.Panel
	track.BorderSizePixel = 0
	track.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = track

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 2
	stroke.Transparency = 0.5
	stroke.Parent = track

	-- Gradient runs bottom (start) to top (finish) so the track itself hints
	-- at the direction of travel, without needing a second label.
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Theme.Color.Success, Theme.Color.AccentA)
	gradient.Parent = track
end

-- An endpoint of the track: a solid tick across the bar plus a labelled pill.
-- Both parts matter. The tick is what actually marks WHERE the course ends on
-- the bar; the pill is what keeps the word readable, because these labels sit
-- over live 3D world -- as bare colored text they disappeared completely
-- (blurple "FINISH" against the sky, green "START" against the grass). The
-- pill goes to the RIGHT of the track, since racer name labels own the left
-- side and would collide with it.
local function buildCap(parent: Frame, text: string, centerY: number, color: Color3)
	local tick = Instance.new("Frame")
	tick.Name = text .. "Tick"
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Size = UDim2.fromOffset(TRACK_WIDTH + 12, 4)
	tick.Position = UDim2.fromOffset(TRACK_WIDTH / 2, centerY)
	tick.BackgroundColor3 = color
	tick.BorderSizePixel = 0
	tick.ZIndex = 4
	tick.Parent = parent

	local tickCorner = Instance.new("UICorner")
	tickCorner.CornerRadius = UDim.new(1, 0)
	tickCorner.Parent = tick

	local pill = Instance.new("Frame")
	pill.Name = text .. "Label"
	pill.AnchorPoint = Vector2.new(0, 0.5)
	pill.Size = UDim2.fromOffset(58, 18)
	pill.Position = UDim2.fromOffset(TRACK_WIDTH + 12, centerY)
	pill.BackgroundColor3 = Theme.Color.Background
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.ZIndex = 4
	pill.Parent = parent

	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = pill

	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = color
	pillStroke.Thickness = 1.5
	pillStroke.Transparency = 0.3
	pillStroke.Parent = pill

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.Heading
	label.Text = text
	label.TextSize = 11
	label.TextColor3 = color
	label.ZIndex = 5
	label.Parent = pill
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaceProgressGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	container = Instance.new("Frame")
	container.Name = "ProgressContainer"
	container.Size = UDim2.fromOffset(TRACK_WIDTH, TRACK_HEIGHT + TRACK_TOP * 2)
	container.Position = TRACK_POSITION
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = screenGui

	buildTrack(container)
	-- Sit exactly on the ends of the track, which is what the progress
	-- fraction is measured against: 1.0 lands on the FINISH tick, 0.0 on the
	-- START tick.
	buildCap(container, "FINISH", TRACK_TOP, Theme.Color.AccentA)
	buildCap(container, "START", TRACK_TOP + TRACK_HEIGHT, Theme.Color.Success)
end

local function createMarker(entry: ProgressEntry): { Holder: Frame, Label: TextLabel }
	local isSelf = entry.UserId == player.UserId

	local holder = Instance.new("Frame")
	holder.Name = tostring(entry.UserId)
	holder.Size = UDim2.fromOffset(MARKER_SIZE, MARKER_SIZE)
	-- Anchored on the track's center line; the name label hangs off to the
	-- left so markers never overlap the track itself.
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 1)
	-- Shows through as the ring behind the headshot (and stays as the whole
	-- marker for a bot, which has no avatar to fetch).
	holder.BackgroundColor3 = if isSelf then Theme.Candy.Gold.Face else Theme.Candy.Blue.Face
	holder.BorderSizePixel = 0
	holder.ZIndex = if isSelf then 3 else 2
	holder.Parent = track

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = holder

	local stroke = Instance.new("UIStroke")
	stroke.Color = if isSelf then Theme.Candy.Gold.Face else Theme.Candy.Border
	stroke.Thickness = 2
	stroke.Parent = holder

	-- The racer's actual profile picture, so you can tell at a glance who's
	-- ahead of you without reading names. Loaded through AvatarThumbnail
	-- rather than by assigning an rbxthumb:// URL directly -- see that module
	-- for why the URL form can silently never render (Studio Team Test's
	-- simulated clients hit exactly that case). UserId 0 is the bot (see
	-- MatchService's broadcast), which has no profile picture at all.
	if entry.UserId > 0 then
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		-- Inset by the ring thickness on each side.
		avatar.Size = UDim2.new(1, -6, 1, -6)
		avatar.Position = UDim2.fromOffset(3, 3)
		avatar.BackgroundColor3 = Theme.Color.Panel
		avatar.BorderSizePixel = 0
		avatar.ZIndex = holder.ZIndex + 1
		avatar.Parent = holder

		local avatarCorner = Instance.new("UICorner")
		avatarCorner.CornerRadius = UDim.new(1, 0)
		avatarCorner.Parent = avatar

		-- Until (or unless) a real photo arrives, the colored pill underneath
		-- is what shows -- which is why this only ever sets Image on success.
		-- The marker can also be destroyed mid-load (the racer finishes, or
		-- the race ends), so the callback has to re-check it's still around.
		AvatarThumbnail.Load(entry.UserId, function(content: string)
			if avatar.Parent then
				avatar.Image = content
			end
		end)
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(120, 16)
	label.Position = UDim2.fromOffset(-128, MARKER_SIZE / 2 - 8)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.Heading
	label.Text = if isSelf then "YOU" else entry.Name
	label.TextSize = 13
	label.TextColor3 = if isSelf then Theme.Candy.Gold.Face else Theme.Color.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextStrokeTransparency = 0.3
	label.ZIndex = holder.ZIndex + 1
	label.Parent = holder

	return { Holder = holder, Label = label }
end

local function clearMarkers()
	for _, marker in markers do
		marker.Holder:Destroy()
	end
	markers = {}
end

local function onProgress(entries: { ProgressEntry })
	if not container.Visible then
		return
	end

	local seen: { [number]: boolean } = {}
	for _, entry in entries do
		seen[entry.UserId] = true

		local marker = markers[entry.UserId]
		if not marker then
			marker = createMarker(entry)
			markers[entry.UserId] = marker
		end

		-- 1 (bottom of the track) at the start line, 0 (top) at the finish.
		local target = UDim2.fromScale(0.5, 1 - entry.Progress)
		TweenService:Create(marker.Holder, Theme.Anim.Ease, { Position = target }):Play()
	end

	-- Anyone who finished, quit or disconnected simply stops appearing in the
	-- broadcast -- drop their marker rather than leaving it frozen mid-track.
	for userId, marker in markers do
		if not seen[userId] then
			marker.Holder:Destroy()
			markers[userId] = nil
		end
	end
end

local function onStateChanged(state: string)
	local racing = state == "Racing" or state == "Spectating"
	if racing == container.Visible then
		return
	end

	clearMarkers()
	container.Visible = racing
end

function RaceProgressController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(onStateChanged)
	onStateChanged(MatchStateController.CurrentState)

	Net.GetRemoteEvent(RemoteNames.RaceProgressChanged).OnClientEvent:Connect(onProgress)
end

return RaceProgressController
