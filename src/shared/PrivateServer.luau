-- Private servers ("VIP servers"): a player buys, or is gifted, their own
-- instance of the experience and controls who may join it.
--
-- SELLING one is a Creator Dashboard setting, not code. Nothing here creates,
-- prices or advertises a private server -- Roblox does all of that, and the
-- feature is dark until it is switched on for the place. What this module
-- answers is the only question the GAME has to make up its own mind about once
-- a private server exists: does what happens inside one count for the ladder?
--
-- It must not, and the reason is farming. Every anti-farm measure the ranked
-- path has assumes a server the farmer does not control -- rematch decay
-- (MatchService.consumeRematchWeight) assumes fresh opponents eventually turn
-- up, the account-age weight assumes alts have to queue alongside real players,
-- and the Elo floor starves a drained alt only because it cannot pick its
-- opponents. A private server voids all three at once: two accounts, no
-- strangers, no shared queue, and a win streak that is unbounded and broadcasts
-- to the whole hype feed.
--
-- So a private server is CASUAL. The race itself is untouched -- stages,
-- gimmicks, abilities, trails, emotes, bots, the countdown, the finish line --
-- and the only thing that changes is that nothing is written to rating, points,
-- win/loss records or the global boards. That is the same zero-stakes shape
-- practice runs already have, so it is a familiar state rather than a new one.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PrivateServer = {}

-- STUDIO TESTING SWITCH. Flip to true to make a Studio session behave as a
-- private server; set it back to false before publishing.
--
-- Studio has no private-server mode and cannot be given one: PrivateServerId
-- and PrivateServerOwnerId are both read-only, and Studio leaves them empty, so
-- a real private server can only be entered on the published experience. Every
-- casual/host code path would therefore be unreachable from Studio without a
-- switch like this, which is worse than the switch.
--
-- The IsStudio guard is the safety property, and the reason this is allowed to
-- exist at all: committing it as `true` by accident cannot make a live server
-- casual or hand a live player the host panel. The worst it can do is affect
-- your own test session.
local SIMULATE_PRIVATE_IN_STUDIO = true

local function simulating(): boolean
	return SIMULATE_PRIVATE_IN_STUDIO and RunService:IsStudio()
end

-- Whoever joined the simulated server first, so a two-client Studio test gives
-- Player1 the host panel and Player2 a guest's view -- which is the pairing
-- worth testing, since the guest path is the one that must be refused.
-- Captured once so it cannot change hands mid-session if Player1 leaves.
local simulatedOwnerId: number? = nil

-- How the client is told. NEITHER private-server property can be read from a
-- client -- both PrivateServerOwnerId and PrivateServerId log "cannot be
-- checked on the client, please check on the server" and hand back a default,
-- so a client asking directly is told "public" in every server there is. The
-- server therefore publishes the answer once at startup and the client reads
-- that instead.
--
-- An attribute rather than a RemoteFunction because it replicates with the
-- rest of ReplicatedStorage on join, needs no round trip, and is readable
-- again at any time by anything that cares -- there is no request to miss.
local CASUAL_ATTRIBUTE = "CasualServer"

-- On the server this reads PrivateServerOwnerId, and deliberately NOT
-- PrivateServerId. Both are set in a player-owned private server, but
-- PrivateServerId alone is also set in a reserved server
-- (TeleportService:ReserveServer). The game does not use reserved servers
-- today, though a party-only match is the obvious thing that would want one --
-- and a reserved match should stay fully RANKED, since that server is
-- allocated by the game rather than chosen by a player. Keying on the owner
-- keeps that door open instead of quietly closing it.
--
-- On the client it reads whatever the server published (see Publish). Before
-- that lands the attribute is nil and this answers "public", which is why the
-- one client-side consumer observes the value instead of sampling it once --
-- see ObserveCasual.
function PrivateServer.IsPrivate(): boolean
	if RunService:IsServer() then
		return simulating() or game.PrivateServerOwnerId ~= 0
	end
	return ReplicatedStorage:GetAttribute(CASUAL_ATTRIBUTE) == true
end

-- Server-side, called once at startup. Always writes, including the `false`
-- case: a client needs to be able to tell "published, public" from "not
-- published yet", and only an explicitly written value does that.
function PrivateServer.Publish()
	ReplicatedStorage:SetAttribute(CASUAL_ATTRIBUTE, PrivateServer.IsPrivate())
end

-- Client-side. Fires the callback with the current answer as soon as one
-- exists, and again if it ever changes.
--
-- Deliberately does NOT yield. The publish above happens during server
-- startup, which usually beats any client script, but "usually" is not a
-- guarantee worth blocking a controller's Init on -- so a caller gets a
-- possibly-stale `false` immediately and the truth the moment it arrives,
-- rather than a UI that hangs waiting for it.
function PrivateServer.ObserveCasual(callback: (boolean) -> ())
	local function push()
		if ReplicatedStorage:GetAttribute(CASUAL_ATTRIBUTE) ~= nil then
			callback(PrivateServer.IsPrivate())
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal(CASUAL_ATTRIBUTE):Connect(push)
	push()
end

-- UserId of the player who owns this private server, or 0 in a public one.
-- Server-only, for the reason above; the client always reads 0.
function PrivateServer.OwnerId(): number
	if simulating() then
		-- Resolved lazily, not at load: this module is required during server
		-- startup, well before anyone has joined, so there is no first player
		-- to read yet. Left uncached until there IS one, so the first call
		-- cannot freeze the answer at "nobody".
		if not simulatedOwnerId then
			local first = Players:GetPlayers()[1]
			if first then
				simulatedOwnerId = first.UserId
			end
		end
		return simulatedOwnerId or 0
	end
	return game.PrivateServerOwnerId
end

-- Whether this player is the one who owns this private server, and so the only
-- one allowed to touch the host controls (see HostControlService).
--
-- Server-only, because it rests on OwnerId. There is deliberately no client
-- equivalent: the client is TOLD whether it is the host by GetHostControls,
-- and every control it can operate is re-checked here before it is acted on.
-- A client that lies about being the host gets a panel it can open and nothing
-- that happens when it presses anything.
--
-- False in a public server, where there is no owner and so no host.
function PrivateServer.IsOwner(player: Player): boolean
	return PrivateServer.IsPrivate() and player.UserId == PrivateServer.OwnerId()
end

-- The single question every scoring path asks. Named for what is being decided
-- rather than for private servers specifically, so the next zero-stakes context
-- -- an event server, a staging place -- has one obvious place to hook into
-- instead of another scattering of `if` statements across the services.
function PrivateServer.CountsForLadder(): boolean
	return not PrivateServer.IsPrivate()
end

return PrivateServer
