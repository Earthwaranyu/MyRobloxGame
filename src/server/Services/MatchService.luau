local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local EloService = require(script.Parent.EloService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local LobbyService = require(script.Parent.LobbyService)

-- Groups players who queue for the same stage into a single race: everyone who
-- queues within the countdown window starts together, and whoever crosses the
-- finish line first is the winner against every other participant still racing
-- at that moment (2nd/3rd place etc. still "lost" the heat, matching the
-- "find the winner who pass the finish line first" design in the game docs).
local MatchService = {}

type Session = {
	participants: { [number]: Player },
	totalParticipants: number,
	finishedCount: number,
	winner: Player?,
	startTime: number,
}

local queues: { [string]: { Player } } = {}
local pendingCountdown: { [string]: boolean } = {}
local countdownEndTime: { [string]: number } = {}
local activeSessions: { [string]: Session } = {}

local playerQueueStage: { [number]: string } = {}
local playerRaceStage: { [number]: string } = {}

local queueStatusRemote: RemoteEvent
local racePositionRemote: RemoteEvent

local tryStartCountdown: (stageId: string) -> ()
local startSession: (stageId: string) -> ()
local endSession: (stageId: string) -> ()

function tryStartCountdown(stageId: string)
	if pendingCountdown[stageId] or activeSessions[stageId] then
		return
	end
	if not queues[stageId] or #queues[stageId] == 0 then
		return
	end

	pendingCountdown[stageId] = true
	countdownEndTime[stageId] = os.clock() + Constants.Match.CountdownSeconds

	task.delay(Constants.Match.CountdownSeconds, function()
		pendingCountdown[stageId] = false
		startSession(stageId)
	end)
end

function startSession(stageId: string)
	local queued = queues[stageId]
	queues[stageId] = nil
	if not queued or #queued == 0 then
		return
	end

	local participants: { [number]: Player } = {}
	for _, player in queued do
		playerQueueStage[player.UserId] = nil
		if player.Parent then
			participants[player.UserId] = player
			playerRaceStage[player.UserId] = stageId
			LobbyService.SetPlayerState(player, "Racing")
			queueStatusRemote:FireClient(player, nil)
		end
	end

	if next(participants) == nil then
		return
	end

	local totalParticipants = 0
	for _ in participants do
		totalParticipants += 1
	end

	local session: Session = {
		participants = participants,
		totalParticipants = totalParticipants,
		finishedCount = 0,
		winner = nil,
		startTime = os.clock(),
	}
	activeSessions[stageId] = session

	-- Nobody has finished yet, so everyone starts tied for 1st.
	for _, racer in participants do
		racePositionRemote:FireClient(racer, 1, totalParticipants)
	end

	-- Watchdog: if the race never finishes (e.g. everyone AFKs), reset the
	-- stage rather than leaving it permanently stuck.
	task.delay(Constants.Match.MaxDurationSeconds, function()
		if activeSessions[stageId] ~= session then
			return
		end

		for _, straggler in session.participants do
			playerRaceStage[straggler.UserId] = nil
			LobbyService.SetPlayerState(straggler, "Lobby")
		end

		endSession(stageId)
	end)
end

function endSession(stageId: string)
	activeSessions[stageId] = nil
	tryStartCountdown(stageId)
end

function MatchService.Enqueue(player: Player, stageId: string)
	local userId = player.UserId
	if playerQueueStage[userId] or playerRaceStage[userId] then
		return
	end

	queues[stageId] = queues[stageId] or {}
	table.insert(queues[stageId], player)
	playerQueueStage[userId] = stageId

	tryStartCountdown(stageId)

	local endTime = countdownEndTime[stageId]
	if endTime then
		queueStatusRemote:FireClient(player, math.max(0, endTime - os.clock()))
	end
end

function MatchService.PlayerReachedFinish(player: Player, stageId: string)
	local userId = player.UserId
	if playerRaceStage[userId] ~= stageId then
		return
	end

	local session = activeSessions[stageId]
	if not session or not session.participants[userId] then
		return
	end

	playerRaceStage[userId] = nil
	session.participants[userId] = nil
	LobbyService.SetPlayerState(player, "Lobby")

	local elapsed = os.clock() - session.startTime
	LeaderboardService.SubmitTime(player, stageId, elapsed)

	session.finishedCount += 1
	racePositionRemote:FireClient(player, session.finishedCount, session.totalParticipants)
	for _, opponent in session.participants do
		racePositionRemote:FireClient(opponent, session.finishedCount + 1, session.totalParticipants)
	end

	if not session.winner then
		session.winner = player
		for _, opponent in session.participants do
			EloService.ReportMatchResult(player, opponent)
		end
	end

	if next(session.participants) == nil then
		endSession(stageId)
	end
end

local function removePlayer(player: Player)
	local userId = player.UserId

	local queueStageId = playerQueueStage[userId]
	if queueStageId and queues[queueStageId] then
		local index = table.find(queues[queueStageId], player)
		if index then
			table.remove(queues[queueStageId], index)
		end
	end
	playerQueueStage[userId] = nil

	local raceStageId = playerRaceStage[userId]
	if raceStageId then
		local session = activeSessions[raceStageId]
		if session then
			session.participants[userId] = nil
			if next(session.participants) == nil then
				endSession(raceStageId)
			end
		end
	end
	playerRaceStage[userId] = nil
end

function MatchService.Init()
	queueStatusRemote = Net.CreateRemoteEvent(RemoteNames.QueueStatusChanged)
	racePositionRemote = Net.CreateRemoteEvent(RemoteNames.RacePositionChanged)
	Players.PlayerRemoving:Connect(removePlayer)
end

return MatchService
