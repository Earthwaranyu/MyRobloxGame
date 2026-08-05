local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local PrivateServer = require(Shared.PrivateServer)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)
local Weather = require(Shared.Weather)

local MatchService = require(script.Parent.MatchService)
local WeatherService = require(script.Parent.WeatherService)

-- The private server's host panel: what the owner of a private server can
-- change about the room they are paying for.
--
-- This is the whole reason a private server is worth buying, because it is the
-- only thing here that a public server cannot give you. A private server on its
-- own is just the same game with fewer people in it -- and since races in one
-- pay nothing (see Shared.PrivateServer), "the same game with fewer people and
-- no rewards" is a worse product than the free one. What makes it worth money
-- is control: race the map you want, with the sky you want, right now, instead
-- of waiting out a 60-second wave for a stage the game picked for you.
--
-- Scope is deliberately three controls and no more. Each removes a specific
-- friction the codebase already admits to:
--   * STAGE   -- every mode rolls a random stage (MatchService.rollStage).
--   * WEATHER -- the sky is a fixed property of that stage (Weather.GetForStage).
--   * START   -- the PLAY queue leaves on a 60s clock and refuses to launch
--                below MinPlayers, which QueueModes' own header notes can mean
--                a quiet server never fills a race at all.
--
-- Racer count is NOT here, and that is not an oversight: any player can already
-- pick 2-8 at the CUSTOM pad (QueueModes.CustomMin/CustomMax). Re-selling an
-- existing free feature as a private-server perk would be the kind of thing
-- that makes a purchase feel thin.
local HostControlService = {}

local getRemote: RemoteFunction
local setRemote: RemoteEvent
local changedRemote: RemoteEvent
local startNowRemote: RemoteEvent

-- nil means "leave it alone": roll the stage normally, use the stage's own
-- weather. That is also every public server's permanent state, since nothing
-- can ever set these there.
local stageId: string? = nil
local weatherName: string? = nil

local function isValidStage(id: any): boolean
	if typeof(id) ~= "string" then
		return false
	end
	for _, stage in Stages do
		if stage.Id == id then
			return true
		end
	end
	return false
end

local function isValidWeather(name: any): boolean
	return typeof(name) == "string" and Weather.Presets[name] ~= nil
end

local function snapshot()
	return { StageId = stageId, Weather = weatherName }
end

-- Broadcast, not a reply to whoever changed it. The stage and the sky are
-- visible to everyone in the room, so everyone's panel should agree about them
-- -- a guest watching the host switch to Stage 5 should see the panel say
-- Stage 5, not the stale value they were told when they joined.
local function broadcast()
	if changedRemote then
		changedRemote:FireAllClients(snapshot())
	end
end

function HostControlService.Init()
	getRemote = Net.CreateRemoteFunction(RemoteNames.GetHostControls)
	setRemote = Net.CreateRemoteEvent(RemoteNames.SetHostControl)
	changedRemote = Net.CreateRemoteEvent(RemoteNames.HostControlsChanged)
	startNowRemote = Net.CreateRemoteEvent(RemoteNames.StartRaceNow)

	-- Answers both halves at once, so the client needs one round trip to decide
	-- whether to build a panel at all AND what to put in it.
	getRemote.OnServerInvoke = function(player: Player)
		return {
			Enabled = PrivateServer.IsPrivate(),
			IsHost = PrivateServer.IsOwner(player),
			Settings = snapshot(),
		}
	end

	setRemote.OnServerEvent:Connect(function(player: Player, key: any, value: any)
		-- Re-checked here rather than trusted from the client that was told it
		-- was the host. A guest can fire this remote as easily as the owner
		-- can; being handed a panel is not permission to use one.
		if not PrivateServer.IsOwner(player) then
			return
		end

		if key == "StageId" then
			-- nil is the meaningful "back to random", so it has to pass while
			-- any other non-stage value is rejected.
			if value ~= nil and not isValidStage(value) then
				return
			end
			stageId = value
			MatchService.SetStageOverride(stageId)
		elseif key == "Weather" then
			if value ~= nil and not isValidWeather(value) then
				return
			end
			weatherName = value
			WeatherService.SetOverride(weatherName)
		else
			return
		end

		broadcast()
	end)

	startNowRemote.OnServerEvent:Connect(function(player: Player)
		if not PrivateServer.IsOwner(player) then
			return
		end

		-- The button says "start race now", so it starts a race now. It used to
		-- only cut short a wave the host had ALREADY joined via PLAY, which
		-- meant pressing it straight from the panel did nothing at all, with no
		-- feedback -- the queue was empty, so there was no wave to shorten.
		-- Reported from a playtest, and it is the obvious way to use the panel:
		-- open it, pick a stage, press the green button.
		--
		-- So a host who is not queued is queued first, and the wave leaves with
		-- them in it.
		local target = MatchService.QueuedTarget(player)
		if target == nil then
			MatchService.Enqueue(player)
		elseif target ~= QueueModes.AnySize then
			-- Waiting on an exact-fill station pad instead. Those start the
			-- instant they are full and have no clock to cut short, so there is
			-- nothing here to force -- and dragging the host out of the room
			-- they chose to stand in would be a stranger outcome than doing
			-- nothing.
			return
		end

		-- Return value ignored: the only remaining refusal is an empty queue,
		-- which the enqueue above has just ruled out for the host themselves.
		MatchService.ForceWaveDeparture()
	end)

	-- A private server outlives any one visit -- the owner can leave and their
	-- friends can keep playing -- but the settings are per-SERVER and reset
	-- when it empties and shuts down. Persisting them would mean a datastore
	-- round trip on a setting whose whole appeal is that it changes instantly,
	-- so a fresh server starts neutral and the host re-picks in two clicks.
	Players.PlayerAdded:Connect(function(player)
		if PrivateServer.IsPrivate() then
			changedRemote:FireClient(player, snapshot())
		end
	end)
end

return HostControlService
