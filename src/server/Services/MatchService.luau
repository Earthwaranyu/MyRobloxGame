local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local EloService = require(script.Parent.EloService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local LobbyService = require(script.Parent.LobbyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local WeatherService = require(script.Parent.WeatherService)

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
}

local queue: { Player } = {}
local queuedSet: { [number]: boolean } = {}
local pendingCountdown = false
local countdownEndTime: number? = nil
local pendingStageId: string? = nil
local activeSession: Session? = nil

local playerRaceStage: { [number]: string } = {}

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

local queueStatusRemote: RemoteEvent
local preRaceCountdownRemote: RemoteEvent
local racePositionRemote: RemoteEvent
local raceOutcomeRemote: RemoteEvent
local mapSelectedRemote: RemoteEvent

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

-- Warps a participant to the stage's spawn regardless of where they wandered
-- off to during the countdown, so everyone actually starts the race together.
-- pcall'd so one player's stale/missing character can't abort session start
-- for everyone else in the loop that calls this.
local function teleportToStageSpawn(player: Player, spawnCFrame: CFrame)
	pcall(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.CFrame = spawnCFrame
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		end
	end)
end

function tryStartCountdown()
	if pendingCountdown or activeSession then
		return
	end
	if #queue == 0 then
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
-- (third-person, no finish-line detection) for CountdownSeconds so everyone
-- gets a moment to see the map before the clock starts.
function startSession()
	local queued = queue
	queue = {}
	local stageId = pendingStageId
	pendingStageId = nil
	countdownEndTime = nil
	if #queued == 0 or not stageId then
		return
	end

	local spawnCFrame = getStageSpawnCFrame(stageId)

	local participants: { [number]: Player } = {}
	for _, player in queued do
		queuedSet[player.UserId] = nil
		if player.Parent then
			participants[player.UserId] = player
			if spawnCFrame then
				teleportToStageSpawn(player, spawnCFrame)
			end
			queueStatusRemote:FireClient(player, nil)
			preRaceCountdownRemote:FireClient(player, Constants.Match.CountdownSeconds)
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

	for userId, player in validParticipants do
		playerRaceStage[userId] = stageId
		LobbyService.SetPlayerState(player, "Racing")
	end
	WeatherService.ApplyStageWeather(stageId)

	local session: Session = {
		stageId = stageId,
		participants = validParticipants,
		totalParticipants = totalParticipants,
		finishedCount = 0,
		winner = nil,
		startTime = os.clock(),
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
			LobbyService.SetPlayerState(straggler, "Lobby")
		end

		endSession()
	end)
end

function endSession()
	activeSession = nil
	WeatherService.RevertToLobby()
	tryStartCountdown()
end

function MatchService.Enqueue(player: Player)
	local userId = player.UserId
	if playerBusy[userId] then
		return
	end

	playerBusy[userId] = true
	table.insert(queue, player)
	queuedSet[userId] = true

	tryStartCountdown()

	if countdownEndTime and pendingStageId then
		queueStatusRemote:FireClient(player, math.max(0, countdownEndTime - os.clock()))
		mapSelectedRemote:FireClient(player, pendingStageId)
	end
end

function MatchService.PlayerReachedFinish(player: Player, stageId: string)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end

	local session = activeSession
	if not session or session.stageId ~= stageId or not session.participants[userId] then
		return
	end

	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
	session.participants[userId] = nil
	LobbyService.SetPlayerState(player, "Lobby")

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
		local winnerDelta = 0
		for _, opponent in session.participants do
			local delta, opponentDelta = EloService.ReportMatchResult(player, opponent)
			winnerDelta += delta
			raceOutcomeRemote:FireClient(opponent, { Won = false, EloDelta = opponentDelta })
		end

		-- Points are awarded once per race won, not once per opponent beaten.
		local winnerProfile = PlayerDataService.GetProfile(player)
		if winnerProfile then
			winnerProfile.Points += Constants.Match.PointsPerWin
		end

		raceOutcomeRemote:FireClient(player, { Won = true, Placement = placement, EloDelta = winnerDelta })
	else
		-- Elo for this player was already settled when the winner finished;
		-- this is just their personal placement confirmation.
		raceOutcomeRemote:FireClient(player, { Won = false, Placement = placement, Total = session.totalParticipants })
	end

	if next(session.participants) == nil then
		endSession()
	end
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

	local raceStageId = playerRaceStage[userId]
	if raceStageId and activeSession and activeSession.stageId == raceStageId then
		activeSession.participants[userId] = nil
		if next(activeSession.participants) == nil then
			endSession()
		end
	end
	playerRaceStage[userId] = nil
	playerBusy[userId] = nil
end

function MatchService.Init()
	queueStatusRemote = Net.CreateRemoteEvent(RemoteNames.QueueStatusChanged)
	preRaceCountdownRemote = Net.CreateRemoteEvent(RemoteNames.PreRaceCountdown)
	racePositionRemote = Net.CreateRemoteEvent(RemoteNames.RacePositionChanged)
	raceOutcomeRemote = Net.CreateRemoteEvent(RemoteNames.RaceOutcome)
	mapSelectedRemote = Net.CreateRemoteEvent(RemoteNames.MapSelected)
	Players.PlayerRemoving:Connect(removePlayer)

	local requestQueueRemote = Net.CreateRemoteEvent(RemoteNames.RequestQueue)
	requestQueueRemote.OnServerEvent:Connect(function(player: Player)
		MatchService.Enqueue(player)
	end)
end

return MatchService
