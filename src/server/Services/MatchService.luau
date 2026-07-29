local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local QueueModes = require(Shared.QueueModes)
local Stages = require(Shared.Stages)
local RankTiers = require(Shared.RankTiers)

local AbilityService = require(script.Parent.AbilityService)
local BadgeMilestoneService = require(script.Parent.BadgeMilestoneService)
local BotService = require(script.Parent.BotService)
local EloService = require(script.Parent.EloService)
local HypeFeedService = require(script.Parent.HypeFeedService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local LeaderstatsService = require(script.Parent.LeaderstatsService)
local LobbyService = require(script.Parent.LobbyService)
local MonetizationService = require(script.Parent.MonetizationService)
local MovementService = require(script.Parent.MovementService)
local PartyService = require(script.Parent.PartyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ReferralService = require(script.Parent.ReferralService)
local TelemetryService = require(script.Parent.TelemetryService)
local WeatherService = require(script.Parent.WeatherService)

-- Streak level N (2 wins in a row = level 1) is worth STREAK_BONUS_PER_LEVEL
-- extra points, capped at STREAK_BONUS_MAX_LEVEL so it stays a fun escalation
-- instead of spiraling.
local STREAK_BONUS_PER_LEVEL = 10
local STREAK_BONUS_MAX_LEVEL = 5

local function streakBonusPoints(winStreak: number): number
	local level = math.clamp(winStreak - 1, 0, STREAK_BONUS_MAX_LEVEL)
	return level * STREAK_BONUS_PER_LEVEL
end

-- Flow: touch a start line / click Play -> shared queue -> once the waiting
-- window ends, roll a random stage and teleport everyone there (still
-- third-person, no finish-line detection yet) -> a short pre-race countdown
-- plays on the map itself -> THEN the race actually starts (first-person,
-- timer running, finish-line detection live). Whoever crosses the finish
-- line first is the winner against every other participant still racing at
-- that moment (2nd/3rd place etc. still "lost" the heat).
local MatchService = {}

type Session = {
	-- Unique per race. Several races can share a stage now (see `sessions`), so
	-- the stage id no longer identifies one.
	id: number,
	-- Net rating change so far this race, per userId. Accumulated as each pair
	-- is settled and reported to a player only when they themselves finish --
	-- firing it the moment someone ahead crosses would pop the results panel in
	-- the face of someone still running the course.
	eloDelta: { [number]: number },
	stageId: string,
	participants: { [number]: Player },
	totalParticipants: number,
	finishedCount: number,
	winner: Player?,
	startTime: number,
	-- Players who finished/lost but stuck around to watch the rest of the
	-- race instead of being yanked straight back to the lobby (see
	-- PlayerReachedFinish/MatchService.LeaveSpectate). Rounded up and sent
	-- to the lobby together once the session actually ends.
	spectators: { [number]: Player },
}

-- One queue per race size (see QueueModes): QueueModes.AnySize is the PLAY
-- button's size-agnostic queue, any other key is a lobby station demanding
-- exactly that many racers. Keyed by target rather than held in one list so a
-- station can never accidentally pull in someone who asked for a different
-- size.
local queues: { [number]: { Player } } = {}
-- userId -> which queue they're sitting in. Replaces the old boolean
-- queuedSet: every lookup that used to ask "are they queued at all?" also
-- needs to know WHICH queue to pull them out of.
local queuedTarget: { [number]: number } = {}

-- Countdowns currently running, keyed by the queue they belong to. Several run
-- at once now -- one per queue -- so the 1v1 station is never held up behind
-- the PLAY queue's longer matching window.
--
-- Each holds the stage it has already rolled, so that stage can be treated as
-- taken from the moment the reel starts spinning rather than only once players
-- are teleported onto it.
type Pending = {
	stageId: string,
	endTime: number,
}
local pending: { [number]: Pending } = {}

local function getQueue(target: number): { Player }
	local existing = queues[target]
	if existing then
		return existing
	end
	local created = {}
	queues[target] = created
	return created
end

-- How many racers this queue needs before it can start: an exact count for a
-- station, or MinPlayers as a floor for the size-agnostic queue.
local function requiredFor(target: number): number
	if target == QueueModes.AnySize then
		return Constants.Match.MinPlayers
	end
	return target
end
-- Live races, keyed by their own id.
--
-- Keyed by SESSION rather than by stage because waves share courses: a stage
-- can hold a 1v1, a 3-player station race and a 60-second wave all at the
-- same time (players are hidden from anyone outside their own race -- see
-- RaceRosterChanged / RaceVisibilityController -- and characters already can't
-- collide with each other, so overlapping groups never physically interfere).
--
-- The earlier version keyed by stage and treated a course as exclusive, which
-- capped the whole server at four concurrent races. That ceiling is what made
-- a fixed wave cadence impossible: a race every 60 seconds that can run for
-- 300 means five can overlap before any stage frees up.
local sessions: { [number]: Session } = {}
local nextSessionId = 1

-- userId -> the race they are currently RUNNING in. Replaces looking a session
-- up by the player's stage, which stops being unique once several races share
-- a course.
local playerSession: { [number]: Session } = {}

local function sessionFor(userId: number): Session?
	return playerSession[userId]
end

-- Which race this player is SPECTATING, if any. Spectators can't be resolved
-- through playerSession the way racers are -- it's cleared the moment they
-- stop racing -- so this has to be a search.
local function sessionSpectatedBy(userId: number): Session?
	for _, session in sessions do
		if session.spectators[userId] then
			return session
		end
	end
	return nil
end

-- Any stage; courses are shared now, so there is nothing to avoid.
local function rollStage(): string
	return Stages[math.random(1, #Stages)].Id
end

local playerRaceStage: { [number]: string } = {}
-- Most recent checkpoint each player has touched this stage visit, used to
-- recover them in place after a fall instead of sending them all the way
-- back to Platform_Start. Seeded with the stage spawn CFrame the moment
-- they're teleported in, so falling before touching any checkpoint still
-- recovers sensibly.
local lastCheckpoint: { [number]: CFrame } = {}

-- True from the moment a player is enqueued until they either finish their
-- race or get force-reset (watchdog/disconnect). Separate from queuedTarget
-- (only set while literally sitting in a queue) and playerRaceStage (only
-- true once the race has actually started): there's a real gap between
-- those two -- teleported to the stage, waiting out CountdownSeconds, but
-- not yet racing -- during which neither flag was set, so touching another
-- start line in that window would silently re-enqueue the player into a
-- second, overlapping race. playerBusy is the single guard covering the
-- whole span.
local playerBusy: { [number]: boolean } = {}

-- Solo vs-bot matches deliberately do NOT go through `sessions`/the shared
-- queue above. Queued races claim a whole stage for their duration, and there
-- are only four; a bot match holding one for up to MaxDurationSeconds would
-- burn a quarter of the server's race capacity on one player. Each player can run their own bot match fully independently,
-- tracked here by userId instead.
local botMatches: { [number]: { stageId: string, bot: BotService.BotHandle } } = {}

-- Practice mode: same independent-of-the-shared-queue shape as botMatches
-- (see above), but with no opponent at all -- just the player, the clock,
-- and optionally their own ghost (GhostService) to race against. No Elo, no
-- points (unlike a bot match, which still awards points -- practice is
-- meant to stay a genuinely zero-stakes way to learn a stage), but real
-- finish times DO still count for the actual leaderboard: there's no bot to
-- make the time suspect, it's just the player racing the clock alone.
local practiceMatches: { [number]: { stageId: string, startTime: number } } = {}

-- Private 1v1 challenge (see MatchService.RequestDuel/RespondToDuel), from the
-- profile card's "Request 1v1" button. Same independent-of-the-shared-queue
-- shape as botMatches/practiceMatches above (a real race between two SPECIFIC
-- people must never pick up a third stranger from the shared queue, and must
-- never fight the shared queue's own race for the single global session
-- slot) -- but unlike those two, a duel carries the exact same stakes as a
-- real ranked race (Elo, points, Wins/Losses): see finishDuelMatch. Both
-- participants' userIds key into the SAME table so either side's finish/quit
-- can see (and mutate) shared state like `winner`.
type DuelMatch = {
	stageId: string,
	players: { [number]: Player }, -- userId -> Player, removed as each side finishes/leaves
	startTime: number,
	winner: Player?,
}
local duelMatches: { [number]: DuelMatch } = {}

local DUEL_REQUEST_TTL = 30
local pendingDuelRequests: { [number]: { fromUserId: number, expiresAt: number } } = {} -- toUserId -> request

-- Lightweight speed-hack guard: MovementService is now the sole authority
-- over WalkSpeed, which closes the easy "just set WalkSpeed to 500" exploit,
-- but a hacked client can still move its own character faster than that by
-- setting CFrame/AssemblyLinearVelocity directly (Roblox lets the owning
-- client drive its own character's physics). Sampling actual horizontal
-- displacement over time and rubber-banding anyone moving implausibly fast
-- catches that case too, without needing a full movement-replay system.
-- Reuses PlayerFellOff as the correction: same "oops, back to checkpoint"
-- UX a legitimate faller gets, so a cheater isn't tipped off that they were
-- specifically caught.
local SPEED_CHECK_INTERVAL = 1
local MAX_HORIZONTAL_STUDS_PER_CHECK = Constants.SprintSpeed * 1.6 * SPEED_CHECK_INTERVAL

-- nil means "no baseline yet, skip this check" -- deliberately cleared by
-- every *forced* teleport in this module (race start/snap-back, fall/cheat
-- recovery) so none of those ever get mistaken for illegitimate movement.
local lastCheckedPosition: { [number]: Vector3 } = {}

local function checkPlayerSpeed(player: Player, stageId: string)
	local userId = player.UserId
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local last = lastCheckedPosition[userId]
	lastCheckedPosition[userId] = root.Position
	-- Still record the position above even during a grace window (rather
	-- than leaving it nil like a forced teleport does) -- a grace window is
	-- a legitimate SUSTAINED burst, not a snap, so the next check right
	-- after grace ends should compare against wherever it actually left off,
	-- not silently skip once more.
	if not last or MovementService.IsInSpeedCheckGrace(player) then
		return
	end

	local horizontalDelta = Vector3.new(root.Position.X - last.X, 0, root.Position.Z - last.Z)
	if horizontalDelta.Magnitude > MAX_HORIZONTAL_STUDS_PER_CHECK then
		MatchService.PlayerFellOff(player, stageId)
	end
end

local function startSpeedWatchdog()
	task.spawn(function()
		while true do
			task.wait(SPEED_CHECK_INTERVAL)
			for userId, stageId in playerRaceStage do
				local player = Players:GetPlayerByUserId(userId)
				if player then
					checkPlayerSpeed(player, stageId)
				end
			end
		end
	end)
end

local queueStatusRemote: RemoteEvent
local preRaceCountdownRemote: RemoteEvent
local raceRosterRemote: RemoteEvent
local waveClockRemote: RemoteEvent
local racePositionRemote: RemoteEvent
local raceProgressRemote: RemoteEvent
local raceOutcomeRemote: RemoteEvent
local mapSelectedRemote: RemoteEvent
local playerFellRemote: RemoteEvent
local spectateStatusRemote: RemoteEvent
local practiceCompleteRemote: RemoteEvent
local queueRejectedRemote: RemoteEvent
local duelRequestReceivedRemote: RemoteEvent
local duelCancelledRemote: RemoteEvent

local broadcastRoster: (session: Session) -> ()
local tryStartCountdown: () -> ()
local startSession: (target: number, stageId: string?, roster: { Player }?) -> ()
local beginRace: (stageId: string, participants: { [number]: Player }) -> ()
local endSession: () -> ()
local awardWalkover: (session: Session) -> boolean

-- Levels are built directly in Studio (not synced from src/), following the
-- convention Workspace.Stages.<StageId>.<StageId>Spawn for each stage's spawn point.
local function getStageSpawnPart(stageId: string): BasePart?
	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	local spawnPart = stageFolder and stageFolder:FindFirstChild(stageId .. "Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart
	end
	return nil
end

local function getStageSpawnCFrame(stageId: string): CFrame?
	local spawnPart = getStageSpawnPart(stageId)
	return spawnPart and spawnPart.CFrame + Vector3.new(0, 3, 0)
end

-- Where each racer of a wave starts, so an uncapped field spreads across a
-- start grid instead of every player being dropped on one CFrame and standing
-- inside each other until the physics shoves them apart.
--
-- Rows build BACKWARDS from the start line rather than sideways only: a wide
-- enough single row would put the outer racers off the edge of the platform on
-- the narrower stages, whereas depth is always available behind the line.
-- Everyone is still behind the same line, so no row gets a head start.
--
-- The grid is fitted to the ACTUAL spawn pad rather than laid out on fixed
-- constants. A fixed 6-column grid put a 4-player wave at -12.5..+2.5 studs --
-- both lopsided (centred on six slots while only four existed) and, on the
-- narrower pads, hanging over the edge, so players spent the countdown falling.
-- Overlapping is the safe failure here and dropping off the pad is not, so when
-- a field genuinely cannot fit, spacing shrinks rather than the grid growing:
-- characters can't collide with each other anyway (see BotService's collision
-- group), so a tight grid looks crowded and nothing worse.
local START_GRID_SPACING = 5
-- Keeps the outermost racer's body clear of the lip of the pad.
local START_GRID_MARGIN = 3

local function buildStartGrid(spawnCFrame: CFrame, padSize: Vector3, count: number): { CFrame }
	-- X is a span centred on the spawn point, so the whole width less both
	-- margins is available. Z is not: rows only ever build BACKWARDS from the
	-- spawn point, so the depth to play with is the half-pad behind it.
	local usableX = math.max(0, padSize.X - START_GRID_MARGIN * 2)
	local usableZ = math.max(0, padSize.Z / 2 - START_GRID_MARGIN)

	-- Never more columns than there are racers, so a small field is a single
	-- centred row instead of the left-hand end of a wide one.
	local columns = math.clamp(math.floor(usableX / START_GRID_SPACING) + 1, 1, count)
	local rows = math.ceil(count / columns)

	local spacingX = if columns > 1 then math.min(START_GRID_SPACING, usableX / (columns - 1)) else 0
	local spacingZ = if rows > 1 then math.min(START_GRID_SPACING, usableZ / (rows - 1)) else 0

	local grid = table.create(count)
	for index = 1, count do
		local slot = index - 1
		local column = slot % columns
		local row = math.floor(slot / columns)
		-- Centred on how many are actually IN this row, so a part-filled back
		-- row sits under the middle of the one in front rather than flush left.
		local inThisRow = math.min(columns, count - row * columns)
		local offsetX = (column - (inThisRow - 1) / 2) * spacingX
		local offsetZ = row * spacingZ
		-- Applied in the spawn's own space, so the grid follows however the
		-- stage's spawn part is rotated -- "back" is always back relative to
		-- the course.
		grid[index] = spawnCFrame * CFrame.new(offsetX, 0, offsetZ)
	end
	return grid
end

local function getLobbySpawnCFrame(): CFrame?
	local spawnPart = Workspace:FindFirstChild("SpawnLocation")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame + Vector3.new(0, 3, 0)
	end
	return nil
end

-- Anchoring a player's own HumanoidRootPart from the server does NOT stick on
-- its own: the character is network-owned by its client, and the client's
-- physics stream keeps re-asserting its own state over the top. Measured in
-- Studio -- the server sets Anchored = true, and ~2.3s into the 8s pre-race
-- countdown it flips back to false by itself, with nothing in this codebase
-- touching it. Spamming jump is what makes it obvious, because that's what
-- forces the client to push physics updates out.
--
-- Taking network ownership (nil = the server simulates it) is what actually
-- makes the anchor hold. Order matters in both directions: Roblox refuses to
-- set network ownership on an already-anchored part, so ownership has to be
-- taken BEFORE anchoring and handed back AFTER un-anchoring.
local function setRootAnchored(root: BasePart, player: Player?, anchored: boolean)
	if anchored then
		root:SetNetworkOwner(nil)
		root.Anchored = true
	else
		root.Anchored = false
		-- Back to the owning client, so their own movement stays locally
		-- simulated and responsive rather than round-tripping to the server.
		root:SetNetworkOwner(player)
	end
end

-- Warps a participant to the stage's spawn regardless of where they wandered
-- off to during the countdown, so everyone actually starts the race together.
-- pcall'd so one player's stale/missing character can't abort session start
-- for everyone else in the loop that calls this. Every call site here is a
-- forced teleport (race entry, anti-headstart snap-back, or return to
-- lobby), so this is also the one place the speed-watchdog baseline gets
-- cleared -- none of these jumps should ever be mistaken for cheating.
-- Strips any live "launch" physics off a character's root.
--
-- Zeroing AssemblyLinearVelocity is NOT enough on its own, which is the whole
-- reason this exists. A bounce pad (StageGimmickService) and the Dash/Blink
-- abilities don't write a velocity -- they parent a LinearVelocity or
-- BodyVelocity CONSTRAINT to the root, deliberately, because a server-side
-- velocity write gets thrown away by the owning client's next physics frame.
-- A constraint keeps re-asserting its velocity every frame until it's
-- destroyed, so a player recovered mid-bounce has their velocity zeroed and
-- then immediately re-launched by the constraint that outlived the teleport --
-- arriving at their checkpoint and being fired straight off it again. That's
-- the "I died on a boost pad and respawned with a jump boost" bug.
--
-- Sibling of the MovementService.ClearSpeedOverride call that already sits on
-- the recovery path for exactly the same reason: Stage4's speed strip used to
-- survive a fall the same way, just through WalkSpeed instead of a constraint.
local function clearLaunchers(root: BasePart)
	for _, child in root:GetChildren() do
		-- BodyMover covers BodyVelocity/BodyForce/BodyThrust; LinearVelocity is
		-- the newer constraint the bounce pads use. BounceAttachment is the
		-- anchor point the latter hangs off, orphaned once its mover is gone.
		if child:IsA("BodyMover") or child:IsA("LinearVelocity") or child.Name == "BounceAttachment" then
			child:Destroy()
		end
	end
end

local function teleportToStageSpawn(player: Player, spawnCFrame: CFrame)
	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			clearLaunchers(root)
			root.CFrame = spawnCFrame
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			-- Always un-anchor here, even for a player who was never parked
			-- (harmless no-op then) -- this is the one shared path every
			-- "send a spectator somewhere real again" call goes through (see
			-- returnSpectatorToLobby), so it's the right place to guarantee
			-- parkSpectator's Anchored = true never outlives the spectate
			-- session it was set for -- including handing network ownership
			-- back to the client, which parking took away (see setRootAnchored).
			setRootAnchored(root, player, false)
		end
	end)
	lastCheckedPosition[player.UserId] = nil
end

-- Moves a fresh spectator's own character straight up and freezes it there
-- (same Anchored mechanism setFrozen already uses for the pre-race
-- countdown) rather than leaving it sitting wherever they finished. Without
-- this, a still-racing player can walk right into/through a spectator's
-- parked body -- player-vs-player collision is deliberately off (see
-- BotService's collision groups) -- and end up standing exactly where they
-- are. When that happens, the spectate camera (correctly aimed at the
-- RACER's own CameraSubject) ends up rendering whichever of the two
-- overlapping characters happens to face the lens, which can be the
-- spectator's own body instead of the racer being watched -- confirmed via
-- screenshot: the UI correctly named the real racer, but the on-screen
-- character was unmistakably someone standing right on top of them. Parking
-- spectators well clear of the course makes that overlap impossible
-- regardless of how small or cramped a given stage is.
local SPECTATOR_PARK_OFFSET = Vector3.new(0, 60, 0)

local function parkSpectator(player: Player)
	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.CFrame = root.CFrame + SPECTATOR_PARK_OFFSET
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			-- Same client-ownership caveat as the pre-race freeze: a bare
			-- Anchored = true here would quietly come undone a couple of
			-- seconds later and drop the spectator back onto the course.
			setRootAnchored(root, player, true)
		end
	end)
end

-- Locks a participant fully in place for the pre-race countdown. Used to be
-- a "free warm-up" (see startSession/beginRace's own comments) where players
-- could already wander the course before the timer started -- now they're
-- anchored instead, so the countdown actually means "can't move yet."
-- Anchoring the root part (rather than e.g. zeroing WalkSpeed) blocks every
-- movement vector at once -- walking, jumping, a Dash/Blink impulse -- not
-- just the ones that go through MovementService's WalkSpeed authority.
-- pcall'd for the same reason teleportToStageSpawn is: a stale/missing
-- character on one participant can't be allowed to abort the loop for
-- everyone else. Safe to call with frozen = false on a player who was never
-- actually frozen (Quit/cancel paths do this defensively) -- it's just a
-- harmless Anchored = false no-op.
local function setFrozen(player: Player, frozen: boolean)
	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			setRootAnchored(root, player, frozen)
		end
	end)
end

-- Every queue that is ready and doesn't already have a countdown running.
--
-- This used to pick exactly ONE queue and return, because only one race could
-- exist at a time. Now each ready queue gets its own countdown, so a full 1v1
-- station starts immediately instead of waiting out an unrelated race.
local function readyTargets(): { number }
	local ready = {}

	-- Stations first and in ascending size order, so when stages are scarce a
	-- complete group claims one before the any-size queue, which is always
	-- willing to wait for one more player anyway.
	for _, mode in QueueModes.Stations do
		local target = mode.Target
		if target ~= QueueModes.AnySize and not pending[target] and #getQueue(target) >= target then
			table.insert(ready, target)
		end
	end

	-- Custom stations can create queues at sizes no fixed station uses, so they
	-- need their own sweep rather than being covered by the loop above.
	for target, waiting in queues do
		if target ~= QueueModes.AnySize and not pending[target] and #waiting >= target then
			if not table.find(ready, target) then
				table.insert(ready, target)
			end
		end
	end

	-- QueueModes.AnySize is deliberately absent: the PLAY queue no longer starts
	-- when it happens to fill, it leaves on the wave clock (see startWaveClock).
	return ready
end

local function beginCountdown(target: number, stageId: string, window: number)
	pending[target] = { stageId = stageId, endTime = os.clock() + window }

	-- Tell EVERYONE already in the queue, not just whoever's Enqueue call
	-- happened to tip it over the threshold. This is where the "the other
	-- player never saw the map-reveal spin" bug lived: the countdown/
	-- MapSelected broadcast used to live only in Enqueue, firing at the
	-- enqueuing party. So the FIRST player to click Play (queued while the
	-- queue was still under MinPlayers, and sent a static `true` "waiting for
	-- players") got nothing further when the second player's click actually
	-- started the countdown -- no ticking number, no MapSelected, so
	-- MapRevealController had no stage to spin to and stayed silent right up
	-- until the teleport. The second player saw the whole thing, which is
	-- exactly why it looked like it only broke for "the other player."
	for _, queuedPlayer in getQueue(target) do
		queueStatusRemote:FireClient(queuedPlayer, window)
		mapSelectedRemote:FireClient(queuedPlayer, stageId)
	end

	-- window is the COUNTDOWN the client shows; the reel then spins for
	-- MapRevealSeconds on top of it before anyone is teleported (see
	-- Constants.Match.MapRevealSeconds). The teleport has to wait for both or
	-- the reveal would be cut off mid-spin by the stage loading around it.
	task.delay(window + Constants.Match.MapRevealSeconds, function()
		pending[target] = nil
		startSession(target, stageId)
	end)
end

-- The PLAY queue's departure clock: one wave every Constants.Match.WaveSeconds,
-- uncapped, carrying everyone queued at that moment.
--
-- The stage is rolled at the START of each wave window rather than at its end,
-- so anyone who joins partway through can immediately be shown the same map and
-- the same remaining time as everyone already waiting.
--
-- A wave with fewer than MinPlayers is skipped rather than launched: a solo
-- "race" pays full points and win-streak credit with no opponent to lose Elo
-- against, which is a free repeatable reward, not just a dull race.
local waveStageId: string = ""
local waveDepartsAt = 0

local function waveSecondsRemaining(): number
	return math.max(0, waveDepartsAt - os.clock())
end

local function startWaveClock()
	task.spawn(function()
		while true do
			waveStageId = rollStage()
			waveDepartsAt = os.clock() + Constants.Match.WaveSeconds

			-- Broadcast to the whole server, not just the queue: the point of
			-- the lobby clock is that someone who hasn't pressed PLAY can see
			-- how long they have to decide.
			if waveClockRemote then
				waveClockRemote:FireAllClients(Constants.Match.WaveSeconds)
			end

			-- Anyone already waiting is told about the new window immediately;
			-- late joiners are caught up by Enqueue.
			for _, queuedPlayer in getQueue(QueueModes.AnySize) do
				queueStatusRemote:FireClient(queuedPlayer, Constants.Match.WaveSeconds)
				mapSelectedRemote:FireClient(queuedPlayer, waveStageId)
			end

			task.wait(Constants.Match.WaveSeconds)

			if #getQueue(QueueModes.AnySize) >= Constants.Match.MinPlayers then
				local departing = waveStageId
				-- Take the passengers OUT of the queue right now, at departure,
				-- and hand them to startSession explicitly.
				--
				-- Letting startSession clear the queue itself was a race: this
				-- loop continues the instant the delay is scheduled, rolls the
				-- NEXT wave's stage, and broadcasts it to everyone still listed
				-- as queued -- which, for the MapRevealSeconds the reel is
				-- spinning, is exactly the people who just departed. They'd get
				-- a second map reveal for a stage they aren't going to, on top
				-- of their own pre-race countdown.
				local passengers = getQueue(QueueModes.AnySize)
				queues[QueueModes.AnySize] = {}
				-- The reel spins for MapRevealSeconds after the clock hits zero,
				-- and the teleport waits for it -- same pacing as a station race.
				task.delay(Constants.Match.MapRevealSeconds, function()
					startSession(QueueModes.AnySize, departing, passengers)
				end)
			else
				-- Nobody (or one person) waiting: tell whoever IS there that the
				-- wave didn't go, so their countdown doesn't sit at zero.
				for _, queuedPlayer in getQueue(QueueModes.AnySize) do
					queueStatusRemote:FireClient(queuedPlayer, true)
				end
			end
		end
	end)
end

function tryStartCountdown()
	for _, target in readyTargets() do
		-- A full station has its group already; the only reason to wait at all
		-- is to let the map-reveal reel play.
		beginCountdown(target, rollStage(), Constants.Match.SoloRevealSeconds)
	end
end

-- Teleports the matched group to the chosen stage. They stay in "Lobby"
-- (first-person, but frozen in place -- see setFrozen) for CountdownSeconds
-- so everyone gets a moment to see the map before the clock starts.
function startSession(target: number, stageId: string?, roster: { Player }?)
	-- `roster` is for callers that already pulled their group out of the queue
	-- (the wave clock, which must do so at departure -- see startWaveClock).
	-- Everyone else hands over the queue as it stands.
	local queued = roster or getQueue(target)
	queues[target] = {}

	-- An exact-size station must still have its exact number; the any-size
	-- queue only needs the floor. Either way, dropping below it during the
	-- window (someone quit) means putting whoever's left back rather than
	-- starting an under-strength -- or solo -- race. tryStartCountdown picks
	-- them back up automatically on the next Enqueue.
	if #queued < requiredFor(target) or not stageId then
		local restored = getQueue(target)
		for _, player in queued do
			if player.Parent then
				table.insert(restored, player)
				queuedTarget[player.UserId] = target
				queueStatusRemote:FireClient(player, true)
			end
		end
		return
	end

	-- No player cap. A wave takes everyone who queued for it, however many that
	-- is -- the reason a cap existed (a spawn pad only fits so many before
	-- players stand inside each other) is handled by spreading the start line
	-- out instead, see buildStartGrid.
	local spawnPart = getStageSpawnPart(stageId)
	local spawnCFrame = getStageSpawnCFrame(stageId)
	local grid = if spawnPart and spawnCFrame
		then buildStartGrid(spawnCFrame, spawnPart.Size, #queued)
		else nil

	local participants: { [number]: Player } = {}
	local gridIndex = 0
	for _, player in queued do
		queuedTarget[player.UserId] = nil
		if player.Parent then
			participants[player.UserId] = player
			-- Set as soon as they're teleported (not just once the race timer
			-- starts) so fall-recovery already works during the pre-race
			-- countdown, not only once CountdownSeconds elapses.
			playerRaceStage[player.UserId] = stageId
			if grid then
				gridIndex += 1
				local startCFrame = grid[gridIndex]
				teleportToStageSpawn(player, startCFrame)
				-- Their own grid slot is the first checkpoint, so an early fall
				-- returns them to where they actually started rather than to a
				-- pile-up on someone else's slot.
				lastCheckpoint[player.UserId] = startCFrame
			end
			queueStatusRemote:FireClient(player, nil)
			preRaceCountdownRemote:FireClient(player, Constants.Match.CountdownSeconds)
			setFrozen(player, true)
			TelemetryService.MatchStep(player, "Matched")
		end
	end

	if next(participants) == nil then
		return
	end

	task.delay(Constants.Match.CountdownSeconds, function()
		beginRace(stageId, participants)
	end)

	-- Any station queue that filled while this one was counting down can start
	-- immediately -- there is no longer a stage to wait for.
	tryStartCountdown()
end

-- Actually starts the race: first-person camera (via the Racing state),
-- timer running, finish-line detection live.
function beginRace(stageId: string, participants: { [number]: Player })
	local validParticipants: { [number]: Player } = {}
	local totalParticipants = 0
	for userId, player in participants do
		-- playerRaceStage is cleared by QuitMatch, so this also filters out
		-- anyone who hit Backspace during the pre-race countdown -- without it
		-- they'd be teleported back onto the stage and flipped to "Racing"
		-- again by the very loop below, undoing the quit they just made.
		if player.Parent and playerRaceStage[userId] == stageId then
			validParticipants[userId] = player
			totalParticipants += 1
		end
	end
	if totalParticipants == 0 then
		return
	end

	-- Players were frozen in place for CountdownSeconds (see setFrozen), not
	-- just left to wander -- but still snap everyone here rather than trusting
	-- wherever they were frozen at, since e.g. a respawn mid-countdown would've
	-- left them unfrozen at whatever spot the default spawn put them.
	--
	-- Snapped back to their own GRID SLOT, not the bare spawn point. Using the
	-- spawn point undid the whole start grid at the instant it mattered: the
	-- field spread out for the countdown and then teleported into one stack on
	-- GO. lastCheckpoint holds the slot startSession assigned, and they were
	-- frozen the whole countdown, so it's still exactly where they should be.
	local spawnCFrame = getStageSpawnCFrame(stageId)
	for userId, player in validParticipants do
		local startCFrame = lastCheckpoint[userId] or spawnCFrame
		if startCFrame then
			teleportToStageSpawn(player, startCFrame)
			lastCheckpoint[userId] = startCFrame
		end
		setFrozen(player, false)
		LobbyService.SetPlayerState(player, "Racing")
		AbilityService.ResetCooldown(player)
		-- Everyone starts the clock at the same speed. Anything picked up
		-- before GO -- a Stage4 speed strip stood on during the countdown --
		-- is wiped here rather than carried across the start line.
		MovementService.ClearSpeedOverride(player)
		TelemetryService.MatchStep(player, "Started")
		TelemetryService.Onboarding(player, "FirstRace")
	end
	local session: Session = {
		id = nextSessionId,
		stageId = stageId,
		participants = validParticipants,
		totalParticipants = totalParticipants,
		finishedCount = 0,
		eloDelta = {},
		winner = nil,
		startTime = os.clock(),
		spectators = {},
	}
	sessions[nextSessionId] = session
	nextSessionId += 1
	for userId in validParticipants do
		playerSession[userId] = session
	end
	broadcastRoster(session)

	-- Everyone else bailed during the countdown (a session never starts below
	-- Constants.Match.MinPlayers, so one participant here means departures).
	-- Nobody left to race, so the survivor takes it rather than being sent
	-- alone round a course with no opponent.
	if totalParticipants == 1 and awardWalkover(session) then
		return
	end

	-- Nobody has finished yet, so everyone starts tied for 1st.
	for _, racer in validParticipants do
		racePositionRemote:FireClient(racer, 1, totalParticipants)
	end

	-- Watchdog: if the race never finishes (e.g. everyone AFKs), reset the
	-- stage rather than leaving it permanently stuck.
	task.delay(Constants.Match.MaxDurationSeconds, function()
		if sessions[session.id] ~= session then
			return
		end

		for _, straggler in session.participants do
			playerRaceStage[straggler.UserId] = nil
			playerBusy[straggler.UserId] = nil
			lastCheckpoint[straggler.UserId] = nil
			LobbyService.SetPlayerState(straggler, "Lobby")
		end

		endSession(session)
	end)
end

-- Sends a still-spectating player back to the lobby -- shared by endSession
-- (everyone left watching once the race is actually over) and
-- MatchService.LeaveSpectate (one spectator bailing out early).
local function returnSpectatorToLobby(player: Player)
	LobbyService.SetPlayerState(player, "Lobby")
	local lobbyCFrame = getLobbySpawnCFrame()
	if lobbyCFrame then
		teleportToStageSpawn(player, lobbyCFrame)
	end
end

-- Tells everyone in a race who else is in it, so each client can hide every
-- character that ISN'T (see RaceVisibilityController).
--
-- Necessary because stages are shared: a single course can be carrying a 1v1,
-- a 3-player station race and a 60-second wave at once, and without this a
-- racer would see a crowd of strangers and have no idea which of them they are
-- actually racing. Purely a visual concern -- player characters already can't
-- collide with each other (see BotService's collision groups), so the ones
-- being hidden could never have blocked or pushed anyone anyway.
--
-- Spectators get the roster too: they're watching this race, so they should
-- see exactly the same set of people the racers do.
function broadcastRoster(session: Session)
	local roster = {}
	for userId in session.participants do
		table.insert(roster, userId)
	end
	for _, player in session.participants do
		raceRosterRemote:FireClient(player, roster)
	end
	for _, spectator in session.spectators do
		raceRosterRemote:FireClient(spectator, roster)
	end
end

-- Sends every spectator the current list of still-racing Players (not just a
-- count) so the client can let them pick who to watch and point their camera
-- at that specific racer -- see SpectateController. Called any time
-- session.participants changes while spectators exist: a finish, a quit, or
-- a disconnect all need to keep every spectator's watch-list in sync,
-- otherwise someone could end up "watching" a racer who already left.
local function broadcastSpectatorRacers(session: Session)
	if next(session.spectators) == nil then
		return
	end
	local racers = {}
	for _, racer in session.participants do
		table.insert(racers, racer)
	end
	for _, spectator in session.spectators do
		spectateStatusRemote:FireClient(spectator, racers)
	end
end

-- Retires ONE race. Takes the session explicitly rather than reading a global
-- slot: with races running in parallel, "the active session" is no longer a
-- meaningful phrase, and a finishing Stage 1 race must not tear down a Stage 3
-- race that happens to still be going.
function endSession(session: Session?)
	if not session then
		return
	end
	for _, spectator in session.spectators do
		returnSpectatorToLobby(spectator)
	end
	-- Guarded: only clear the slot if it still holds THIS session, so a late
	-- endSession (e.g. the AFK watchdog firing after a normal finish already
	-- cleaned up and a new race started on the same stage) can't evict its
	-- successor.
	if sessions[session.id] == session then
		sessions[session.id] = nil
	end
	-- The stage this race was using is free now, so a queue that was waiting on
	-- one can finally start.
	tryStartCountdown()
end

-- Partied players (see PartyService) are enqueued together in one atomic
-- pass -- every member gets added to the shared `queue` before this function
-- returns, so whichever `startSession` call grabs the queue next is
-- guaranteed to grab all of them together, regardless of exactly when each
-- member's own PLAY click happened. If any party member is already busy,
-- nobody is enqueued: a partial-party queue would just separate them anyway.
function MatchService.Enqueue(player: Player, target: number?)
	local partyMembers = PartyService.GetPartyMembers(player)

	-- Read BEFORE tryStartCountdown below, which may start one: it decides
	-- whether tryStartCountdown's whole-queue broadcast already covered these
	-- members, or whether they joined a window that was already ticking and
	-- need to be caught up individually. See the branch at the end.
	-- Captured per-queue: with several countdowns able to run at once, "was a
	-- countdown running" is only ever a question about THIS queue.
	local queueTargetForCatchUp = target or QueueModes.AnySize
	local countdownWasRunning = pending[queueTargetForCatchUp] ~= nil

	for _, member in partyMembers do
		if playerBusy[member.UserId] then
			-- The caller's own client already guards against double-clicking
			-- (see PlayButtonController's `busy` flag), so the only way to
			-- land here is a DIFFERENT party member being busy -- something
			-- the caller's client has no way to know on its own. Without this,
			-- the caller's UI already optimistically shows "QUEUED..." the
			-- instant they clicked and would be stuck there forever, since no
			-- QueueStatusChanged/PreRaceCountdown/state change was ever coming.
			if member ~= player then
				queueRejectedRemote:FireClient(player, member.Name)
			end
			return
		end
	end

	local queueTarget = target or QueueModes.AnySize
	local targetQueue = getQueue(queueTarget)
	for _, member in partyMembers do
		local userId = member.UserId
		playerBusy[userId] = true
		table.insert(targetQueue, member)
		queuedTarget[userId] = queueTarget

		TelemetryService.BeginMatchAttempt(member)
		TelemetryService.MatchStep(member, "Queued", QueueModes.LabelForTarget(queueTarget))
		TelemetryService.Onboarding(member, "FirstQueue")
	end

	-- Only meaningful for an actual party (a solo queuer's own partyMembers
	-- list is just {player} -- see PartyService.GetPartyMembers -- so this is
	-- a no-op on the common solo-queue path).
	ReferralService.TagPartyReferral(partyMembers)

	tryStartCountdown()

	-- The PLAY queue always has a departure time -- the wave clock runs whether
	-- or not anyone is in it -- so a joiner is always caught up to the current
	-- wave rather than being told to wait for a countdown that has to be
	-- triggered. The wave still only LEAVES with MinPlayers aboard.
	if queueTarget == QueueModes.AnySize then
		for _, member in partyMembers do
			queueStatusRemote:FireClient(member, waveSecondsRemaining())
			mapSelectedRemote:FireClient(member, waveStageId)
		end
		return
	end

	-- Looked up by THIS queue: several countdowns can be running at once, and
	-- sending another station's timer and map to someone in this queue would
	-- show them a race they aren't in -- counting down to a teleport that never
	-- comes for them.
	local ourPending = pending[queueTarget]
	if ourPending then
		-- Only when the countdown was ALREADY running before this call: these
		-- members joined mid-window, so tryStartCountdown's own whole-queue
		-- broadcast (which fires once, at the moment a countdown starts) never
		-- reached them, and they need the current partially-elapsed value. If
		-- THIS call is what started it, everyone in the queue was already told.
		if countdownWasRunning then
			for _, member in partyMembers do
				queueStatusRemote:FireClient(member, math.max(0, ourPending.endTime - os.clock()))
				mapSelectedRemote:FireClient(member, ourPending.stageId)
			end
		end
	else
		-- Either this queue isn't full yet, or a countdown is running for a
		-- different station and this queue's turn hasn't come. `true` (not a
		-- number) tells QueueStatusController to show its waiting state with
		-- the elapsed clock instead of a ticking countdown.
		for _, member in partyMembers do
			queueStatusRemote:FireClient(member, true)
		end
	end
end

-- Whether this player is sitting in ANY queue right now. Read by
-- QueueStationService before it acts on someone leaving a room: a race
-- starting teleports its participants out of the room they were standing in,
-- which looks identical to walking out, and treating that as "they left the
-- queue" would quit them from the very race they just filled.
function MatchService.IsQueued(player: Player): boolean
	return queuedTarget[player.UserId] ~= nil
end

-- How many players are waiting in a given size's queue. Read by
-- QueueStationService to paint each lobby room's live count.
function MatchService.GetQueueCount(target: number): number
	local waiting = queues[target]
	return if waiting then #waiting else 0
end

-- Solo mode: no matchmaking wait needed (nothing to match with), but keeps
-- the same map-reveal + pre-race-countdown pacing as a real match so the
-- client-side UI (MapRevealController, QueueStatusController) works
-- completely unmodified. Doesn't touch `queue`/`sessions` at all.
function MatchService.StartBotMatch(player: Player)
	local userId = player.UserId
	if playerBusy[userId] then
		return
	end
	playerBusy[userId] = true

	local stageId = Stages[math.random(1, #Stages)].Id
	playerRaceStage[userId] = stageId

	queueStatusRemote:FireClient(player, Constants.Match.SoloRevealSeconds)
	mapSelectedRemote:FireClient(player, stageId)

	task.delay(Constants.Match.SoloRevealSeconds + Constants.Match.MapRevealSeconds, function()
		if not player.Parent or playerRaceStage[userId] ~= stageId then
			return -- quit or disconnected during the reveal
		end

		local spawnCFrame = getStageSpawnCFrame(stageId)
		if spawnCFrame then
			teleportToStageSpawn(player, spawnCFrame)
			lastCheckpoint[userId] = spawnCFrame
		end
		queueStatusRemote:FireClient(player, nil)
		preRaceCountdownRemote:FireClient(player, Constants.Match.CountdownSeconds)
		setFrozen(player, true)

		task.delay(Constants.Match.CountdownSeconds, function()
			if not player.Parent or playerRaceStage[userId] ~= stageId then
				-- Quit mid-countdown already unfroze via QuitMatch, but this is
				-- cheap and covers any other path that could reach here.
				setFrozen(player, false)
				return
			end

			-- Same anti-headstart snap-back as a real race (see beginRace).
			if spawnCFrame then
				teleportToStageSpawn(player, spawnCFrame)
				lastCheckpoint[userId] = spawnCFrame
			end
			setFrozen(player, false)
			LobbyService.SetPlayerState(player, "Racing")
			AbilityService.ResetCooldown(player)
			MovementService.ClearSpeedOverride(player)
			racePositionRemote:FireClient(player, 1, 2)

			local bot = BotService.SpawnBot(stageId)
			if not bot then
				-- Stage geometry missing its waypoints; bail out cleanly rather
				-- than strand the player mid-race with no opponent.
				playerRaceStage[userId] = nil
				playerBusy[userId] = nil
				lastCheckpoint[userId] = nil
				LobbyService.SetPlayerState(player, "Lobby")
				return
			end
			botMatches[userId] = { stageId = stageId, bot = bot }

			BotService.RunBot(bot, stageId, function()
				-- Bot reached the finish first. If this fires after the player
				-- already finished/quit, botMatches[userId] won't match this
				-- bot anymore (DespawnBot already ran), so it's a no-op.
				local match = botMatches[userId]
				if not match or match.bot ~= bot then
					return
				end
				botMatches[userId] = nil
				playerRaceStage[userId] = nil
				playerBusy[userId] = nil
				lastCheckpoint[userId] = nil
				LobbyService.SetPlayerState(player, "Lobby")
				BotService.DespawnBot(bot)
				raceOutcomeRemote:FireClient(player, { Won = false, Placement = 2, Total = 2 })
			end)

			task.delay(Constants.Match.MaxDurationSeconds, function()
				local match = botMatches[userId]
				if not match or match.bot ~= bot then
					return
				end
				botMatches[userId] = nil
				playerRaceStage[userId] = nil
				playerBusy[userId] = nil
				lastCheckpoint[userId] = nil
				LobbyService.SetPlayerState(player, "Lobby")
				BotService.DespawnBot(bot)
			end)
		end)
	end)
end

-- Solo, no opponent at all -- shares the exact map-reveal/countdown pacing
-- with the other two modes (same reasoning as StartBotMatch: the client-side
-- UI needs no mode-specific handling), but where StartBotMatch hands off to
-- a bot, this just starts the clock and lets the player race it alone. See
-- finishPracticeMatch for what happens at the finish line, and
-- GhostService/GhostController for the recorded-run playback this unlocks.
function MatchService.StartPracticeMatch(player: Player)
	local userId = player.UserId
	if playerBusy[userId] then
		return
	end
	playerBusy[userId] = true

	local stageId = Stages[math.random(1, #Stages)].Id
	playerRaceStage[userId] = stageId

	queueStatusRemote:FireClient(player, Constants.Match.SoloRevealSeconds)
	mapSelectedRemote:FireClient(player, stageId)

	task.delay(Constants.Match.SoloRevealSeconds + Constants.Match.MapRevealSeconds, function()
		if not player.Parent or playerRaceStage[userId] ~= stageId then
			return
		end

		local spawnCFrame = getStageSpawnCFrame(stageId)
		if spawnCFrame then
			teleportToStageSpawn(player, spawnCFrame)
			lastCheckpoint[userId] = spawnCFrame
		end
		queueStatusRemote:FireClient(player, nil)
		preRaceCountdownRemote:FireClient(player, Constants.Match.CountdownSeconds)
		setFrozen(player, true)

		task.delay(Constants.Match.CountdownSeconds, function()
			if not player.Parent or playerRaceStage[userId] ~= stageId then
				setFrozen(player, false)
				return
			end

			if spawnCFrame then
				teleportToStageSpawn(player, spawnCFrame)
				lastCheckpoint[userId] = spawnCFrame
			end
			setFrozen(player, false)
			LobbyService.SetPlayerState(player, "Racing")
			AbilityService.ResetCooldown(player)
			MovementService.ClearSpeedOverride(player)
			racePositionRemote:FireClient(player, 1, 1)

			practiceMatches[userId] = { stageId = stageId, startTime = os.clock() }

			task.delay(Constants.Match.MaxDurationSeconds, function()
				local match = practiceMatches[userId]
				if not match or match.stageId ~= stageId then
					return
				end
				practiceMatches[userId] = nil
				playerRaceStage[userId] = nil
				playerBusy[userId] = nil
				lastCheckpoint[userId] = nil
				LobbyService.SetPlayerState(player, "Lobby")
			end)
		end)
	end)
end

function MatchService.PlayerReachedCheckpoint(player: Player, stageId: string, checkpointCFrame: CFrame)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end
	lastCheckpoint[userId] = checkpointCFrame
end

-- Stages are elevated well above the ground now (see Stages.luau difficulty
-- tiers), so a miss is only a fair "hard but fun" penalty if there's a fast
-- way back up: teleport back to the last checkpoint touched (or the stage
-- spawn if none yet) instead of leaving the player to walk all the way back.
function MatchService.PlayerFellOff(player: Player, stageId: string)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end

	local recoverTo = lastCheckpoint[userId] or getStageSpawnCFrame(stageId)
	if not recoverTo then
		return
	end

	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			-- Order matters: kill the constraints BEFORE zeroing velocity, or
			-- a surviving one re-applies its launch on the next physics frame
			-- and the zeroing is wasted.
			clearLaunchers(root)
			root.CFrame = recoverTo + Vector3.new(0, 2, 0)
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end)
	-- This teleport itself must never be mistaken for movement on the next
	-- speed check.
	lastCheckedPosition[userId] = nil
	-- A fall is a teleport, not a respawn, so nothing else resets WalkSpeed
	-- here -- without this a Stage4 speed strip's boost survives the recovery
	-- and immediately launches you off the same ledge again.
	MovementService.ClearSpeedOverride(player)

	playerFellRemote:FireClient(player)
end

-- Every stage has a VoidZone slab under its course that recovers anyone who
-- misses a jump (see StageService) -- but a slab only covers the footprint it
-- was drawn over, and each one stops just short of the course's own extents
-- (Stage4's platforms run to X=72, its VoidZone only to X=87). Overshoot past
-- the finish -- easy on Stage4, where a speed strip can fire you well past it
-- -- and you sail over the edge of the trigger entirely, land on the terrain
-- below, and simply stay there: no recovery, no respawn, nothing until the
-- match watchdog eventually times the whole race out. That's the "I fell to
-- the ground and had to wait seconds" bug.
--
-- This generalises the slab to infinite horizontal extent -- applied by
-- altitude instead of by touch, so where you fall stops mattering. The
-- threshold it compares against is the thing that has to be right: see
-- getFallFloorY for why reading it off the VoidZone left this bug half-fixed
-- (you still had to walk under the stage), and what replaced it.
local FALL_CHECK_INTERVAL = 0.15
-- How far below the stage's lowest standable surface counts as "fallen".
-- Small on purpose, and the reason it can't just be "under the VoidZone" --
-- see getFallFloorY.
local FALL_FLOOR_MARGIN = 1

local fallFloorY: { [string]: number } = {}

-- Below this altitude you are, by construction, no longer on the course.
--
-- Measured from the stage's own lowest standable platform, NOT from the
-- VoidZone slab -- which is what it used to do, and is why sailing past the
-- finish line still stranded you. Every VoidZone is authored down at ground
-- level (top surface Y = 2.5), but a player standing on the ground has their
-- HumanoidRootPart at roughly Y = 3: hip height plus half the root part. So
-- landing on the grass left you sitting about half a stud ABOVE the
-- threshold, and nothing fired. Walking into the slab's actual footprint
-- under the stage was the only way to trigger recovery, exactly as reported.
--
-- The lowest platform is a far better reference: it's tens of studs up on
-- every stage (Stage1's is the closest at ~5.9, the rest are 13-35), so a
-- grounded player is unambiguously below it, while someone legitimately
-- standing on that very platform is still ~3 studs of hip height above it and
-- can never trip this. The VoidZone keeps working as an instant trigger via
-- its own Touched handler in StageService -- this is the altitude backstop for
-- everywhere the slab doesn't physically reach.
local function getFallFloorY(stageId: string): number?
	local cached = fallFloorY[stageId]
	if cached then
		return cached
	end

	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	if not stageFolder then
		return nil
	end

	local lowest = math.huge
	for _, part in stageFolder:GetDescendants() do
		-- CanCollide filters out the triggers and decoration you can't
		-- actually stand on; the VoidZone is skipped explicitly because it's
		-- the ground-level slab whose height caused the bug above.
		if part:IsA("BasePart") and part.CanCollide and not CollectionService:HasTag(part, "VoidZone") then
			lowest = math.min(lowest, part.Position.Y - part.Size.Y / 2)
		end
	end
	if lowest == math.huge then
		return nil
	end

	fallFloorY[stageId] = lowest - FALL_FLOOR_MARGIN
	return fallFloorY[stageId]
end

local function startFallWatchdog()
	task.spawn(function()
		while true do
			task.wait(FALL_CHECK_INTERVAL)
			for userId, stageId in playerRaceStage do
				local player = Players:GetPlayerByUserId(userId)
				local character = player and player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				local floorY = root and getFallFloorY(stageId)
				if root and floorY and root.Position.Y < floorY then
					MatchService.PlayerFellOff(player :: Player, stageId)
				end
			end
		end
	end)
end

-- How often every racer's "how far along the course are you" fraction is
-- pushed to every client showing the progress bar. 0.2s is slow enough to be
-- cheap (one small array per racer, five times a second) and fast enough that
-- the bar reads as live -- the client tweens between updates anyway, so the
-- gaps aren't visible (see RaceProgressController).
local PROGRESS_BROADCAST_INTERVAL = 0.2

-- Stage geometry the progress fraction is measured against: the FinishLine
-- part (same tag + StageId attribute convention StageService binds its touch
-- handlers to) and the stage spawn, cached because neither ever moves.
local finishPosition: { [string]: Vector3 } = {}

local function getFinishPosition(stageId: string): Vector3?
	local cached = finishPosition[stageId]
	if cached then
		return cached
	end
	for _, part in CollectionService:GetTagged("FinishLine") do
		if part:IsA("BasePart") and part:GetAttribute("StageId") == stageId then
			finishPosition[stageId] = part.Position
			return part.Position
		end
	end

	-- Fallback for a stage whose finish part was built but never tagged (or
	-- tagged without the StageId attribute): the same
	-- Workspace.Stages.<StageId> folder convention getStageSpawnCFrame uses.
	-- Only the progress bar depends on this -- actual win detection still
	-- requires the tag, since that's what StageService binds Touched to.
	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	local finishPart = stageFolder and stageFolder:FindFirstChild("FinishLine", true)
	if finishPart and finishPart:IsA("BasePart") then
		finishPosition[stageId] = finishPart.Position
		return finishPart.Position
	end

	return nil
end

-- 0 at the spawn, 1 at the finish line. Measured as "distance still to go,
-- as a fraction of the whole course" on the XZ plane rather than by summing
-- checkpoints: stages are built in Studio with no fixed checkpoint count (see
-- getStageSpawnCFrame's note on levels living outside src/), so anything
-- keyed off checkpoint indices would silently break on the next stage edit.
-- Height is deliberately ignored -- falling into the void shouldn't read as
-- progress in either direction, the fall watchdog handles that.
local function computeProgress(stageId: string, position: Vector3): number?
	local finish = getFinishPosition(stageId)
	local spawnCFrame = getStageSpawnCFrame(stageId)
	if not finish or not spawnCFrame then
		return nil
	end

	local start = spawnCFrame.Position
	local total = (Vector3.new(finish.X, 0, finish.Z) - Vector3.new(start.X, 0, start.Z)).Magnitude
	if total < 1 then
		return nil
	end

	local remaining = (Vector3.new(finish.X, 0, finish.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
	return math.clamp(1 - remaining / total, 0, 1)
end

export type ProgressEntry = { UserId: number, Name: string, Progress: number }

local function progressEntry(stageId: string, userId: number, name: string, root: BasePart?): ProgressEntry?
	if not root then
		return nil
	end
	local progress = computeProgress(stageId, root.Position)
	if not progress then
		return nil
	end
	return { UserId = userId, Name = name, Progress = progress }
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Pushes the whole field's progress to everyone who has a stake in that
-- particular race. Deliberately covers all three race shapes that have an
-- opponent worth watching -- the shared session (plus its spectators, who
-- care most of all), duels, and bot matches -- but not practice runs, where
-- the bar would only ever show one lonely marker.
-- Pushes each player's weather from playerRaceStage, which is the single
-- authoritative answer to "which stage is this player standing on" -- set the
-- moment they're teleported in and cleared the moment they're sent back,
-- across every mode (queued, bot, practice, duel).
--
-- Reconciled on a timer rather than pushed from each assignment: that field is
-- written in roughly twenty-five places, several inside loops that only have a
-- userId to hand, and a weather push bolted onto each one would be a
-- transition waiting to be missed the next time somebody adds a mode. Diffing
-- one field cannot miss a transition by construction. WeatherService.SetForPlayer
-- already suppresses no-op repeats, so this only touches the wire on a real
-- change, and a quarter-second of latency is invisible against a 3-second
-- weather tween.
local WEATHER_RECONCILE_INTERVAL = 0.25

-- Players who have been told "you are no longer in a race", so the clear is
-- sent once on leaving rather than every tick.
local rosterCleared: { [number]: boolean } = {}

local function startWeatherReconciler()
	task.spawn(function()
		while true do
			task.wait(WEATHER_RECONCILE_INTERVAL)
			for _, player in Players:GetPlayers() do
				local userId = player.UserId
				WeatherService.SetForPlayer(player, playerRaceStage[userId])

				-- Roster CONTENT is pushed immediately by broadcastRoster; only
				-- the "you're out" edge is reconciled here, because it happens
				-- on half a dozen paths (finish, quit, walkover, disconnect,
				-- stop-spectating, session timeout) and missing one would leave
				-- a player back in the lobby with half the lobby invisible.
				local inRace = playerSession[userId] ~= nil or sessionSpectatedBy(userId) ~= nil
				if inRace then
					rosterCleared[userId] = nil
				elseif not rosterCleared[userId] then
					rosterCleared[userId] = true
					raceRosterRemote:FireClient(player, nil)
				end
			end
		end
	end)
end

local function startProgressBroadcast()
	task.spawn(function()
		while true do
			task.wait(PROGRESS_BROADCAST_INTERVAL)

			-- Every live race gets its own progress list, and each list only
			-- goes to that race's own players -- a racer on Stage 1 must never
			-- be sent the positions of a concurrent race on Stage 3.
			for _, session in sessions do
				local entries = {}
				for userId, racer in session.participants do
					local entry = progressEntry(session.stageId, userId, racer.DisplayName, getRoot(racer))
					if entry then
						table.insert(entries, entry)
					end
				end
				if #entries > 0 then
					for _, racer in session.participants do
						raceProgressRemote:FireClient(racer, entries)
					end
					for _, spectator in session.spectators do
						raceProgressRemote:FireClient(spectator, entries)
					end
				end
			end

			for userId, duel in duelMatches do
				-- Both sides key into the same DuelMatch table, so iterating
				-- the map visits each duel twice -- build the entry list from
				-- the duel's own `players` and just send it to this one side.
				local player = Players:GetPlayerByUserId(userId)
				if player then
					local entries = {}
					for opponentUserId, duellist in duel.players do
						local entry =
							progressEntry(duel.stageId, opponentUserId, duellist.DisplayName, getRoot(duellist))
						if entry then
							table.insert(entries, entry)
						end
					end
					if #entries > 0 then
						raceProgressRemote:FireClient(player, entries)
					end
				end
			end

			for userId, botMatch in botMatches do
				local player = Players:GetPlayerByUserId(userId)
				if player then
					local entries = {}
					local playerEntry = progressEntry(botMatch.stageId, userId, player.DisplayName, getRoot(player))
					if playerEntry then
						table.insert(entries, playerEntry)
					end
					-- Bots have no UserId of their own; 0 never collides with
					-- a real one, and the client only uses it to spot "me".
					local botEntry = progressEntry(botMatch.stageId, 0, "Bot", botMatch.bot.root)
					if botEntry then
						table.insert(entries, botEntry)
					end
					if #entries > 0 then
						raceProgressRemote:FireClient(player, entries)
					end
				end
			end
		end
	end)
end

-- No Elo/streak/leaderboard here on purpose: "playing with bots won't give
-- them elo, just points" -- and letting an easy-by-design bot time count on
-- the competitive top-100 leaderboard would make that list meaningless.
local function finishBotMatch(player: Player, botMatch: { stageId: string, bot: BotService.BotHandle })
	local userId = player.UserId
	botMatches[userId] = nil
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	LobbyService.SetPlayerState(player, "Lobby")
	BotService.DespawnBot(botMatch.bot)

	local pointsAwarded = 0
	local profile = PlayerDataService.GetProfile(player)
	if profile then
		local multiplier = if MonetizationService.HasVIP(player) then MonetizationService.PointsMultiplier else 1
		pointsAwarded = Constants.Match.PointsPerWin * multiplier
		profile.Points += pointsAwarded
	end

	raceOutcomeRemote:FireClient(player, { Won = true, Placement = 1, Total = 2, Points = pointsAwarded })
end

-- No points, no Elo (see the comment on practiceMatches for why) -- just the
-- real finish time submitted to the real leaderboard, and a completion
-- signal so the client can offer to save this run as its new ghost.
local function finishPracticeMatch(player: Player, match: { stageId: string, startTime: number })
	local userId = player.UserId
	practiceMatches[userId] = nil
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	LobbyService.SetPlayerState(player, "Lobby")

	local elapsed = os.clock() - match.startTime
	LeaderboardService.SubmitTime(player, match.stageId, elapsed)
	-- Practice is zero-stakes for Elo and points, but the TIME is real (it
	-- goes to the same leaderboard as any other run), so a practice lap that
	-- genuinely beats the server's best is a genuine record.
	HypeFeedService.CheckStageRecord(player, match.stageId, elapsed)

	practiceCompleteRemote:FireClient(player, elapsed)
end

-- Elo/points/streak/badge bookkeeping for whoever just won a heat, against
-- every opponent still racing at that instant. Shared by the real
-- ranked-queue path (one winner, N still-racing opponents) and duels (see
-- finishDuelMatch -- one winner, exactly one opponent) so this can't drift
-- into two different scoring rules for what's supposed to be the same Elo
-- ladder. Returns (winnerEloDelta, winStreak, streakBonus, pointsAwarded) for
-- the caller's own RaceOutcome payload to the winner -- pointsAwarded being
-- the final figure AFTER the streak bonus and any VIP multiplier, so the
-- number the player is shown is exactly the number that hit their balance.
-- Rematch decay: beating the SAME opponent over and over is worth less each
-- time, recovering once you stop.
--
-- Elo itself is already largely self-defending against alt-farming -- the loser
-- is floored at 0, so a drained alt has nothing left to donate and a main
-- feeding off one stalls at about 720 rating no matter how many wins it racks
-- up (measured against EloCalculator directly). What is NOT self-limiting is
-- everything else a win pays: win streak is unbounded and now broadcasts to the
-- whole server, and Wins is a public profile stat. Two accounts trading
-- deliberate losses could park a 50-win streak in everybody's feed.
--
-- Smooth rather than a hard cut-off after N, because on a quiet server racing
-- the same person five times in a row is completely normal and shouldn't be
-- punished like cheating. The curve only bites where the pattern is sustained.
local REMATCH_WINDOW_SECONDS = 1800
-- 1st win 100%, 2nd 87.5%, 3rd 75%, ... 8th 12.5%, 9th and beyond nothing.
--
-- Eight rather than four because four bites too early on legitimate play: with
-- waves every 60 seconds, two friends on a quiet server can genuinely race each
-- other five times inside ten minutes and would have been earning nothing by
-- then. Eight still shuts a farm down well inside the 30-minute window, just
-- without taxing the normal case to do it.
local REMATCH_DECAY_STEPS = 8

type RematchRecord = {
	count: number,
	lastAt: number,
}
local rematchHistory: { [number]: { [number]: RematchRecord } } = {}

-- How much this win over this opponent is worth, and record that it happened.
-- Directional on purpose: A beating B repeatedly damps A's gains, but it says
-- nothing about what B earns if B ever wins one back.
local function consumeRematchWeight(winnerUserId: number, loserUserId: number): number
	local byOpponent = rematchHistory[winnerUserId]
	if not byOpponent then
		byOpponent = {}
		rematchHistory[winnerUserId] = byOpponent
	end

	local now = os.clock()
	local record = byOpponent[loserUserId]
	-- A gap longer than the window wipes the slate rather than merely pausing
	-- it, so someone who plays a friend a lot on Monday isn't still damped on
	-- Tuesday.
	if not record or now - record.lastAt > REMATCH_WINDOW_SECONDS then
		record = { count = 0, lastAt = now }
		byOpponent[loserUserId] = record
	end

	record.lastAt = now
	local weight = math.max(0, 1 - record.count / REMATCH_DECAY_STEPS)
	record.count += 1
	return weight
end

-- How much a result against THIS player is worth to their opponent, based on
-- how old their Roblox account is.
--
-- This is the only defence that actually reaches alt mills. The rematch decay
-- above is keyed per-pair, so rotating a fresh alt in for every race sidesteps
-- it entirely -- every new account is a new pairing at full value. Account age
-- can't be rotated: Player.AccountAge is reported by Roblox, is server-side,
-- and can't be faked by the client. Farming past this means creating hundreds
-- of accounts and then waiting a week before using any of them.
--
-- Researched alternatives were weaker. Glicko's g(RD) and TrueSkill's
-- normaliser both damp wins over uncertain opponents, but only by roughly a
-- third -- they reduce the yield of farming, they don't stop it, because no
-- rating algorithm has access to identity. Worse, both are floorless, so
-- adopting one would have removed the 0-floor that currently caps a farm at
-- ~720 rating.
--
-- Applied ASYMMETRICALLY (see EloService): it damps what the OPPONENT earns
-- from the new account, never what the new account earns itself. A real new
-- player still gains and loses rating at full speed and calibrates normally --
-- they're just not a worthwhile thing to farm.
local ACCOUNT_AGE_FULL_VALUE_DAYS = 7

local function accountAgeWeight(player: Player): number
	-- Studio's simulated test clients ALWAYS report AccountAge 0, so without
	-- this every rating change in a local multi-client test settles to exactly
	-- zero -- the ramp working correctly on what look like four brand-new
	-- accounts, but indistinguishable from Elo being broken. Treating them as
	-- established is what makes the system testable at all.
	--
	-- Studio-only by construction: RunService:IsStudio() is false on every live
	-- server, so this can never weaken the real anti-farm protection.
	if RunService:IsStudio() then
		return 1
	end

	-- Ramped rather than a hard cut-off, so a 6-day-old account and an 8-day-old
	-- one aren't arbitrarily different. Day 0 accounts are worth nothing at all,
	-- which is the case that matters: a mill spins up accounts and uses them
	-- immediately.
	return math.clamp(player.AccountAge / ACCOUNT_AGE_FULL_VALUE_DAYS, 0, 1)
end

local function forgetRematchHistory(userId: number)
	rematchHistory[userId] = nil
	for _, byOpponent in rematchHistory do
		byOpponent[userId] = nil
	end
end

-- Settles rating for ONE finisher against everyone still out on the course.
--
-- Called every time anybody crosses the line, not just the winner, which is
-- what finally makes placement matter. A race of N is treated as the N(N-1)/2
-- pairwise results it actually contains: when you finish, you have beaten
-- exactly the people still racing, and you were already beaten by everyone who
-- crossed before you (settled when THEY finished). Every pair is settled once,
-- in order, with no need to wait for the race to end.
--
-- Before this, rating was only ever computed for the winner, so 2nd place out
-- of 8 and last place out of 8 lost exactly the same amount -- the finishing
-- order, the whole result of a race, was thrown away.
--
-- K is divided by (N-1) so a big race isn't worth more total rating than a
-- small one: the winner of an 8-player race settles 7 pairs, and without this
-- their swing would be seven times a duel's.
-- Returns the rating gained, and the best per-opponent weight seen. The weight
-- is handed back rather than recomputed by the caller because consuming it
-- ADVANCES the rematch counter -- asking twice for the same pair would count
-- one race as two and damp the next result too hard.
local function settleFinisherElo(
	finisher: Player,
	stillRacing: { Player },
	totalParticipants: number,
	tally: { [number]: number }?
): (number, number)
	local gained = 0
	local bestWeight = 0
	local pairShare = 1 / math.max(1, totalParticipants - 1)

	for _, behind in stillRacing do
		-- Both damping factors multiply: a repeat opponent AND a fresh account
		-- is worth less than either alone.
		local resultWeight = consumeRematchWeight(finisher.UserId, behind.UserId) * accountAgeWeight(behind)
		bestWeight = math.max(bestWeight, resultWeight)
		local winnerWeight = resultWeight * pairShare
		-- The loser's side is damped only by how established the WINNER is --
		-- never by the rematch count, which is the winner's own history and
		-- says nothing about how much rating the loser should shed.
		local loserWeight = accountAgeWeight(finisher) * pairShare

		local delta, behindDelta = EloService.ReportMatchResult(finisher, behind, winnerWeight, loserWeight)
		gained += delta

		local behindProfile = PlayerDataService.GetProfile(behind)
		if behindProfile then
			LeaderstatsService.Refresh(behind)
			LeaderboardService.SubmitElo(behind, behindProfile.Elo)
		end
		if tally then
			tally[behind.UserId] = (tally[behind.UserId] or 0) + behindDelta
		end
	end

	if tally then
		tally[finisher.UserId] = (tally[finisher.UserId] or 0) + gained
	end

	return gained, bestWeight
end

-- The win-only half: streak, points, badges, announcements. Rating is settled
-- separately by settleFinisherElo, for EVERY finisher rather than just this one.
--
-- `raceWeight` is the best per-opponent weight from that settlement, and decides
-- what the race is worth for points and progression: beating one familiar rival
-- alongside three fresh opponents is a real win and shouldn't be dragged down by
-- the rival.
local function settleWin(
	winner: Player,
	opponents: { Player },
	winnerDelta: number,
	raceWeight: number
): (number, number, number, number)
	local pointsAwarded = 0
	for _, opponent in opponents do
		local opponentProfile = PlayerDataService.GetProfile(opponent)
		if opponentProfile then
			opponentProfile.WinStreak = 0
			opponentProfile.Losses += 1
			ReferralService.HandleFirstRealRace(opponent, opponentProfile)
		end
	end

	-- Points are awarded once per race won, not once per opponent beaten.
	local winnerProfile = PlayerDataService.GetProfile(winner)
	local winStreak, streakBonus = 0, 0
	if winnerProfile then
		ReferralService.HandleFirstRealRace(winner, winnerProfile)

		-- A fully damped win (the 5th+ over the same person inside the window)
		-- pays nothing and counts for nothing -- no Wins, no streak. Anything
		-- above zero still counts as a win for progression; only the points
		-- scale. Otherwise the streak, which is the loudest farmable thing in
		-- the game now that it broadcasts, would keep climbing on wins the
		-- system has already decided are worthless.
		if raceWeight > 0 then
			winnerProfile.Wins += 1
			winnerProfile.WinStreak += 1
			winnerProfile.BestWinStreak = math.max(winnerProfile.BestWinStreak, winnerProfile.WinStreak)
		end
		winStreak = winnerProfile.WinStreak
		streakBonus = streakBonusPoints(winStreak)
		local multiplier = if MonetizationService.HasVIP(winner) then MonetizationService.PointsMultiplier else 1
		pointsAwarded = math.floor((Constants.Match.PointsPerWin + streakBonus) * multiplier * raceWeight)
		winnerProfile.Points += pointsAwarded
		TelemetryService.Economy(
			winner,
			true,
			"Points",
			pointsAwarded,
			winnerProfile.Points,
			Enum.AnalyticsEconomyTransactionType.Gameplay,
			"RaceWin"
		)

		BadgeMilestoneService.CheckWinMilestones(winner, winnerProfile)

		-- Whole-server announcements for what this win just created. Both read
		-- the profile AFTER the Elo/streak writes above have landed, so a
		-- broadcast can never describe a state that didn't actually happen.
		-- EloService has already applied winnerDelta, so subtracting it back
		-- off is what the rank was a moment ago.
		local oldRank = RankTiers.GetRankForElo(winnerProfile.Elo - winnerDelta)
		local newRank = RankTiers.GetRankForElo(winnerProfile.Elo)
		if newRank ~= oldRank then
			HypeFeedService.AnnounceRankUp(winner, newRank)
		end
		HypeFeedService.AnnounceWinStreak(winner, winStreak)

		LeaderstatsService.Refresh(winner) -- Elo (via EloService above), Wins, and Rank are all final now
		LeaderboardService.SubmitElo(winner, winnerProfile.Elo) -- keeps the physical board's global ranking current
	end

	return winnerDelta, winStreak, streakBonus, pointsAwarded
end

-- Everyone else left (quit or disconnected) and exactly one racer is still out
-- there with no winner decided yet. Before this, that player was simply left
-- alone on the course, still obliged to run the whole thing to a finish line
-- nobody was contesting -- most visible in the 2-player case the shared queue
-- is usually running, where one person leaving stranded the other. They win on
-- the spot instead.
--
-- Deliberately settled as settleWin(winner, {}) -- an empty opponent list --
-- so it's a real win (Wins, points, streak, badges, leaderboard) but moves
-- ZERO Elo. Elo is a transfer: it needs someone who actually lost, and this
-- module's existing rule, applied at every other quit/disconnect path, is that
-- leaving costs you nothing. Paying the survivor Elo for it would both break
-- that rule and hand two alt accounts a trivial ladder-boosting loop -- queue
-- as a pair, one quits, repeat.
function awardWalkover(session: Session): boolean
	if session.winner then
		return false
	end

	local remaining: Player? = nil
	local count = 0
	for _, participant in session.participants do
		remaining = participant
		count += 1
	end
	if count ~= 1 or not remaining then
		return false
	end

	local winner = remaining :: Player
	local userId = winner.UserId
	session.winner = winner
	session.participants[userId] = nil
	playerSession[userId] = nil
	session.finishedCount += 1

	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil

	-- They may still be mid-pre-race-countdown when the last opponent bails.
	setFrozen(winner, false)
	MovementService.ClearSpeedOverride(winner)
	LobbyService.SetPlayerState(winner, "Lobby")
	local lobbyCFrame = getLobbySpawnCFrame()
	if lobbyCFrame then
		teleportToStageSpawn(winner, lobbyCFrame)
	end

	local _, winStreak, streakBonus, points = settleWin(winner, {}, 0, 1)
	raceOutcomeRemote:FireClient(winner, {
		Won = true,
		Placement = 1,
		Total = session.totalParticipants,
		EloDelta = 0,
		WinStreak = winStreak,
		StreakBonus = streakBonus,
		Points = points,
		Walkover = true,
	})

	endSession(session)
	return true
end

-- Pays the finish reward and reports it. Applied to EVERY player who crosses
-- the line, including the winner (who gets it on top of their win points), so
-- there is no completed race that pays nothing. Returns the amount so the
-- caller can put it in that player's RaceOutcome payload -- a reward the
-- player is never shown may as well not exist.
local function awardFinishPoints(player: Player): number
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return 0
	end
	local multiplier = if MonetizationService.HasVIP(player) then MonetizationService.PointsMultiplier else 1
	local amount = Constants.Match.PointsPerFinish * multiplier
	profile.Points += amount
	TelemetryService.Economy(
		player,
		true,
		"Points",
		amount,
		profile.Points,
		Enum.AnalyticsEconomyTransactionType.Gameplay,
		"RaceFinish"
	)
	return amount
end

-- No Elo/streak/leaderboard-skew here (see finishBotMatch's comment above for
-- why bot/practice stay zero-stakes) -- a duel carries the exact same stakes
-- as a real ranked race, just against one specific opponent picked via the
-- profile card instead of whoever else was in the shared queue. Weather is
-- deliberately left alone (see MatchService.StartDuelMatch), matching how
-- bot/practice matches already avoid touching the one global Lighting
-- singleton while a real race might be using it for something else.
local function finishDuelMatch(player: Player, match: DuelMatch)
	local userId = player.UserId
	match.players[userId] = nil
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	duelMatches[userId] = nil
	LobbyService.SetPlayerState(player, "Lobby")

	local elapsed = os.clock() - match.startTime
	LeaderboardService.SubmitTime(player, match.stageId, elapsed)
	HypeFeedService.CheckStageRecord(player, match.stageId, elapsed)

	-- Same rule as a queued race: crossing the line always pays.
	local finishPoints = awardFinishPoints(player)

	local isWinner = not match.winner
	if isWinner then
		match.winner = player

		local opponent: Player? = nil
		for _, p in match.players do
			opponent = p
		end

		if opponent then
			local winnerDelta, raceWeight = settleFinisherElo(player, { opponent }, 2)
			local _, winStreak, streakBonus, points = settleWin(player, { opponent }, winnerDelta, raceWeight)
			raceOutcomeRemote:FireClient(player, {
				Won = true,
				Points = points + finishPoints,
				Placement = 1,
				EloDelta = winnerDelta,
				WinStreak = winStreak,
				StreakBonus = streakBonus,
			})
		end
	else
		-- Elo for this player was already settled when the opponent (the real
		-- winner) finished first -- this is just their personal placement,
		-- plus the finish reward for having actually completed the course.
		raceOutcomeRemote:FireClient(player, { Won = false, Placement = 2, Total = 2, Points = finishPoints })
	end
end

function MatchService.PlayerReachedFinish(player: Player, stageId: string)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end

	-- Before any of the mode-specific paths below, since every one of them
	-- ends with the player back in the lobby -- crossing the line mid-boost
	-- shouldn't leave them sprinting around the lobby at 42 afterwards.
	MovementService.ClearSpeedOverride(player)

	local botMatch = botMatches[userId]
	if botMatch and botMatch.stageId == stageId then
		finishBotMatch(player, botMatch)
		return
	end

	local practiceMatch = practiceMatches[userId]
	if practiceMatch and practiceMatch.stageId == stageId then
		finishPracticeMatch(player, practiceMatch)
		return
	end

	local duelMatch = duelMatches[userId]
	if duelMatch and duelMatch.stageId == stageId then
		finishDuelMatch(player, duelMatch)
		return
	end

	-- Resolved through the player, not the stage: a stage can be carrying
	-- several races at once, so crossing Stage 3's finish line only counts for
	-- whichever race on Stage 3 this player is actually in.
	local session = sessionFor(userId)
	if not session or session.stageId ~= stageId or not session.participants[userId] then
		return
	end

	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	session.participants[userId] = nil
	playerSession[userId] = nil

	-- Others are still out there racing -- offer to stick around and watch
	-- instead of yanking this player straight back to the lobby the instant
	-- they cross the line. See MatchService.LeaveSpectate for bailing out
	-- early, and endSession for the "round everyone up" once it's really over.
	if next(session.participants) ~= nil then
		session.spectators[userId] = player
		LobbyService.SetPlayerState(player, "Spectating")
		parkSpectator(player)
		broadcastSpectatorRacers(session)
		broadcastRoster(session)
	else
		LobbyService.SetPlayerState(player, "Lobby")
	end

	local elapsed = os.clock() - session.startTime
	LeaderboardService.SubmitTime(player, stageId, elapsed)
	HypeFeedService.CheckStageRecord(player, stageId, elapsed)

	session.finishedCount += 1
	local placement = session.finishedCount

	TelemetryService.MatchStep(player, "Finished")
	TelemetryService.Onboarding(player, "FirstFinish")
	-- Value is the finish time in whole seconds, so the dashboard can chart how
	-- long a race actually takes per stage -- the number that decides whether a
	-- session fits into the few minutes a new player gives you.
	TelemetryService.Custom(player, "RaceFinished", math.floor(elapsed), {
		stageId,
		tostring(placement),
		tostring(session.totalParticipants),
	})
	TelemetryService.EndMatchAttempt(player)

	local finishPoints = awardFinishPoints(player)
	racePositionRemote:FireClient(player, placement, session.totalParticipants)
	for _, opponent in session.participants do
		racePositionRemote:FireClient(opponent, placement + 1, session.totalParticipants)
	end

	-- Everyone still on the course finished behind this player, so this is the
	-- moment those pairs are decided -- for the winner and for every placement
	-- after them. Settling here, per finisher, is what makes 2nd out of 8 worth
	-- more than 8th out of 8.
	local behind = {}
	for _, opponent in session.participants do
		table.insert(behind, opponent)
	end
	local _, raceWeight = settleFinisherElo(player, behind, session.totalParticipants, session.eloDelta)
	-- Their NET change across the whole race: what they just gained from the
	-- field behind them, minus everything they already shed to whoever beat
	-- them home earlier.
	local eloDelta = math.round(session.eloDelta[userId] or 0)

	local isWinner = not session.winner
	if isWinner then
		session.winner = player

		local winnerDelta, winStreak, streakBonus, points = settleWin(player, behind, eloDelta, raceWeight)

		raceOutcomeRemote:FireClient(player, {
			Won = true,
			Placement = placement,
			EloDelta = winnerDelta,
			WinStreak = winStreak,
			StreakBonus = streakBonus,
			Points = points + finishPoints,
		})
	else
		-- Not a win, but no longer a flat loss either: this player still gained
		-- rating from everyone they beat home, so their own delta is reported
		-- rather than the winner's.
		raceOutcomeRemote:FireClient(player, {
			Won = false,
			Placement = placement,
			Total = session.totalParticipants,
			EloDelta = eloDelta,
			Points = finishPoints,
		})
	end

	if next(session.participants) == nil then
		endSession(session)
	end
end

-- A duel only ever has these two participants -- unlike a real race, there's
-- no "still racing" third party to keep the match alive for, so if either
-- side leaves while both are still actively racing, the whole duel is
-- cancelled with no result for either (same "quitting costs no Elo" rule as
-- a real race, just applied to both sides at once since there's no one left
-- to legitimately win against). A no-op if the match was already decided
-- (the caller already finished, or already quit) -- see the call sites.
local function abandonDuel(player: Player)
	local userId = player.UserId
	local match = duelMatches[userId]
	if not match then
		return
	end
	duelMatches[userId] = nil

	local opponent: Player? = nil
	for otherId, p in match.players do
		if otherId ~= userId then
			opponent = p
		end
	end
	if not opponent then
		return
	end

	duelMatches[opponent.UserId] = nil
	playerRaceStage[opponent.UserId] = nil
	playerBusy[opponent.UserId] = nil
	lastCheckpoint[opponent.UserId] = nil
	if opponent.Parent then
		LobbyService.SetPlayerState(opponent, "Lobby")
		local lobbyCFrame = getLobbySpawnCFrame()
		if lobbyCFrame then
			teleportToStageSpawn(opponent, lobbyCFrame)
		end
		duelCancelledRemote:FireClient(opponent, player.Name)
	end
end

-- Voluntary "Leave Match" -- no Elo/streak penalty (they didn't lose to
-- anyone, they just left), just cleans them out of the queue/session exactly
-- like a disconnect would (see removePlayer) and, since they're staying
-- connected, flips their camera back to third-person. Only teleports them
-- back to the lobby spawn if they'd actually left it -- see wasOnStage below.
function MatchService.QuitMatch(player: Player)
	local userId = player.UserId
	if not playerBusy[userId] then
		return
	end

	local queuedIn = queuedTarget[userId]
	if queuedIn then
		local waiting = getQueue(queuedIn)
		local index = table.find(waiting, player)
		if index then
			table.remove(waiting, index)
		end
		queuedTarget[userId] = nil
	end

	-- Unconditionally, NOT just for someone still sitting in `queue` (which is
	-- where this used to live): QueueStatusController's countdown is a local
	-- timer that only ever stops on a nil here. By the pre-race countdown the
	-- player is long out of `queue`, so quitting during it sent nothing and
	-- left "RACE STARTING IN" ticking all the way down to zero on the screen of
	-- someone who had already left. Harmless no-op when nothing is showing.
	queueStatusRemote:FireClient(player, nil)

	TelemetryService.Custom(player, "MatchAbandoned")
	TelemetryService.EndMatchAttempt(player)

	local botMatch = botMatches[userId]
	if botMatch then
		botMatches[userId] = nil
		BotService.DespawnBot(botMatch.bot)
	end
	practiceMatches[userId] = nil
	abandonDuel(player)

	local raceSession = sessionFor(userId)
	if raceSession then
		raceSession.participants[userId] = nil
		playerSession[userId] = nil
		if next(raceSession.participants) == nil then
			endSession(raceSession)
		elseif not awardWalkover(raceSession) then
			-- Anyone spectating this player specifically needs to know they're
			-- gone (a quit is just as much "no longer racing" as a finish).
			broadcastSpectatorRacers(raceSession)
			broadcastRoster(raceSession)
		end
	end

	-- lastCheckpoint only ever gets set at the exact moment a participant is
	-- actually teleported onto a stage (every "enter stage" call site sets
	-- it right alongside teleportToStageSpawn -- see startSession/
	-- StartBotMatch/StartPracticeMatch/RequestDuel), so it's still nil here
	-- if they cancelled during the brief "matching"/map-reveal window before
	-- that teleport ever fires, or while just sitting in the shared queue.
	-- Read it BEFORE clearing it just below.
	local wasOnStage = lastCheckpoint[userId] ~= nil

	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil

	-- Harmless no-op if they weren't mid-countdown (already unfrozen or
	-- never frozen) -- but if they were, leaving this out would strand them
	-- anchored in the lobby with no way to move.
	setFrozen(player, false)
	MovementService.ClearSpeedOverride(player)
	LobbyService.SetPlayerState(player, "Lobby")

	-- Snapping to the lobby spawn only makes sense if they'd actually been
	-- moved off of it -- otherwise (still queued, or cancelling during the
	-- pre-teleport countdown) they never left wherever they clicked Play
	-- from, and yanking them to the lobby spawn anyway was the bug: hitting
	-- Cancel with no match found used to relocate you for no reason.
	if wasOnStage then
		local lobbyCFrame = getLobbySpawnCFrame()
		if lobbyCFrame then
			teleportToStageSpawn(player, lobbyCFrame)
		end
	end
end

-- Voluntary "stop spectating" -- a spectator isn't racing (playerBusy/
-- playerRaceStage are already clear by the time someone's in this state, see
-- PlayerReachedFinish), so this is a separate path from QuitMatch rather
-- than folded into it. Wired to the same QuitMatch remote/Backspace key
-- client-side though: whichever of the two actually applies to this player
-- fires, the other is a no-op.
function MatchService.LeaveSpectate(player: Player)
	local userId = player.UserId
	local session = sessionSpectatedBy(userId)
	if not session then
		return
	end
	session.spectators[userId] = nil
	returnSpectatorToLobby(player)
end

local function removePlayer(player: Player)
	local userId = player.UserId

	-- Drop their cached weather value too, or a rejoining player reusing this
	-- UserId would be told "no change" and left on the previous session's sky.
	WeatherService.Forget(player)
	forgetRematchHistory(userId)
	rosterCleared[userId] = nil
	playerSession[userId] = nil

	local queuedIn = queuedTarget[userId]
	if queuedIn then
		local waiting = getQueue(queuedIn)
		local index = table.find(waiting, player)
		if index then
			table.remove(waiting, index)
		end
		queuedTarget[userId] = nil
	end

	TelemetryService.Custom(player, "MatchAbandoned")
	TelemetryService.EndMatchAttempt(player)

	local botMatch = botMatches[userId]
	if botMatch then
		botMatches[userId] = nil
		BotService.DespawnBot(botMatch.bot)
	end
	practiceMatches[userId] = nil
	abandonDuel(player)
	pendingDuelRequests[userId] = nil

	local raceSession = sessionFor(userId)
	if raceSession then
		raceSession.participants[userId] = nil
		playerSession[userId] = nil
		if next(raceSession.participants) == nil then
			endSession(raceSession)
		elseif not awardWalkover(raceSession) then
			broadcastSpectatorRacers(raceSession)
			broadcastRoster(raceSession)
		end
	end
	local spectated = sessionSpectatedBy(userId)
	if spectated then
		spectated.spectators[userId] = nil
	end
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	lastCheckedPosition[userId] = nil
end

-- Private 1v1: same map-reveal/countdown pacing as every other mode (see
-- StartBotMatch), but never touches `queue`/`sessions` (see the module
-- comment on `duelMatches`). Weather now applies here like anywhere else: it
-- became per-player when it moved to the client (see WeatherService), so a
-- duel can have its stage's sky without fighting a concurrent real race over
-- the one global Lighting -- which is exactly why duels used to skip it.
function MatchService.StartDuelMatch(playerA: Player, playerB: Player)
	local stageId = Stages[math.random(1, #Stages)].Id
	local userIdA, userIdB = playerA.UserId, playerB.UserId

	playerBusy[userIdA] = true
	playerBusy[userIdB] = true
	playerRaceStage[userIdA] = stageId
	playerRaceStage[userIdB] = stageId

	queueStatusRemote:FireClient(playerA, Constants.Match.SoloRevealSeconds)
	queueStatusRemote:FireClient(playerB, Constants.Match.SoloRevealSeconds)
	mapSelectedRemote:FireClient(playerA, stageId)
	mapSelectedRemote:FireClient(playerB, stageId)

	-- Shared by both the reveal-end and countdown-end checks below: either
	-- side quitting/disconnecting before the race actually starts cancels the
	-- whole duel (see abandonDuel for the same rule once racing has begun).
	local function releaseBoth()
		playerRaceStage[userIdA] = nil
		playerRaceStage[userIdB] = nil
		playerBusy[userIdA] = nil
		playerBusy[userIdB] = nil
		lastCheckpoint[userIdA] = nil
		lastCheckpoint[userIdB] = nil
		-- Harmless no-op if this fires before either side was ever frozen
		-- (the reveal-end check below can hit this same path).
		setFrozen(playerA, false)
		setFrozen(playerB, false)
		if playerA.Parent then
			LobbyService.SetPlayerState(playerA, "Lobby")
			queueStatusRemote:FireClient(playerA, nil)
		end
		if playerB.Parent then
			LobbyService.SetPlayerState(playerB, "Lobby")
			queueStatusRemote:FireClient(playerB, nil)
		end
	end

	task.delay(Constants.Match.SoloRevealSeconds + Constants.Match.MapRevealSeconds, function()
		if playerRaceStage[userIdA] ~= stageId or playerRaceStage[userIdB] ~= stageId then
			releaseBoth()
			return
		end

		local spawnCFrame = getStageSpawnCFrame(stageId)
		if spawnCFrame then
			teleportToStageSpawn(playerA, spawnCFrame)
			teleportToStageSpawn(playerB, spawnCFrame)
			lastCheckpoint[userIdA] = spawnCFrame
			lastCheckpoint[userIdB] = spawnCFrame
		end
		queueStatusRemote:FireClient(playerA, nil)
		queueStatusRemote:FireClient(playerB, nil)
		preRaceCountdownRemote:FireClient(playerA, Constants.Match.CountdownSeconds)
		preRaceCountdownRemote:FireClient(playerB, Constants.Match.CountdownSeconds)
		setFrozen(playerA, true)
		setFrozen(playerB, true)

		task.delay(Constants.Match.CountdownSeconds, function()
			if playerRaceStage[userIdA] ~= stageId or playerRaceStage[userIdB] ~= stageId then
				releaseBoth()
				return
			end

			-- Same anti-headstart snap-back as a real race (see beginRace).
			if spawnCFrame then
				teleportToStageSpawn(playerA, spawnCFrame)
				teleportToStageSpawn(playerB, spawnCFrame)
				lastCheckpoint[userIdA] = spawnCFrame
				lastCheckpoint[userIdB] = spawnCFrame
			end
			setFrozen(playerA, false)
			setFrozen(playerB, false)
			LobbyService.SetPlayerState(playerA, "Racing")
			LobbyService.SetPlayerState(playerB, "Racing")
			AbilityService.ResetCooldown(playerA)
			AbilityService.ResetCooldown(playerB)
			MovementService.ClearSpeedOverride(playerA)
			MovementService.ClearSpeedOverride(playerB)
			racePositionRemote:FireClient(playerA, 1, 2)
			racePositionRemote:FireClient(playerB, 1, 2)

			local match: DuelMatch = {
				stageId = stageId,
				players = { [userIdA] = playerA, [userIdB] = playerB },
				startTime = os.clock(),
				winner = nil,
			}
			duelMatches[userIdA] = match
			duelMatches[userIdB] = match

			task.delay(Constants.Match.MaxDurationSeconds, function()
				-- Watchdog: if neither side ever finishes (e.g. both AFK), don't
				-- leave the pair stuck racing forever.
				if duelMatches[userIdA] ~= match and duelMatches[userIdB] ~= match then
					return
				end
				duelMatches[userIdA] = nil
				duelMatches[userIdB] = nil
				playerRaceStage[userIdA] = nil
				playerRaceStage[userIdB] = nil
				playerBusy[userIdA] = nil
				playerBusy[userIdB] = nil
				lastCheckpoint[userIdA] = nil
				lastCheckpoint[userIdB] = nil
				if playerA.Parent then
					LobbyService.SetPlayerState(playerA, "Lobby")
				end
				if playerB.Parent then
					LobbyService.SetPlayerState(playerB, "Lobby")
				end
			end)
		end)
	end)
end

-- Fired from the profile card's "Request 1v1". Silently drops (same
-- philosophy as PartyService.createInvite) if either side is already mid-
-- match -- there's nothing sensible to interrupt them with.
function MatchService.RequestDuel(fromPlayer: Player, targetPlayer: Player)
	if fromPlayer.UserId == targetPlayer.UserId then
		return
	end
	if playerBusy[fromPlayer.UserId] or playerBusy[targetPlayer.UserId] then
		return
	end
	pendingDuelRequests[targetPlayer.UserId] = { fromUserId = fromPlayer.UserId, expiresAt = os.clock() + DUEL_REQUEST_TTL }
	duelRequestReceivedRemote:FireClient(targetPlayer, fromPlayer.Name)
end

function MatchService.RespondToDuel(respondingPlayer: Player, accepted: boolean)
	local request = pendingDuelRequests[respondingPlayer.UserId]
	pendingDuelRequests[respondingPlayer.UserId] = nil
	if not request or os.clock() > request.expiresAt then
		return
	end

	local challenger = Players:GetPlayerByUserId(request.fromUserId)
	if not challenger then
		return
	end

	if not accepted then
		duelCancelledRemote:FireClient(challenger, respondingPlayer.Name)
		return
	end

	-- Both sides may have gotten busy (queued, started another match) during
	-- the time the request sat pending -- re-check right before actually
	-- starting rather than trusting the snapshot from request time.
	if playerBusy[respondingPlayer.UserId] or playerBusy[challenger.UserId] then
		duelCancelledRemote:FireClient(challenger, respondingPlayer.Name)
		duelCancelledRemote:FireClient(respondingPlayer, challenger.Name)
		return
	end

	MatchService.StartDuelMatch(challenger, respondingPlayer)
end

function MatchService.Init()
	queueStatusRemote = Net.CreateRemoteEvent(RemoteNames.QueueStatusChanged)
	preRaceCountdownRemote = Net.CreateRemoteEvent(RemoteNames.PreRaceCountdown)
	racePositionRemote = Net.CreateRemoteEvent(RemoteNames.RacePositionChanged)
	raceProgressRemote = Net.CreateRemoteEvent(RemoteNames.RaceProgressChanged)
	raceOutcomeRemote = Net.CreateRemoteEvent(RemoteNames.RaceOutcome)
	mapSelectedRemote = Net.CreateRemoteEvent(RemoteNames.MapSelected)
	playerFellRemote = Net.CreateRemoteEvent(RemoteNames.PlayerFell)
	spectateStatusRemote = Net.CreateRemoteEvent(RemoteNames.SpectateStatus)
	raceRosterRemote = Net.CreateRemoteEvent(RemoteNames.RaceRosterChanged)
	waveClockRemote = Net.CreateRemoteEvent(RemoteNames.WaveClock)
	-- Someone joining mid-window needs the time LEFT, not a fresh 60 -- the
	-- wave clock runs on server start and never restarts for an individual.
	Players.PlayerAdded:Connect(function(player)
		waveClockRemote:FireClient(player, waveSecondsRemaining())
	end)
	practiceCompleteRemote = Net.CreateRemoteEvent(RemoteNames.PracticeComplete)
	queueRejectedRemote = Net.CreateRemoteEvent(RemoteNames.QueueRejected)
	duelRequestReceivedRemote = Net.CreateRemoteEvent(RemoteNames.DuelRequestReceived)
	duelCancelledRemote = Net.CreateRemoteEvent(RemoteNames.DuelCancelled)
	Players.PlayerRemoving:Connect(removePlayer)
	startSpeedWatchdog()
	startFallWatchdog()
	startProgressBroadcast()
	startWeatherReconciler()
	startWaveClock()

	-- mode: nil/"Real" -> shared queue, "Bots" -> solo vs. a bot, "Practice"
	-- -> solo, no opponent at all. (Was a plain vsBots boolean before
	-- Practice mode existed; a string reads better now that there are three.)
	local requestQueueRemote = Net.CreateRemoteEvent(RemoteNames.RequestQueue)
	requestQueueRemote.OnServerEvent:Connect(function(player: Player, mode: string?)
		if mode == "Bots" then
			MatchService.StartBotMatch(player)
		elseif mode == "Practice" then
			MatchService.StartPracticeMatch(player)
		else
			MatchService.Enqueue(player)
		end
	end)

	local quitMatchRemote = Net.CreateRemoteEvent(RemoteNames.QuitMatch)
	quitMatchRemote.OnServerEvent:Connect(function(player: Player)
		MatchService.QuitMatch(player)
		MatchService.LeaveSpectate(player)
	end)

	local requestDuelRemote = Net.CreateRemoteEvent(RemoteNames.RequestDuel)
	requestDuelRemote.OnServerEvent:Connect(function(player: Player, targetUserId: number)
		if typeof(targetUserId) ~= "number" then
			return
		end
		local target = Players:GetPlayerByUserId(targetUserId)
		if target then
			MatchService.RequestDuel(player, target)
		end
	end)

	local respondDuelRemote = Net.CreateRemoteEvent(RemoteNames.RespondToDuel)
	respondDuelRemote.OnServerEvent:Connect(function(player: Player, accepted: boolean)
		MatchService.RespondToDuel(player, accepted == true)
	end)
end

return MatchService
