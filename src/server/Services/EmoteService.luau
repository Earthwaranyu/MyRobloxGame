local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local PlayerDataService = require(script.Parent.PlayerDataService)

-- Validates + broadcasts "play this emote" (the actual above-head bubble is
-- purely a client-side visual, see client/Controllers/EmoteDisplayController)
-- and handles the Robux prompt for locked ones. Receipt granting itself
-- lives in PurchaseService, not here (see that module for why).
local EmoteService = {}

local COOLDOWN_SECONDS = 1.2

local emoteById: { [string]: any } = {}
for _, emote in Emotes do
	emoteById[emote.Id] = emote
end

local lastEmoteAt: { [number]: number } = {}

local function isUnlocked(profile: { [string]: any }, emote): boolean
	return emote.RobuxProductId == nil or table.find(profile.OwnedEmotes or {}, emote.Id) ~= nil
end

function EmoteService.Init()
	local playEmoteRemote = Net.CreateRemoteEvent(RemoteNames.PlayEmote)
	local emotePlayedRemote = Net.CreateRemoteEvent(RemoteNames.EmotePlayed)
	local promptEmoteRemote = Net.CreateRemoteEvent(RemoteNames.PromptEmotePurchase)

	playEmoteRemote.OnServerEvent:Connect(function(player: Player, emoteId: string)
		local emote = emoteById[emoteId]
		local profile = PlayerDataService.GetProfile(player)
		if not emote or not profile or not isUnlocked(profile, emote) then
			return
		end

		local now = os.clock()
		if now - (lastEmoteAt[player.UserId] or 0) < COOLDOWN_SECONDS then
			return
		end
		lastEmoteAt[player.UserId] = now

		for _, otherPlayer in Players:GetPlayers() do
			emotePlayedRemote:FireClient(otherPlayer, player, emoteId)
		end
	end)

	promptEmoteRemote.OnServerEvent:Connect(function(player: Player, emoteId: string)
		local emote = emoteById[emoteId]
		if emote and emote.RobuxProductId and emote.RobuxProductId ~= 0 then
			MarketplaceService:PromptProductPurchase(player, emote.RobuxProductId)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastEmoteAt[player.UserId] = nil
	end)
end

return EmoteService
