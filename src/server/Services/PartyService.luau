local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Playing with friends is one of the strongest retention/virality levers in
-- any multiplayer game -- without this, two friends who queue even a few
-- seconds apart land in separate races by pure luck of MatchingSeconds
-- timing. A party is just a shared set of userIds; queuing while partied
-- (see MatchService.Enqueue) enqueues the whole set atomically in one pass,
-- so they're guaranteed to land in the same session together regardless of
-- exactly when each of them clicked PLAY.
local PartyService = {}

local INVITE_TTL = 30

local nextPartyId = 1
local partyOf: { [number]: number } = {} -- userId -> partyId
local partyMembers: { [number]: { [number]: boolean } } = {} -- partyId -> set of userIds
local pendingInvites: { [number]: { fromUserId: number, expiresAt: number } } = {} -- toUserId -> invite
-- The reverse direction of pendingInvites: a viewer asking to join SOMEONE
-- ELSE's party (from the profile card's "Request to Join Party" button)
-- instead of that person inviting the viewer. Keyed by the party OWNER being
-- asked, same TTL/shape as pendingInvites so the accept/decline UI can reuse
-- the same toast pattern.
local pendingJoinRequests: { [number]: { fromUserId: number, expiresAt: number } } = {} -- toUserId (party owner) -> request

local partyInviteRemote: RemoteEvent
local partyUpdatedRemote: RemoteEvent
local joinRequestReceivedRemote: RemoteEvent

local function getPlayer(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

local function broadcastParty(partyId: number)
	local members = partyMembers[partyId]
	if not members then
		return
	end
	local names = {}
	for userId in members do
		local p = getPlayer(userId)
		if p then
			table.insert(names, p.Name)
		end
	end
	for userId in members do
		local p = getPlayer(userId)
		if p then
			partyUpdatedRemote:FireClient(p, names)
		end
	end
end

-- Solo callers (not partied) just race as themselves -- this always returns
-- at least {player}, never an empty list, so callers don't need a separate
-- "am I partied" branch.
function PartyService.GetPartyMembers(player: Player): { Player }
	local partyId = partyOf[player.UserId]
	if not partyId or not partyMembers[partyId] then
		return { player }
	end

	local result = {}
	for userId in partyMembers[partyId] do
		local p = getPlayer(userId)
		if p then
			table.insert(result, p)
		end
	end
	if #result == 0 then
		return { player }
	end
	return result
end

function PartyService.LeaveParty(player: Player)
	local userId = player.UserId
	local partyId = partyOf[userId]
	if not partyId then
		return
	end
	partyOf[userId] = nil

	local members = partyMembers[partyId]
	if not members then
		return
	end
	members[userId] = nil

	local remaining = {}
	for id in members do
		table.insert(remaining, id)
	end

	if #remaining <= 1 then
		-- Down to a solo member (or none) -- fully disband rather than
		-- leaving a "party of 1" hanging around.
		for _, id in remaining do
			partyOf[id] = nil
			local p = getPlayer(id)
			if p then
				partyUpdatedRemote:FireClient(p, {})
			end
		end
		partyMembers[partyId] = nil
	else
		broadcastParty(partyId)
	end

	partyUpdatedRemote:FireClient(player, {})
end

local function createInvite(fromPlayer: Player, toPlayer: Player)
	if fromPlayer.UserId == toPlayer.UserId then
		return
	end
	pendingInvites[toPlayer.UserId] = { fromUserId = fromPlayer.UserId, expiresAt = os.clock() + INVITE_TTL }
	partyInviteRemote:FireClient(toPlayer, fromPlayer.Name)
end

local function acceptInvite(player: Player)
	local invite = pendingInvites[player.UserId]
	if not invite or os.clock() > invite.expiresAt then
		pendingInvites[player.UserId] = nil
		return
	end
	pendingInvites[player.UserId] = nil

	local inviter = getPlayer(invite.fromUserId)
	if not inviter then
		return
	end

	-- Leave any existing party first (rare, but keeps membership clean if
	-- someone had a stale invite from before).
	PartyService.LeaveParty(player)

	local partyId = partyOf[inviter.UserId]
	if not partyId then
		partyId = nextPartyId
		nextPartyId += 1
		partyMembers[partyId] = { [inviter.UserId] = true }
		partyOf[inviter.UserId] = partyId
	end

	partyMembers[partyId][player.UserId] = true
	partyOf[player.UserId] = partyId

	broadcastParty(partyId)
end

local function declineInvite(player: Player)
	pendingInvites[player.UserId] = nil
end

-- Reverse of createInvite: the VIEWER is the one asking, the TARGET is the
-- party they want to join (see the profile card's "Request to Join Party").
local function createJoinRequest(viewer: Player, target: Player)
	if viewer.UserId == target.UserId then
		return
	end
	pendingJoinRequests[target.UserId] = { fromUserId = viewer.UserId, expiresAt = os.clock() + INVITE_TTL }
	joinRequestReceivedRemote:FireClient(target, viewer.Name)
end

-- Called when the party owner (or any current member -- whoever's online and
-- taps Accept) approves a pending join request. Unlike acceptInvite (where
-- the ACCEPTING player joins the INVITER's party), here the ACCEPTING player
-- keeps their own party and the REQUESTER (fromUserId) is the one who moves.
local function acceptJoinRequest(target: Player)
	local request = pendingJoinRequests[target.UserId]
	if not request or os.clock() > request.expiresAt then
		pendingJoinRequests[target.UserId] = nil
		return
	end
	pendingJoinRequests[target.UserId] = nil

	local viewer = getPlayer(request.fromUserId)
	if not viewer then
		return
	end

	PartyService.LeaveParty(viewer)

	local partyId = partyOf[target.UserId]
	if not partyId then
		partyId = nextPartyId
		nextPartyId += 1
		partyMembers[partyId] = { [target.UserId] = true }
		partyOf[target.UserId] = partyId
	end

	partyMembers[partyId][viewer.UserId] = true
	partyOf[viewer.UserId] = partyId

	broadcastParty(partyId)
end

local function declineJoinRequest(target: Player)
	pendingJoinRequests[target.UserId] = nil
end

function PartyService.Init()
	partyInviteRemote = Net.CreateRemoteEvent(RemoteNames.PartyInviteReceived)
	partyUpdatedRemote = Net.CreateRemoteEvent(RemoteNames.PartyUpdated)

	local requestInviteRemote = Net.CreateRemoteEvent(RemoteNames.RequestPartyInvite)
	requestInviteRemote.OnServerEvent:Connect(function(player: Player, targetUserId: number)
		if typeof(targetUserId) ~= "number" then
			return
		end
		local target = getPlayer(targetUserId)
		if target then
			createInvite(player, target)
		end
	end)

	local respondRemote = Net.CreateRemoteEvent(RemoteNames.RespondToPartyInvite)
	respondRemote.OnServerEvent:Connect(function(player: Player, accepted: boolean)
		if accepted then
			acceptInvite(player)
		else
			declineInvite(player)
		end
	end)

	local leaveRemote = Net.CreateRemoteEvent(RemoteNames.LeaveParty)
	leaveRemote.OnServerEvent:Connect(function(player: Player)
		PartyService.LeaveParty(player)
	end)

	joinRequestReceivedRemote = Net.CreateRemoteEvent(RemoteNames.JoinRequestReceived)

	local requestJoinRemote = Net.CreateRemoteEvent(RemoteNames.RequestJoinParty)
	requestJoinRemote.OnServerEvent:Connect(function(player: Player, targetUserId: number)
		if typeof(targetUserId) ~= "number" then
			return
		end
		local target = getPlayer(targetUserId)
		if target then
			createJoinRequest(player, target)
		end
	end)

	local respondJoinRemote = Net.CreateRemoteEvent(RemoteNames.RespondToJoinRequest)
	respondJoinRemote.OnServerEvent:Connect(function(player: Player, accepted: boolean)
		if accepted then
			acceptJoinRequest(player)
		else
			declineJoinRequest(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		pendingInvites[player.UserId] = nil
		pendingJoinRequests[player.UserId] = nil
		PartyService.LeaveParty(player)
	end)
end

return PartyService
