local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local AvatarThumbnail = require(script.Parent.Parent.AvatarThumbnail)
local Responsive = require(script.Parent.Parent.Responsive)
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
-- Big enough for an avatar headshot to be recognizable at a glance while
-- you're actually racing, without the markers colliding when the field is
-- bunched up at the start.
local MARKER_SIZE = 34
-- Vertical padding above/below the track, leaving room for the endpoint caps
-- to sit centered on the track's ends without being clipped at the edges.
local TRACK_TOP = 18
-- Right edge inset, at reference. The endpoint pills hang to the RIGHT of the
-- track, so the track has to be held far enough in that they still fit.
local TRACK_RIGHT_INSET = 150

-- The track's length is the one dimension here that cannot just be scaled.
--
-- It was a flat 300px, which is fine on a 720-tall desktop and absurd on a phone
-- in landscape: a 375-point viewport would have given a 300px track plus 36 of
-- padding, i.e. 90% of the screen height taken by a progress bar during the one
-- activity where seeing the course matters most. So it is a share of the
-- viewport, floored so it stays readable on a short window and capped so it does
-- not become a full-height bar on a tall monitor.
local TRACK_HEIGHT_SHARE = 0.42
local TRACK_HEIGHT_MIN = 150
local TRACK_HEIGHT_MAX = 300

local CAP_TICK_OVERHANG = 12
local CAP_TICK_THICKNESS = 4
local CAP_PILL_WIDTH = 58
local CAP_PILL_HEIGHT = 18
local CAP_TEXT = 11
local NAME_WIDTH = 120
local NAME_HEIGHT = 16
local NAME_GAP = 8
local NAME_TEXT = 13

local function trackHeight(): number
	local available = Responsive.ViewportSize().Y * TRACK_HEIGHT_SHARE
	return math.round(math.clamp(available, TRACK_HEIGHT_MIN, TRACK_HEIGHT_MAX))
end

type ProgressEntry = { UserId: number, Name: string, Progress: number }
type Cap = { Tick: Frame, Pill: Frame, Label: TextLabel, AtFinish: boolean }

local container: Frame
local track: Frame
local caps: { Cap } = {}

-- userId -> the marker UI built for them, reused across updates so the
-- markers can tween between broadcasts instead of teleporting five times a
-- second. Rebuilt from scratch whenever a race starts.
local markers: { [number]: { Holder: Frame, Label: TextLabel } } = {}

local function buildTrack(parent: Frame)
	track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.fromOffset(TRACK_WIDTH, trackHeight())
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
local function buildCap(parent: Frame, text: string, atFinish: boolean, color: Color3)
	-- Both ends are placed off the track's CURRENT length, so the pair moves
	-- together when the viewport changes -- the progress fraction is measured
	-- against exactly these two points (1.0 lands on FINISH, 0.0 on START), and a
	-- cap left behind at its old y would be a visibly lying scale.
	local centerY = if atFinish then TRACK_TOP else TRACK_TOP + trackHeight()

	local tick = Instance.new("Frame")
	tick.Name = text .. "Tick"
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Size = UDim2.fromOffset(TRACK_WIDTH + CAP_TICK_OVERHANG, CAP_TICK_THICKNESS)
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
	pill.Size = UDim2.fromOffset(CAP_PILL_WIDTH, CAP_PILL_HEIGHT)
	pill.Position = UDim2.fromOffset(TRACK_WIDTH + CAP_TICK_OVERHANG, centerY)
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
	label.TextSize = CAP_TEXT
	label.TextColor3 = color
	label.ZIndex = 5
	label.Parent = pill

	table.insert(caps, { Tick = tick, Pill = pill, Label = label, AtFinish = atFinish })
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaceProgressGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	container = Instance.new("Frame")
	container.Name = "ProgressContainer"
	container.Size = UDim2.fromOffset(TRACK_WIDTH, trackHeight() + TRACK_TOP * 2)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = screenGui

	buildTrack(container)
	-- Sit exactly on the ends of the track, which is what the progress
	-- fraction is measured against: 1.0 lands on the FINISH tick, 0.0 on the
	-- START tick.
	buildCap(container, "FINISH", true, Theme.Color.AccentA)
	buildCap(container, "START", false, Theme.Color.Success)

	-- Right edge, vertically centred. Everything here is re-derived rather than
	-- fixed: the track's length is a share of the viewport (see trackHeight), and
	-- the inset that keeps the endpoint pills on screen has to shrink with the
	-- pills themselves or a phone loses the right-hand third of the bar.
	local function layout()
		local height = trackHeight()
		local top = Responsive.Px(TRACK_TOP)
		local width = Responsive.Px(TRACK_WIDTH)

		container.Size = UDim2.fromOffset(width, height + top * 2)
		container.Position = UDim2.new(1, -Responsive.Px(TRACK_RIGHT_INSET), 0.5, -(height / 2 + top))

		track.Size = UDim2.fromOffset(width, height)
		track.Position = UDim2.fromOffset(0, top)

		for _, cap in caps do
			local centerY = if cap.AtFinish then top else top + height
			local overhang = Responsive.Px(CAP_TICK_OVERHANG)
			cap.Tick.Size = UDim2.fromOffset(width + overhang, Responsive.Px(CAP_TICK_THICKNESS))
			cap.Tick.Position = UDim2.fromOffset(width / 2, centerY)
			cap.Pill.Size = UDim2.fromOffset(Responsive.Px(CAP_PILL_WIDTH), Responsive.Px(CAP_PILL_HEIGHT))
			cap.Pill.Position = UDim2.fromOffset(width + overhang, centerY)
			cap.Label.TextSize = Responsive.Text(CAP_TEXT)
		end

		-- Markers are built per race and may already be on the track. Their
		-- POSITION is in scale so the track's new length carries them, but their
		-- size is not.
		local markerSize = Responsive.Px(MARKER_SIZE)
		for _, marker in markers do
			marker.Holder.Size = UDim2.fromOffset(markerSize, markerSize)
			marker.Label.Size = UDim2.fromOffset(Responsive.Px(NAME_WIDTH), Responsive.Px(NAME_HEIGHT))
			marker.Label.Position =
				UDim2.fromOffset(-Responsive.Px(NAME_WIDTH + NAME_GAP), markerSize / 2 - Responsive.Px(NAME_HEIGHT) / 2)
			marker.Label.TextSize = Responsive.Text(NAME_TEXT)
		end
	end
	Responsive.Observe(layout)
end

local function createMarker(entry: ProgressEntry): { Holder: Frame, Label: TextLabel }
	local isSelf = entry.UserId == player.UserId

	-- Sized for the current viewport at creation, since markers are built when a
	-- race starts rather than at boot -- layout() keeps any already on the track
	-- in step after that.
	local markerSize = Responsive.Px(MARKER_SIZE)

	local holder = Instance.new("Frame")
	holder.Name = tostring(entry.UserId)
	holder.Size = UDim2.fromOffset(markerSize, markerSize)
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

	local nameWidth = Responsive.Px(NAME_WIDTH)
	local nameHeight = Responsive.Px(NAME_HEIGHT)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(nameWidth, nameHeight)
	label.Position = UDim2.fromOffset(-(nameWidth + Responsive.Px(NAME_GAP)), markerSize / 2 - nameHeight / 2)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.Heading
	label.Text = if isSelf then "YOU" else entry.Name
	label.TextSize = Responsive.Text(NAME_TEXT)
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
