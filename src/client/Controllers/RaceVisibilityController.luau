local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MatchStateController = require(script.Parent.MatchStateController)

-- Hides every character that isn't in THIS player's race.
--
-- Stages are shared: one course can be carrying a 1v1, a 3-player station race
-- and a 60-second wave at the same time. Without this you'd be running past a
-- crowd of strangers with no way to tell which of them you're actually racing
-- -- and the position readout ("3/5") would disagree with the number of people
-- visibly around you.
--
-- Purely cosmetic, and safe to be: player characters already can't collide with
-- each other (BotService registers a PlayerCharacters collision group with
-- collisions disabled against itself), so the players being hidden could never
-- have blocked, pushed or bumped anyone anyway.
local RaceVisibilityController = {}

local player = Players.LocalPlayer

-- Empty means "not racing" -- in the lobby everyone is visible, which is the
-- point of a lobby.
local roster: { [number]: boolean } = {}
local racing = false

-- LocalTransparencyModifier rather than Transparency: it's a client-only
-- property that never replicates and never touches the real Transparency the
-- server (or a trail/accessory) set, so restoring is just putting it back to 0
-- rather than having to remember what each part looked like.
--
-- `queryable` is separate from `hidden` because they answer different
-- questions. Hiding is about who you can SEE (only your own race); querying is
-- about who you can CLICK, which has to be closed for every other player while
-- racing, opponents included.
--
-- Blocking clicks via CanQuery rather than by turning core UI off: disabling
-- the avatar context menu through SetCore did not actually stop the profile
-- popup. Roblox's inspect UI finds what you clicked by querying the world, so
-- a character whose parts don't answer queries can't be picked in the first
-- place -- that holds regardless of which core UI is doing the asking.
--
-- Safe to write from the client on someone else's character: CanQuery is not a
-- physics property being fought over by the owner (unlike velocity/Anchored),
-- nothing on the server ever writes it on characters, and the Heartbeat loop
-- below re-asserts it anyway. It's local-only, so the server's own raycasts --
-- including StageService's checkpoint sweep -- are untouched.
local function setCharacterHidden(character: Model, hidden: boolean, queryable: boolean)
	local modifier = if hidden then 1 else 0
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = modifier
			part.CanQuery = queryable
		elseif part:IsA("Decal") then
			part.LocalTransparencyModifier = modifier
		elseif part:IsA("BillboardGui") or part:IsA("ParticleEmitter") or part:IsA("Trail") then
			-- Nameplates, emote bubbles and trails aren't parts, so the
			-- modifier doesn't reach them -- a hidden player would otherwise
			-- still be marked by a floating name and a trail streak.
			part.Enabled = not hidden
		end
	end
end

local function shouldHide(other: Player): boolean
	if other == player then
		return false
	end
	if not racing then
		return false
	end
	return not roster[other.UserId]
end

-- Practice bots are plain Models parented to Workspace, not Players, so the
-- roster can't speak about them at all -- a wave sharing a stage with somebody's
-- bot match would otherwise see a stray runner nobody is racing.
--
-- The rule is simply "hide every bot while I'm in a session race". It needs no
-- server flag because a bot match is never a session: MatchService keeps
-- botMatches separate from sessions and never broadcasts a roster for one, so
-- the player who owns the bot has `racing == false` here and keeps seeing it.
local BOT_MODEL_NAME = "RaceBot"
local bots: { [Model]: true } = {}

-- Set the moment the pre-race countdown starts, i.e. as soon as everyone is
-- teleported to the start line, and cleared on the way back to the lobby.
--
-- The countdown is not yet "Racing" and no roster has been broadcast, so
-- without this there was a window -- standing on the start grid waiting for GO
-- -- where every other racer was still fully clickable. That's precisely the
-- moment someone has nothing else to do, and it let you read the profile of a
-- player from a race you aren't in.
local staging = false

-- True for every kind of race, not just the ones that broadcast a roster:
-- station, wave and bot matches all need clicks closed off, and so does the
-- start-line wait before any of them begin.
local function inRace(): boolean
	return racing or staging or MatchStateController.CurrentState == "Racing"
end

-- Exposed because CanQuery does NOT stop a ClickDetector: ProfileCardController
-- attaches one per body part, and MouseClick still fires on parts that answer no
-- spatial queries. The visibility rules and the click rules therefore have to be
-- enforced in two different places from one shared answer, rather than the
-- second falling out of the first as originally assumed.
function RaceVisibilityController.IsInRace(): boolean
	return inRace()
end

local function refresh()
	local blockClicks = inRace()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			-- Your own character stays queryable -- blocking it would break
			-- anything that raycasts against yourself, and you can't open your
			-- own profile popup by clicking anyway.
			local queryable = other == player or not blockClicks
			setCharacterHidden(character, shouldHide(other), queryable)
		end
	end
	-- Bots stay queryable: they aren't players, so clicking one reveals nothing
	-- about anybody, and the bot's own owner needs to see it normally.
	for bot in bots do
		setCharacterHidden(bot, racing, true)
	end
end

-- The player list is a second route to another player's identity, so it goes
-- away during a race for the same reason the characters do.
--
-- The avatar context menu is NOT handled here: ProfileCardController disables
-- it outright for the whole session, since it conflicts with the profile card
-- everywhere, not just mid-race. The click block that actually protects a race
-- is CanQuery in setCharacterHidden above.
--
-- pcall'd because SetCoreGuiEnabled throws if the CoreGui hasn't registered the
-- callback yet, which can happen on the first frames of a session; losing the
-- lockdown is survivable, an error during Init is not.
local function setInspectionEnabled(enabled: boolean)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
	end)
end

function RaceVisibilityController.Init()
	local function onStateChanged()
		-- Back in the lobby means the staging window is over, however it ended
		-- -- raced, quit, or a countdown that never departed.
		if MatchStateController.CurrentState == "Lobby" then
			staging = false
		end
		setInspectionEnabled(not inRace())
		-- Also refresh, because entering a bot or station race changes who may
		-- be clicked without any roster arriving to trigger it.
		refresh()
	end
	onStateChanged()
	MatchStateController.StateChanged:Connect(onStateChanged)

	-- Teleported to the start line: close clicks off now, not at GO.
	Net.GetRemoteEvent(RemoteNames.PreRaceCountdown).OnClientEvent:Connect(function()
		staging = true
		setInspectionEnabled(false)
		refresh()
	end)

	Net.GetRemoteEvent(RemoteNames.RaceRosterChanged).OnClientEvent:Connect(function(userIds: { number }?)
		roster = {}
		racing = userIds ~= nil
		if userIds then
			for _, userId in userIds do
				roster[userId] = true
			end
		end
		refresh()
	end)

	-- Re-applied on a loop, not just on roster changes, for two reasons: a
	-- character that streams in or respawns mid-race arrives with fresh parts
	-- that were never hidden, and Roblox itself resets
	-- LocalTransparencyModifier on characters in some camera/state transitions.
	-- Cheap enough at this rate to simply reassert the truth every so often
	-- rather than trying to hook every event that could disturb it.
	RunService.Heartbeat:Connect(function()
		-- inRace rather than `racing`, so a bot or station match -- which never
		-- broadcasts a roster -- still gets its click block re-asserted.
		if not inRace() then
			return
		end
		refresh()
	end)

	-- A player joining or respawning mid-race needs hiding immediately rather
	-- than on the next tick, or they pop into view for a frame.
	Players.PlayerAdded:Connect(function(other)
		other.CharacterAdded:Connect(refresh)
	end)
	for _, other in Players:GetPlayers() do
		other.CharacterAdded:Connect(refresh)
	end

	-- Tracked by signal rather than rescanning Workspace on the heartbeat loop,
	-- since Workspace holds every stage part in the game and bots appear a
	-- handful at a time.
	local function trackBot(child: Instance)
		if child:IsA("Model") and child.Name == BOT_MODEL_NAME then
			bots[child] = true
			-- Hidden on arrival rather than on the next tick, or a bot spawning
			-- next to a wave pops into view for a frame.
			setCharacterHidden(child, racing)
		end
	end
	Workspace.ChildAdded:Connect(trackBot)
	Workspace.ChildRemoved:Connect(function(child)
		if child:IsA("Model") then
			bots[child :: Model] = nil
		end
	end)
	for _, child in Workspace:GetChildren() do
		trackBot(child)
	end
end

return RaceVisibilityController
