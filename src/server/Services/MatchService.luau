local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)
local RankTiers = require(Shared.RankTiers)

local AbilityService = require(script.Parent.AbilityService)
local BadgeMilestoneService = require(script.Parent.BadgeMilestoneService)
local BotService = require(script.Parent.BotService)
local EloService = require(script.Parent.EloService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local LobbyService = require(script.Parent.LobbyService)
local MonetizationService = require(script.Parent.MonetizationService)
local MovementService = require(script.Parent.MovementService)
local PartyService = require(script.Parent.PartyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
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

local queue: { Player } = {}
local queuedSet: { [number]: boolean } = {}
local pendingCountdown = false
local countdownEndTime: number? = nil
local pendingStageId: string? = nil
local activeSession: Session? = nil

local playerRaceStage: { [number]: string } = {}
-- Most recent checkpoint each player has touched this stage visit, used to
-- recover them in place after a fall instead of sending them all the way
-- back to Platform_Start. Seeded with the stage spawn CFrame the moment
-- they're teleported in, so falling before touching any checkpoint still
-- recovers sensibly.
local lastCheckpoint: { [number]: CFrame } = {}

-- True from the moment a player is enqueued until they either finish their
-- race or get force-reset (watchdog/disconnect). Separate from queuedSet
-- (only true while literally sitting in `queue`) and playerRaceStage (only
-- true once the race has actually started): there's a real gap between
-- those two -- teleported to the stage, waiting out CountdownSeconds, but
-- not yet racing -- during which neither flag was set, so touching another
-- start line in that window would silently re-enqueue the player into a
-- second, overlapping race. playerBusy is the single guard covering the
-- whole span.
local playerBusy: { [number]: boolean } = {}

-- Solo vs-bot matches deliberately do NOT go through `activeSession`/the
-- shared queue above -- that's a single server-wide slot by design (see
-- WeatherService's comment on why), and a bot match blocking every other
-- player's real matchmaking for up to MaxDurationSeconds would be a real
-- regression. Each player can run their own bot match fully independently,
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
local racePositionRemote: RemoteEvent
local raceOutcomeRemote: RemoteEvent
local mapSelectedRemote: RemoteEvent
local playerFellRemote: RemoteEvent
local spectateStatusRemote: RemoteEvent
local practiceCompleteRemote: RemoteEvent
local queueRejectedRemote: RemoteEvent
local duelRequestReceivedRemote: RemoteEvent
local duelCancelledRemote: RemoteEvent

local tryStartCountdown: () -> ()
local startSession: () -> ()
local beginRace: (stageId: string, participants: { [number]: Player }) -> ()
local endSession: () -> ()

-- Levels are built directly in Studio (not synced from src/), following the
-- convention Workspace.Stages.<StageId>.<StageId>Spawn for each stage's spawn point.
local function getStageSpawnCFrame(stageId: string): CFrame?
	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	local spawnPart = stageFolder and stageFolder:FindFirstChild(stageId .. "Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame + Vector3.new(0, 3, 0)
	end
	return nil
end

local function getLobbySpawnCFrame(): CFrame?
	local spawnPart = Workspace:FindFirstChild("SpawnLocation")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame + Vector3.new(0, 3, 0)
	end
	return nil
end

-- Warps a participant to the stage's spawn regardless of where they wandered
-- off to during the countdown, so everyone actually starts the race together.
-- pcall'd so one player's stale/missing character can't abort session start
-- for everyone else in the loop that calls this. Every call site here is a
-- forced teleport (race entry, anti-headstart snap-back, or return to
-- lobby), so this is also the one place the speed-watchdog baseline gets
-- cleared -- none of these jumps should ever be mistaken for cheating.
local function teleportToStageSpawn(player: Player, spawnCFrame: CFrame)
	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.CFrame = spawnCFrame
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end)
	lastCheckedPosition[player.UserId] = nil
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
			root.Anchored = frozen
		end
	end)
end

function tryStartCountdown()
	if pendingCountdown or activeSession then
		return
	end
	-- Below this, stay in "waiting" -- no countdown, no map reveal, nothing
	-- teleported. This used to only check #queue == 0, which meant a single
	-- solo player queuing would still get matched into a "race" against
	-- nobody 3 seconds later: 0 Elo change (no real opponent to calculate
	-- against) but full points AND win-streak credit, same as a real win --
	-- a free, repeatable reward exploit, not just a UX gap.
	if #queue < Constants.Match.MinPlayers then
		return
	end

	pendingCountdown = true
	pendingStageId = Stages[math.random(1, #Stages)].Id
	countdownEndTime = os.clock() + Constants.Match.MatchingSeconds

	task.delay(Constants.Match.MatchingSeconds, function()
		pendingCountdown = false
		startSession()
	end)
end

-- Teleports the matched group to the chosen stage. They stay in "Lobby"
-- (first-person, but frozen in place -- see setFrozen) for CountdownSeconds
-- so everyone gets a moment to see the map before the clock starts.
function startSession()
	local queued = queue
	queue = {}
	local stageId = pendingStageId
	pendingStageId = nil
	countdownEndTime = nil

	if #queued < Constants.Match.MinPlayers or not stageId then
		-- Dropped below the minimum during the matching window (someone in
		-- queue quit) -- put whoever's left back in queue rather than
		-- starting an under-strength (or solo) race; tryStartCountdown picks
		-- it back up automatically on the next Enqueue.
		for _, player in queued do
			if player.Parent then
				table.insert(queue, player)
				queuedSet[player.UserId] = true
				queueStatusRemote:FireClient(player, true)
			end
		end
		return
	end

	local spawnCFrame = getStageSpawnCFrame(stageId)

	local participants: { [number]: Player } = {}
	for _, player in queued do
		queuedSet[player.UserId] = nil
		if player.Parent then
			participants[player.UserId] = player
			-- Set as soon as they're teleported (not just once the race timer
			-- starts) so fall-recovery already works during the pre-race
			-- countdown, not only once CountdownSeconds elapses.
			playerRaceStage[player.UserId] = stageId
			if spawnCFrame then
				teleportToStageSpawn(player, spawnCFrame)
				lastCheckpoint[player.UserId] = spawnCFrame
			end
			queueStatusRemote:FireClient(player, nil)
			preRaceCountdownRemote:FireClient(player, Constants.Match.CountdownSeconds)
			setFrozen(player, true)
		end
	end

	if next(participants) == nil then
		return
	end

	task.delay(Constants.Match.CountdownSeconds, function()
		beginRace(stageId, participants)
	end)
end

-- Actually starts the race: first-person camera (via the Racing state),
-- timer running, finish-line detection live.
function beginRace(stageId: string, participants: { [number]: Player })
	local validParticipants: { [number]: Player } = {}
	local totalParticipants = 0
	for userId, player in participants do
		if player.Parent then
			validParticipants[userId] = player
			totalParticipants += 1
		end
	end
	if totalParticipants == 0 then
		return
	end

	-- Players were frozen in place for CountdownSeconds (see setFrozen), not
	-- just left to wander -- but still snap everyone to the exact spawn CFrame
	-- here rather than trusting wherever they were frozen at, since e.g. a
	-- respawn mid-countdown would've left them unfrozen at whatever spot the
	-- default spawn put them.
	local spawnCFrame = getStageSpawnCFrame(stageId)
	for userId, player in validParticipants do
		if spawnCFrame then
			teleportToStageSpawn(player, spawnCFrame)
			lastCheckpoint[userId] = spawnCFrame
		end
		setFrozen(player, false)
		LobbyService.SetPlayerState(player, "Racing")
		AbilityService.ResetCooldown(player)
	end
	WeatherService.ApplyStageWeather(stageId)

	local session: Session = {
		stageId = stageId,
		participants = validParticipants,
		totalParticipants = totalParticipants,
		finishedCount = 0,
		winner = nil,
		startTime = os.clock(),
		spectators = {},
	}
	activeSession = session

	-- Nobody has finished yet, so everyone starts tied for 1st.
	for _, racer in validParticipants do
		racePositionRemote:FireClient(racer, 1, totalParticipants)
	end

	-- Watchdog: if the race never finishes (e.g. everyone AFKs), reset the
	-- stage rather than leaving it permanently stuck.
	task.delay(Constants.Match.MaxDurationSeconds, function()
		if activeSession ~= session then
			return
		end

		for _, straggler in session.participants do
			playerRaceStage[straggler.UserId] = nil
			playerBusy[straggler.UserId] = nil
			lastCheckpoint[straggler.UserId] = nil
			LobbyService.SetPlayerState(straggler, "Lobby")
		end

		endSession()
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

function endSession()
	if activeSession then
		for _, spectator in activeSession.spectators do
			returnSpectatorToLobby(spectator)
		end
	end
	activeSession = nil
	WeatherService.RevertToLobby()
	tryStartCountdown()
end

-- Partied players (see PartyService) are enqueued together in one atomic
-- pass -- every member gets added to the shared `queue` before this function
-- returns, so whichever `startSession` call grabs the queue next is
-- guaranteed to grab all of them together, regardless of exactly when each
-- member's own PLAY click happened. If any party member is already busy,
-- nobody is enqueued: a partial-party queue would just separate them anyway.
function MatchService.Enqueue(player: Player)
	local partyMembers = PartyService.GetPartyMembers(player)

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

	for _, member in partyMembers do
		local userId = member.UserId
		playerBusy[userId] = true
		table.insert(queue, member)
		queuedSet[userId] = true
	end

	tryStartCountdown()

	if countdownEndTime and pendingStageId then
		-- Either this call just started the countdown, or one was already
		-- running when this party joined -- either way, this party specifically
		-- needs the current countdown value (a `true` for "waiting" sent on
		-- an earlier Enqueue call wouldn't have updated once someone else's
		-- join pushed the queue over MinPlayers).
		for _, member in partyMembers do
			queueStatusRemote:FireClient(member, math.max(0, countdownEndTime - os.clock()))
			mapSelectedRemote:FireClient(member, pendingStageId)
		end
	else
		-- Below Constants.Match.MinPlayers -- queued, but no real countdown
		-- yet. `true` (not a number) tells QueueStatusController to show a
		-- static "waiting for players" state instead of a ticking countdown.
		for _, member in partyMembers do
			queueStatusRemote:FireClient(member, true)
		end
	end
end

-- Solo mode: no matchmaking wait needed (nothing to match with), but keeps
-- the same map-reveal + pre-race-countdown pacing as a real match so the
-- client-side UI (MapRevealController, QueueStatusController) works
-- completely unmodified. Doesn't touch `queue`/`activeSession` at all.
function MatchService.StartBotMatch(player: Player)
	local userId = player.UserId
	if playerBusy[userId] then
		return
	end
	playerBusy[userId] = true

	local stageId = Stages[math.random(1, #Stages)].Id
	playerRaceStage[userId] = stageId

	queueStatusRemote:FireClient(player, Constants.Match.MatchingSeconds)
	mapSelectedRemote:FireClient(player, stageId)

	task.delay(Constants.Match.MatchingSeconds, function()
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

	queueStatusRemote:FireClient(player, Constants.Match.MatchingSeconds)
	mapSelectedRemote:FireClient(player, stageId)

	task.delay(Constants.Match.MatchingSeconds, function()
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
			root.CFrame = recoverTo + Vector3.new(0, 2, 0)
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end)
	-- This teleport itself must never be mistaken for movement on the next
	-- speed check.
	lastCheckedPosition[userId] = nil

	playerFellRemote:FireClient(player)
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

	local profile = PlayerDataService.GetProfile(player)
	if profile then
		local multiplier = if MonetizationService.HasVIP(player) then MonetizationService.PointsMultiplier else 1
		profile.Points += Constants.Match.PointsPerWin * multiplier
	end

	raceOutcomeRemote:FireClient(player, { Won = true, Placement = 1, Total = 2 })
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

	practiceCompleteRemote:FireClient(player, elapsed)
end

-- Elo/points/streak/badge bookkeeping for whoever just won a heat, against
-- every opponent still racing at that instant. Shared by the real
-- ranked-queue path (one winner, N still-racing opponents) and duels (see
-- finishDuelMatch -- one winner, exactly one opponent) so this can't drift
-- into two different scoring rules for what's supposed to be the same Elo
-- ladder. Returns (winnerEloDelta, winStreak, streakBonus) for the caller's
-- own RaceOutcome payload to the winner.
local function settleWin(winner: Player, opponents: { Player }): (number, number, number)
	local winnerDelta = 0
	for _, opponent in opponents do
		local delta, opponentDelta = EloService.ReportMatchResult(winner, opponent)
		winnerDelta += delta
		local opponentProfile = PlayerDataService.GetProfile(opponent)
		if opponentProfile then
			opponentProfile.WinStreak = 0
			opponentProfile.Losses += 1
		end
		raceOutcomeRemote:FireClient(opponent, { Won = false, EloDelta = opponentDelta })
	end

	-- Points are awarded once per race won, not once per opponent beaten.
	local winnerProfile = PlayerDataService.GetProfile(winner)
	local winStreak, streakBonus = 0, 0
	if winnerProfile then
		local oldElo = winnerProfile.Elo - winnerDelta

		winnerProfile.Wins += 1
		winnerProfile.WinStreak += 1
		winnerProfile.BestWinStreak = math.max(winnerProfile.BestWinStreak, winnerProfile.WinStreak)
		winStreak = winnerProfile.WinStreak
		streakBonus = streakBonusPoints(winStreak)
		local multiplier = if MonetizationService.HasVIP(winner) then MonetizationService.PointsMultiplier else 1
		winnerProfile.Points += (Constants.Match.PointsPerWin + streakBonus) * multiplier

		BadgeMilestoneService.CheckWinMilestones(winner, winnerProfile)
		local oldRank = RankTiers.GetRankForElo(oldElo)
		local newRank = RankTiers.GetRankForElo(winnerProfile.Elo)
		if newRank ~= oldRank then
			BadgeMilestoneService.CheckRankMilestone(winner, winnerProfile, newRank)
		end
	end

	return winnerDelta, winStreak, streakBonus
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

	local isWinner = not match.winner
	if isWinner then
		match.winner = player

		local opponent: Player? = nil
		for _, p in match.players do
			opponent = p
		end

		if opponent then
			local winnerDelta, winStreak, streakBonus = settleWin(player, { opponent })
			raceOutcomeRemote:FireClient(player, {
				Won = true,
				Placement = 1,
				EloDelta = winnerDelta,
				WinStreak = winStreak,
				StreakBonus = streakBonus,
			})
		end
	else
		-- Elo for this player was already settled when the opponent (the real
		-- winner) finished first -- this is just their personal placement.
		raceOutcomeRemote:FireClient(player, { Won = false, Placement = 2, Total = 2 })
	end
end

function MatchService.PlayerReachedFinish(player: Player, stageId: string)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end

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

	local session = activeSession
	if not session or session.stageId ~= stageId or not session.participants[userId] then
		return
	end

	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	session.participants[userId] = nil

	-- Others are still out there racing -- offer to stick around and watch
	-- instead of yanking this player straight back to the lobby the instant
	-- they cross the line. See MatchService.LeaveSpectate for bailing out
	-- early, and endSession for the "round everyone up" once it's really over.
	if next(session.participants) ~= nil then
		session.spectators[userId] = player
		LobbyService.SetPlayerState(player, "Spectating")
		broadcastSpectatorRacers(session)
	else
		LobbyService.SetPlayerState(player, "Lobby")
	end

	local elapsed = os.clock() - session.startTime
	LeaderboardService.SubmitTime(player, stageId, elapsed)

	session.finishedCount += 1
	local placement = session.finishedCount
	racePositionRemote:FireClient(player, placement, session.totalParticipants)
	for _, opponent in session.participants do
		racePositionRemote:FireClient(opponent, placement + 1, session.totalParticipants)
	end

	local isWinner = not session.winner
	if isWinner then
		session.winner = player

		-- Elo is settled once, at the moment the winner crosses the line, against
		-- every opponent still racing at that instant (see the module comment).
		local opponents = {}
		for _, opponent in session.participants do
			table.insert(opponents, opponent)
		end
		local winnerDelta, winStreak, streakBonus = settleWin(player, opponents)

		raceOutcomeRemote:FireClient(player, {
			Won = true,
			Placement = placement,
			EloDelta = winnerDelta,
			WinStreak = winStreak,
			StreakBonus = streakBonus,
		})
	else
		-- Elo for this player was already settled when the winner finished;
		-- this is just their personal placement confirmation.
		raceOutcomeRemote:FireClient(player, { Won = false, Placement = placement, Total = session.totalParticipants })
	end

	if next(session.participants) == nil then
		endSession()
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

	if queuedSet[userId] then
		local index = table.find(queue, player)
		if index then
			table.remove(queue, index)
		end
		queuedSet[userId] = nil
		queueStatusRemote:FireClient(player, nil)
	end

	local botMatch = botMatches[userId]
	if botMatch then
		botMatches[userId] = nil
		BotService.DespawnBot(botMatch.bot)
	end
	practiceMatches[userId] = nil
	abandonDuel(player)

	local raceStageId = playerRaceStage[userId]
	if raceStageId and activeSession and activeSession.stageId == raceStageId then
		activeSession.participants[userId] = nil
		if next(activeSession.participants) == nil then
			endSession()
		else
			-- Anyone spectating this player specifically needs to know they're
			-- gone (a quit is just as much "no longer racing" as a finish).
			broadcastSpectatorRacers(activeSession)
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
	local session = activeSession
	if not session or not session.spectators[userId] then
		return
	end
	session.spectators[userId] = nil
	returnSpectatorToLobby(player)
end

local function removePlayer(player: Player)
	local userId = player.UserId

	if queuedSet[userId] then
		local index = table.find(queue, player)
		if index then
			table.remove(queue, index)
		end
		queuedSet[userId] = nil
	end

	local botMatch = botMatches[userId]
	if botMatch then
		botMatches[userId] = nil
		BotService.DespawnBot(botMatch.bot)
	end
	practiceMatches[userId] = nil
	abandonDuel(player)
	pendingDuelRequests[userId] = nil

	local raceStageId = playerRaceStage[userId]
	if raceStageId and activeSession and activeSession.stageId == raceStageId then
		activeSession.participants[userId] = nil
		if next(activeSession.participants) == nil then
			endSession()
		else
			broadcastSpectatorRacers(activeSession)
		end
	end
	if activeSession then
		activeSession.spectators[userId] = nil
	end
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	lastCheckpoint[userId] = nil
	lastCheckedPosition[userId] = nil
end

-- Private 1v1: same map-reveal/countdown pacing as every other mode (see
-- StartBotMatch), but never touches `queue`/`activeSession` (see the module
-- comment on `duelMatches`) and deliberately skips WeatherService.
-- ApplyStageWeather -- exactly like bot/practice matches already do -- since
-- Lighting is one global singleton shared by the whole server, and a duel
-- fighting a concurrent real race over it would be a visible regression for
-- whichever one loses that race.
function MatchService.StartDuelMatch(playerA: Player, playerB: Player)
	local stageId = Stages[math.random(1, #Stages)].Id
	local userIdA, userIdB = playerA.UserId, playerB.UserId

	playerBusy[userIdA] = true
	playerBusy[userIdB] = true
	playerRaceStage[userIdA] = stageId
	playerRaceStage[userIdB] = stageId

	queueStatusRemote:FireClient(playerA, Constants.Match.MatchingSeconds)
	queueStatusRemote:FireClient(playerB, Constants.Match.MatchingSeconds)
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

	task.delay(Constants.Match.MatchingSeconds, function()
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
	raceOutcomeRemote = Net.CreateRemoteEvent(RemoteNames.RaceOutcome)
	mapSelectedRemote = Net.CreateRemoteEvent(RemoteNames.MapSelected)
	playerFellRemote = Net.CreateRemoteEvent(RemoteNames.PlayerFell)
	spectateStatusRemote = Net.CreateRemoteEvent(RemoteNames.SpectateStatus)
	practiceCompleteRemote = Net.CreateRemoteEvent(RemoteNames.PracticeComplete)
	queueRejectedRemote = Net.CreateRemoteEvent(RemoteNames.QueueRejected)
	duelRequestReceivedRemote = Net.CreateRemoteEvent(RemoteNames.DuelRequestReceived)
	duelCancelledRemote = Net.CreateRemoteEvent(RemoteNames.DuelCancelled)
	Players.PlayerRemoving:Connect(removePlayer)
	startSpeedWatchdog()

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
