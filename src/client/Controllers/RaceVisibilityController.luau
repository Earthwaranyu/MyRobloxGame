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
local function setCharacterHidden(character: Model, hidden: boolean)
	local modifier = if hidden then 1 else 0
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") or part:IsA("Decal") then
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

local function refresh()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			setCharacterHidden(character, shouldHide(other))
		end
	end
	for bot in bots do
		setCharacterHidden(bot, racing)
	end
end

-- Hiding a character is only half the job: an invisible player is still there
-- to be clicked, and Roblox's own inspect UI will happily name them. That makes
-- the whole separation cosmetic and trivially bypassable -- you could sit on the
-- start line double-clicking your way through a race you aren't in.
--
-- So while racing, the two routes to another player's identity are closed: the
-- avatar context menu (double-clicking a character) and the player list (whose
-- rows open the same profile popup). Both come back the moment the race ends.
--
-- Keyed off MatchStateController rather than the roster, because it has to hold
-- for EVERY kind of race -- station, wave and bot matches alike -- not just the
-- ones that broadcast a roster.
--
-- pcall'd because SetCore/SetCoreGuiEnabled throw if the CoreGui hasn't
-- registered the callback yet, which can happen on the first frames of a
-- session; losing the lockdown is survivable, an error during Init is not.
local function setInspectionEnabled(enabled: boolean)
	pcall(function()
		StarterGui:SetCore("AvatarContextMenuEnabled", enabled)
	end)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, enabled)
	end)
end

function RaceVisibilityController.Init()
	local function updateInspection()
		setInspectionEnabled(MatchStateController.CurrentState ~= "Racing")
	end
	updateInspection()
	MatchStateController.StateChanged:Connect(updateInspection)

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
		if not racing then
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
