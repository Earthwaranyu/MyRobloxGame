local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

-- Every call into Roblox's AnalyticsService goes through here.
--
-- The game had no instrumentation of any kind, which made "why do players
-- leave?" unanswerable by anything but guesswork -- and retention is the
-- single largest input to how the platform recommends an experience. The
-- events below are chosen to answer specific questions, not to log
-- everything:
--
--   * the ONBOARDING funnel answers "where does a brand-new player stop?"
--     across their first session -- joined, taught, queued, raced, finished.
--   * the MATCH funnel answers "how often does pressing PLAY actually produce
--     a race?" Queued -> Matched is the important step: a big drop there means
--     players are sitting in a queue that never fills, which no amount of
--     content will fix.
--   * ECONOMY events make points a currency the dashboard understands, so
--     earn/spend can be balanced against each other rather than by feel.
--
-- Named TelemetryService, not AnalyticsService, purely so this module and the
-- Roblox service it wraps can be told apart at every call site.
local TelemetryService = {}

-- Analytics must never be able to break gameplay. Every entry point is
-- wrapped: these calls hit an external pipeline, and a throttle or an outage
-- on Roblox's side must not propagate into the match loop that calls them.
-- Failures are swallowed rather than warned about -- a broken pipeline would
-- otherwise flood the log once per race per player.
local function safely(fn: () -> ())
	pcall(fn)
end

-- Onboarding is a per-ACCOUNT funnel, not per-session: Roblox aggregates it
-- against a player's first experiences, so re-firing "Joined" every time a
-- veteran rejoins would drown the real signal. Cleared on leave so a rejoin
-- inside the same server doesn't double-count either.
local onboardingSeen: { [number]: { [number]: boolean } } = {}

local ONBOARDING_STEPS = {
	Joined = 1,
	TutorialSeen = 2,
	FirstQueue = 3,
	FirstRace = 4,
	FirstFinish = 5,
}

function TelemetryService.Onboarding(player: Player, stepName: string)
	local stepNumber = ONBOARDING_STEPS[stepName]
	if not stepNumber then
		return
	end
	local seen = onboardingSeen[player.UserId]
	if not seen then
		seen = {}
		onboardingSeen[player.UserId] = seen
	end
	if seen[stepNumber] then
		return
	end
	seen[stepNumber] = true

	safely(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, stepNumber, stepName)
	end)
end

local MATCH_FUNNEL = "Match"
local MATCH_STEPS = {
	Queued = 1,
	Matched = 2,
	Started = 3,
	Finished = 4,
}

-- One funnel session per race ATTEMPT, so a player who queues, quits, and
-- queues again produces two independent journeys rather than one journey that
-- appears to have reached step 1 twice. Handed out here so every call site
-- shares the same id for the same attempt.
local matchSession: { [number]: string } = {}
local sessionCounter = 0

function TelemetryService.BeginMatchAttempt(player: Player)
	sessionCounter += 1
	matchSession[player.UserId] = ("%d-%d"):format(player.UserId, sessionCounter)
end

function TelemetryService.MatchStep(player: Player, stepName: string, mode: string?)
	local stepNumber = MATCH_STEPS[stepName]
	local sessionId = matchSession[player.UserId]
	if not stepNumber or not sessionId then
		return
	end

	safely(function()
		AnalyticsService:LogFunnelStepEvent(player, MATCH_FUNNEL, sessionId, stepNumber, stepName)
	end)

	if mode then
		safely(function()
			AnalyticsService:LogCustomEvent(player, "MatchStep_" .. stepName, 1, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = mode,
			})
		end)
	end
end

-- Ends the attempt without a Finished step: quit, disconnect, or a queue that
-- never filled. The absence of step 4 for this session IS the signal, so
-- there's nothing to log -- this just stops a later, unrelated event being
-- attributed to a journey that's over.
function TelemetryService.EndMatchAttempt(player: Player)
	matchSession[player.UserId] = nil
end

-- currency/amount/balance in the dashboard's terms. `sku` is what was bought
-- or what paid out -- the stage for a race reward, the item for a purchase --
-- so earn and spend can be broken down by source rather than sitting in one
-- undifferentiated bucket.
function TelemetryService.Economy(
	player: Player,
	isSource: boolean,
	currency: string,
	amount: number,
	endingBalance: number,
	transactionType: Enum.AnalyticsEconomyTransactionType,
	sku: string?
)
	if amount <= 0 then
		return
	end
	safely(function()
		AnalyticsService:LogEconomyEvent(
			player,
			if isSource then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink,
			currency,
			amount,
			math.max(0, endingBalance),
			transactionType.Name,
			sku
		)
	end)
end

-- Free-form event for things that aren't a funnel step or a transaction.
-- Roblox allows exactly three custom field keys, so callers pass an ordered
-- list and this maps it onto CustomField01..03 rather than every call site
-- having to remember the enum names.
function TelemetryService.Custom(player: Player, eventName: string, value: number?, fields: { string }?)
	safely(function()
		local mapped: { [string]: string }? = nil
		if fields then
			mapped = {}
			local keys = {
				Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
				Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
				Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
			}
			for index, fieldValue in fields do
				local key = keys[index]
				if key then
					(mapped :: { [string]: string })[key] = fieldValue
				end
			end
		end
		AnalyticsService:LogCustomEvent(player, eventName, value, mapped)
	end)
end

function TelemetryService.Init()
	Players.PlayerAdded:Connect(function(player: Player)
		TelemetryService.Onboarding(player, "Joined")
	end)
	for _, player in Players:GetPlayers() do
		TelemetryService.Onboarding(player, "Joined")
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		onboardingSeen[player.UserId] = nil
		matchSession[player.UserId] = nil
	end)
end

return TelemetryService
