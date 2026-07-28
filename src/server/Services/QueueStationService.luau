local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)

local MatchService = require(script.Parent.MatchService)
local NeonGlowService = require(script.Parent.NeonGlowService)

-- Waiting ROOMS in the lobby, one per race size. Walk in through the doorway
-- and you're in that room's queue; walk back out and you've left it. When the
-- room holds the number of players it's for, that race starts.
--
-- Presence, not a button press, is the whole interaction. Standing in a room
-- IS being queued, so the room itself shows you the thing you actually want
-- to know -- how many people are in here, and how many more are needed --
-- without reading any UI. It also gives leaving an obvious physical gesture
-- (walk out) instead of a keyboard shortcut nobody discovers.
--
-- There is deliberately NO timer on a room. A room fills or it doesn't; it
-- never starts an under-strength race, and never boots you for waiting too
-- long. The PLAY button's size-agnostic queue keeps its matching window, and
-- the on-screen "PLAY WITH BOTS" offer still appears once a wait stalls, so a
-- room that can't fill is never a trap.
--
-- Built in code rather than authored in Studio, following
-- StageDecorationService: the layout comes entirely from QueueModes, so
-- adding a size is a one-line edit rather than a new room to model and keep
-- in sync with the server's idea of which sizes exist.
local QueueStationService = {}

local ROOM_INNER = 18 -- floor is ROOM_INNER x ROOM_INNER studs
local WALL_HEIGHT = 7
local WALL_THICKNESS = 1
local DOORWAY_WIDTH = 8
local ROOM_SPACING = 26
-- Far side of the plaza, past the trophy.
--
-- The rooms used to sit in the gap between spawn and the plaza centre, which
-- put them first on the walk out of spawn -- so a new player met five doorways
-- before ever seeing the leaderboard or the rank chart, and picked a race
-- without knowing what Elo or rank meant. The order along the walk is now
-- boards (Z 30) -> trophy (Z 0) -> room doorways (Z -13), so the two
-- information boards are read on the way to the thing they explain.
--
-- The row must also clear the trophy itself (Z -8..8 around the plaza
-- centre) or the middle room would be built straight through it -- at this
-- offset the back wall lands at Z -31, well past it.
local ROOM_FORWARD_OFFSET = 62
-- How far above the floor still counts as "in the room", so a jumping player
-- isn't momentarily read as having left.
local ROOM_HEIGHT_TOLERANCE = 12
local PRESENCE_INTERVAL = 0.3

local FLOOR_COLOR = Color3.fromRGB(88, 101, 242)
local FLOOR_COLOR_CUSTOM = Color3.fromRGB(168, 85, 247)
local WALL_COLOR = Color3.fromRGB(58, 62, 120)

type Room = {
	mode: QueueModes.Mode,
	cframe: CFrame,
	countLabel: TextLabel,
	floor: BasePart,
}

local rooms: { Room } = {}
-- userId -> index into `rooms`, i.e. which room they were standing in on the
-- previous sweep. The queue is only touched on a CHANGE, so a player standing
-- still isn't re-enqueued several times a second.
local occupantRoom: { [number]: number } = {}
-- The size the custom room is currently set to, or nil when nobody has
-- chosen one. Deliberately a property of the ROOM, not of each player: two
-- occupants who had each picked their own number would sit in two different
-- queues, in the same room, neither of which can ever fill -- the room would
-- look full and never start. So the first person in picks, everyone who joins
-- them races at that size, and it resets to nil the moment the room empties,
-- leaving the next person free to pick again rather than inheriting a size
-- somebody else chose earlier.
local customTarget: number? = nil
-- Index of the custom room in `rooms`, recorded at build time rather than
-- searched for on every sweep.
local customRoomIndex: number? = nil
local openPickerRemote: RemoteEvent

local function getLobbySpawn(): CFrame
	local spawnPart = Workspace:FindFirstChild("SpawnLocation")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame
	end
	return CFrame.new(0, 3, 0)
end

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildSign(anchor: BasePart, mode: QueueModes.Mode): TextLabel
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RoomSign"
	-- Sized in STUDS (the Scale component), not pixels, so a sign shrinks with
	-- distance like the room it labels. A fixed-pixel sign keeps its on-screen
	-- size no matter how far away it is, which was fine when the rooms sat 20
	-- studs from spawn and filled the view -- at the current 62 the five rooms
	-- subtend a much narrower angle, and five same-sized signs collapsed into
	-- one overlapping unreadable band across the middle of the screen.
	--
	-- 18 wide against ROOM_SPACING of 26 leaves a clear gutter between
	-- neighbours at any distance, since both now scale together.
	billboard.Size = UDim2.fromScale(18, 8)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, WALL_HEIGHT * 0.5 + 2, 0)
	billboard.MaxDistance = 200
	billboard.Parent = anchor

	-- Both labels are laid out in SCALE for the same reason the billboard is:
	-- a stud-sized billboard's pixel canvas grows and shrinks with distance, so
	-- offset-positioned children would drift out of the frame as you walk up.
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.55)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = mode.Label
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextStrokeTransparency = 0.35
	title.Parent = billboard

	local count = Instance.new("TextLabel")
	count.Name = "Count"
	count.Size = UDim2.fromScale(1, 0.4)
	count.Position = UDim2.fromScale(0, 0.58)
	count.BackgroundTransparency = 1
	count.Font = Enum.Font.GothamBold
	count.Text = ""
	count.TextScaled = true
	count.TextColor3 = Color3.fromRGB(210, 214, 245)
	count.TextStrokeTransparency = 0.5
	count.Parent = billboard

	return count
end

-- Three solid walls plus a front wall split around a doorway, so a room reads
-- as a room from outside and has exactly one obvious way in and out.
local function buildWalls(model: Model, base: CFrame, color: Color3)
	local half = ROOM_INNER / 2
	local wallY = WALL_HEIGHT / 2
	local span = ROOM_INNER + WALL_THICKNESS * 2
	local lengthwise = Vector3.new(span, WALL_HEIGHT, WALL_THICKNESS)
	local crosswise = Vector3.new(WALL_THICKNESS, WALL_HEIGHT, span)

	-- Back and sides.
	makePart("WallBack", lengthwise, base * CFrame.new(0, wallY, -half), color, model)
	makePart("WallLeft", crosswise, base * CFrame.new(-half, wallY, 0), color, model)
	makePart("WallRight", crosswise, base * CFrame.new(half, wallY, 0), color, model)

	-- Front, split around the doorway.
	local segment = (span - DOORWAY_WIDTH) / 2
	local segmentOffset = (DOORWAY_WIDTH + segment) / 2
	local frontSize = Vector3.new(segment, WALL_HEIGHT, WALL_THICKNESS)
	makePart("WallFrontA", frontSize, base * CFrame.new(-segmentOffset, wallY, half), color, model)
	makePart("WallFrontB", frontSize, base * CFrame.new(segmentOffset, wallY, half), color, model)
end

local function buildRoom(mode: QueueModes.Mode, index: number, total: number)
	local lobby = getLobbySpawn()
	local offset = (index - (total + 1) / 2) * ROOM_SPACING
	local centre = lobby * CFrame.new(offset, 0, -ROOM_FORWARD_OFFSET)
	-- Drop the spawn's pitch/roll; a room must sit flat however the spawn part
	-- happens to be oriented.
	local base = CFrame.new(centre.Position) * CFrame.Angles(0, select(2, lobby:ToOrientation()), 0)

	local model = Instance.new("Model")
	model.Name = "QueueRoom_" .. mode.Id
	model.Parent = Workspace
	CollectionService:AddTag(model, "QueueStation")
	model:SetAttribute("QueueTarget", mode.Target)

	local floor = makePart(
		"Floor",
		Vector3.new(ROOM_INNER, 1, ROOM_INNER),
		base,
		if mode.Custom then FLOOR_COLOR_CUSTOM else FLOOR_COLOR,
		model
	)
	floor.Material = Enum.Material.Neon
	-- Opt the floor in to a real PointLight, so a room casts its colour up its
	-- own walls and out of the doorway instead of just looking bright itself.
	-- The light takes the floor's colour, so the custom room glows violet and
	-- the rest blue with no extra wiring here.
	CollectionService:AddTag(floor, NeonGlowService.Tag)

	buildWalls(model, base, WALL_COLOR)
	model.PrimaryPart = floor

	rooms[index] = {
		mode = mode,
		cframe = base,
		countLabel = buildSign(floor, mode),
		floor = floor,
	}
	if mode.Custom then
		customRoomIndex = index
	end
end

local function isInside(room: Room, position: Vector3): boolean
	local localPosition = room.cframe:PointToObjectSpace(position)
	local half = ROOM_INNER / 2
	return math.abs(localPosition.X) <= half
		and math.abs(localPosition.Z) <= half
		and localPosition.Y >= -2
		and localPosition.Y <= ROOM_HEIGHT_TOLERANCE
end

local function countOccupants(index: number?): number
	if not index then
		return 0
	end
	local total = 0
	for _, roomIndex in occupantRoom do
		if roomIndex == index then
			total += 1
		end
	end
	return total
end

local function roomContaining(position: Vector3): number?
	for index, room in rooms do
		if isInside(room, position) then
			return index
		end
	end
	return nil
end

-- What size this room queues for. Fixed rooms carry their own; the custom
-- room queues for nothing until someone has set it.
local function targetFor(room: Room): number?
	if room.mode.Custom then
		return customTarget
	end
	return room.mode.Target
end

local function onEnterRoom(player: Player, room: Room)
	local target = targetFor(room)
	if target then
		MatchService.Enqueue(player, target)
		return
	end
	-- Custom room with no size set: ask. The picker's reply comes back through
	-- RequestQueueMode, which sets the room's size and queues them if they're
	-- still standing here.
	openPickerRemote:FireClient(player, true)
end

local function onLeaveRoom(player: Player, room: Room)
	-- Walking out with the size picker still up would leave it floating over
	-- the lobby, able to queue them for a room they're no longer standing in.
	-- Closing it here keeps the picker tied to the room that raised it.
	if room.mode.Custom then
		openPickerRemote:FireClient(player, false)
	end

	-- The room emptying because its race STARTED looks exactly like walking
	-- out: the participants get teleported to the stage, so the next sweep
	-- finds them outside. Quitting them here would cancel the race they just
	-- filled, one tick after it began -- so only act on someone who is still
	-- actually sitting in a queue.
	if not MatchService.IsQueued(player) then
		return
	end
	-- Same path the CANCEL button uses; it deliberately does NOT teleport
	-- anyone who never made it onto a stage. See MatchService.QuitMatch.
	MatchService.QuitMatch(player)
end

-- Presence sweep. Reading positions rather than listening to Touched because
-- "are you standing in here right now" is the actual rule -- Touched fires on
-- entry and never tells us about the walk back out, which is exactly the
-- gesture this design leans on.
local function startPresenceLoop()
	task.spawn(function()
		while true do
			task.wait(PRESENCE_INTERVAL)

			for _, player in Players:GetPlayers() do
				local userId = player.UserId
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				local current = if root then roomContaining(root.Position) else nil
				local previous = occupantRoom[userId]

				if current ~= previous then
					occupantRoom[userId] = current
					if previous then
						onLeaveRoom(player, rooms[previous])
					end
					if current then
						onEnterRoom(player, rooms[current])
					end
				end
			end

			-- Catch up anyone standing in the custom room who still isn't
			-- queued. Happens when SOMEBODY ELSE set the size while their
			-- picker was open: their own choice never lands (the room is
			-- already set), and entry only fires on a transition, so without
			-- this they'd stand in a room they can see filling and never be
			-- part of it. Their stale picker is dismissed at the same time.
			if customTarget and customRoomIndex then
				for _, player in Players:GetPlayers() do
					if occupantRoom[player.UserId] == customRoomIndex and not MatchService.IsQueued(player) then
						openPickerRemote:FireClient(player, false)
						MatchService.Enqueue(player, customTarget)
					end
				end
			end

			-- Once the custom room is empty its size is forgotten, so the next
			-- person to walk in is asked fresh instead of being silently
			-- dropped into whatever the last group happened to pick.
			if customTarget and countOccupants(customRoomIndex) == 0 then
				customTarget = nil
			end
		end
	end)
end

-- Repaints each room's "in here / needed" sign. A poll rather than an event
-- from MatchService: counts change on entry, exit, disconnect and race start,
-- and this covers all four without MatchService having to know the sign
-- exists.
local function startCountRefresh()
	task.spawn(function()
		while true do
			task.wait(0.4)
			for _, room in rooms do
				if room.mode.Custom then
					-- Reads like a fixed room once someone has set the size,
					-- so passers-by can see what they'd be joining and how
					-- close it is to starting.
					room.countLabel.Text = if customTarget
						then ("%d / %d"):format(MatchService.GetQueueCount(customTarget), customTarget)
						else "PICK A SIZE"
				else
					local waiting = MatchService.GetQueueCount(room.mode.Target)
					room.countLabel.Text = ("%d / %d"):format(waiting, room.mode.Target)
				end
			end
		end
	end)
end

function QueueStationService.Init()
	openPickerRemote = Net.CreateRemoteEvent(RemoteNames.OpenCustomQueuePicker)

	-- Clear any rooms already in the world before building. These are created
	-- at runtime, but Workspace changes made while testing in Studio persist
	-- if the place is saved -- so without this a saved session would come back
	-- with a second row of rooms overlapping the first.
	for _, existing in CollectionService:GetTagged("QueueStation") do
		existing:Destroy()
	end

	local total = #QueueModes.Stations
	for index, mode in QueueModes.Stations do
		buildRoom(mode, index, total)
	end

	-- The custom picker's "join" click comes back here. Validated server-side:
	-- a client can send any number it likes, and an unvalidated target would
	-- let someone queue for a 1-player "race" (instant win, full points) or a
	-- 500-player one that could never fill.
	local requestModeRemote = Net.CreateRemoteEvent(RemoteNames.RequestQueueMode)
	requestModeRemote.OnServerEvent:Connect(function(player: Player, target: any)
		if typeof(target) ~= "number" or not QueueModes.IsValidTarget(target) then
			return
		end
		-- Only act if they're still standing in the custom room -- they may
		-- have wandered out while the picker was open, and queueing someone
		-- for a room they've left would break the rule that presence IS the
		-- queue (nothing would ever take them back out of it).
		local index = occupantRoom[player.UserId]
		local room = index and rooms[index]
		if not (room and room.mode.Custom) then
			return
		end

		-- First chooser sets the room; anyone who picked at the same moment
		-- joins at the size already set rather than overwriting it, which
		-- would strand whoever was queued under the previous number.
		if not customTarget then
			customTarget = target
		end
		MatchService.Enqueue(player, customTarget)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		occupantRoom[player.UserId] = nil
	end)

	startPresenceLoop()
	startCountRefresh()
end

return QueueStationService
