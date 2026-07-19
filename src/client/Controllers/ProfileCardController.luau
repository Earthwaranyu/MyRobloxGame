local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- "Double-click another player to see their profile" (rank, win rate,
-- equipped ability, wins/losses, playtime, request 1v1, request to join
-- party). ClickDetector is created and owned entirely client-side, one per
-- OTHER player's character (see TrailVisualsController for the same
-- watch-every-player CharacterAdded pattern) -- it never needs to replicate,
-- since only the local player's own clicks on it matter.
local ProfileCardController = {}

local DOUBLE_CLICK_WINDOW = 0.4
local CLICK_ACTIVATION_DISTANCE = 12
local DUEL_REQUEST_TTL_DISPLAY = 30

local player = Players.LocalPlayer

local getSummaryRemote: RemoteFunction
local requestJoinRemote: RemoteEvent
local requestDuelRemote: RemoteEvent
local respondDuelRemote: RemoteEvent

local lastClickTime: { [number]: number } = {}

local panel: CanvasGroup
local nameLabel: TextLabel
local rankLabel: TextLabel
local statsLabel: TextLabel
local duelButton: TextButton
local joinPartyButton: TextButton
-- duelButton/joinPartyButton are fixed, reused instances (the card is
-- rebuilt in place for whoever was last double-clicked, not recreated per
-- open) -- their click handlers are wired ONCE in buildUI and read this
-- upvalue, rather than each openProfileCard call layering on another
-- one-shot closure (which would leak a stale listener per open targeting
-- the wrong player if the buttons were never clicked in between).
local currentTarget: Player? = nil

local duelToast: CanvasGroup
local duelToastLabel: TextLabel
-- Not a real Roblox UserId -- just a monotonically increasing token (same
-- idea as noticeToken below) so the delayed auto-hide can tell "is the toast
-- still showing the challenge it was scheduled for" without the server
-- needing to round-trip the challenger's actual userId through this remote.
local duelToastToken = 0

local noticeToast: CanvasGroup
local noticeLabel: TextLabel
local noticeToken = 0

local function formatPlaytime(totalSeconds: number): string
	local minutes = math.floor(totalSeconds / 60)
	if minutes < 60 then
		return ("%dm"):format(minutes)
	end
	local hours = math.floor(minutes / 60)
	return ("%dh %dm"):format(hours, minutes % 60)
end

local function showNotice(text: string)
	noticeToken += 1
	local myToken = noticeToken
	noticeLabel.Text = text
	Widgets.Open(noticeToast)
	task.delay(4, function()
		if noticeToken == myToken then
			Widgets.Close(noticeToast)
		end
	end)
end

local function openProfileCard(target: Player)
	local summary = getSummaryRemote:InvokeServer(target.UserId)
	if not summary then
		return
	end

	currentTarget = target

	nameLabel.Text = summary.Name
	rankLabel.Text = summary.Rank .. "  ·  " .. summary.Elo .. " elo"
	rankLabel.TextColor3 = Theme.GetRankColor(summary.Rank)

	local winRatePercent = math.floor(summary.WinRate * 100 + 0.5)
	statsLabel.Text = table.concat({
		("Wins: %d    Losses: %d    Win Rate: %d%%"):format(summary.Wins, summary.Losses, winRatePercent),
		("Ability: %s"):format(summary.EquippedAbility),
		("Time Played: %s"):format(formatPlaytime(summary.PlaytimeSeconds)),
	}, "\n")

	Sounds.Play("Reveal")
	openPanel()
end

local function hideDuelToast()
	duelToastToken += 1
	Widgets.Close(duelToast)
end

local function showDuelToast(fromName: string)
	duelToastToken += 1
	local myToken = duelToastToken
	duelToastLabel.Text = fromName .. " challenged you to a 1v1!"
	Sounds.Play("Reveal")
	Widgets.Open(duelToast)

	task.delay(DUEL_REQUEST_TTL_DISPLAY, function()
		if duelToastToken == myToken then
			hideDuelToast()
		end
	end)
end

local openPanel: () -> ()
local closePanel: () -> ()

local function buildUI()
	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) -- this panel
	-- has no persistent toggle button (it only opens from a double-click),
	-- so click-outside/✕ are the ONLY way to dismiss it besides its own
	-- buttons, which makes them non-optional here, not just a nicety.
	-- 284 tall, not 300 -- that extra ~36px used to hold a "Close" button
	-- doing the exact same thing as the modal's own close-✕ one inch above it.
	panel, openPanel, closePanel = Widgets.Modal("ProfileCard", UDim2.fromOffset(380, 284), UDim2.new(0.5, -190, 0.5, -142), {
		DisplayOrder = 30,
	})

	nameLabel = Widgets.Label("", UDim2.new(1, -16, 0, 30), UDim2.fromOffset(8, 6), {
		TextSize = 22,
	})
	nameLabel.Parent = panel

	rankLabel = Widgets.Label("", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 38), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rankLabel.Parent = panel

	statsLabel = Widgets.Label("", UDim2.new(1, -16, 0, 100), UDim2.fromOffset(8, 68), {
		TextSize = 15,
		Color = Theme.Color.TextPrimary,
		Bold = false,
	})
	statsLabel.TextWrapped = true
	statsLabel.Parent = panel

	duelButton = Widgets.Button("Request 1v1", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 180), {
		Variant = "Primary",
		TextSize = 15,
	})
	duelButton.Parent = panel
	duelButton.MouseButton1Click:Connect(function()
		if not currentTarget then
			return
		end
		requestDuelRemote:FireServer(currentTarget.UserId)
		showNotice("Duel request sent to " .. currentTarget.Name .. "!")
		closePanel()
	end)

	joinPartyButton = Widgets.Button("Ask to Join Party", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 226), {
		Variant = "Secondary",
		TextSize = 15,
	})
	joinPartyButton.Parent = panel
	joinPartyButton.MouseButton1Click:Connect(function()
		if not currentTarget then
			return
		end
		requestJoinRemote:FireServer(currentTarget.UserId)
		showNotice("Asked to join " .. currentTarget.Name .. "'s party!")
		closePanel()
	end)

	-- Incoming duel challenge toast, separate GUI/panel from the profile card
	-- itself so it can pop up regardless of whether a card is currently open.
	local toastGui = Instance.new("ScreenGui")
	toastGui.Name = "DuelToastGui"
	toastGui.ResetOnSpawn = false
	toastGui.DisplayOrder = 12
	toastGui.Parent = player:WaitForChild("PlayerGui")

	duelToast = Widgets.Panel(UDim2.fromOffset(360, 130), UDim2.new(0.5, -180, 0.24, 300))
	duelToast.Parent = toastGui

	duelToastLabel = Widgets.Label("", UDim2.new(1, -20, 0, 44), UDim2.fromOffset(10, 12), {
		TextSize = 17,
		Align = Enum.TextXAlignment.Center,
	})
	duelToastLabel.TextWrapped = true
	duelToastLabel.Parent = duelToast

	local acceptButton = Widgets.Button("Accept", UDim2.fromOffset(150, 40), UDim2.fromOffset(20, 78), {
		Variant = "Success",
		TextSize = 15,
	})
	acceptButton.Parent = duelToast
	acceptButton.MouseButton1Click:Connect(function()
		respondDuelRemote:FireServer(true)
		hideDuelToast()
	end)

	local declineButton = Widgets.Button("Decline", UDim2.fromOffset(150, 40), UDim2.fromOffset(190, 78), {
		Variant = "Danger",
		TextSize = 15,
	})
	declineButton.Parent = duelToast
	declineButton.MouseButton1Click:Connect(function()
		respondDuelRemote:FireServer(false)
		hideDuelToast()
	end)

	-- Small auto-fading notice (duel sent/cancelled, join request sent) --
	-- informational only, no buttons, doesn't compete for the same screen
	-- space as the accept/decline toasts above.
	local noticeGui = Instance.new("ScreenGui")
	noticeGui.Name = "ProfileNoticeGui"
	noticeGui.ResetOnSpawn = false
	noticeGui.DisplayOrder = 12
	noticeGui.Parent = player:WaitForChild("PlayerGui")

	noticeToast = Widgets.Panel(UDim2.fromOffset(340, 64), UDim2.new(0.5, -170, 0.14, 0))
	noticeToast.Parent = noticeGui

	noticeLabel = Widgets.Label("", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Center,
	})
	noticeLabel.TextWrapped = true
	noticeLabel.Parent = noticeToast
end

local function watchCharacter(target: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not root then
		return
	end

	local clickDetector = Instance.new("ClickDetector")
	clickDetector.Name = "ProfileCardClickDetector"
	clickDetector.MaxActivationDistance = CLICK_ACTIVATION_DISTANCE
	clickDetector.Parent = root

	clickDetector.MouseClick:Connect(function()
		local now = os.clock()
		local last = lastClickTime[target.UserId]
		lastClickTime[target.UserId] = now
		if last and now - last <= DOUBLE_CLICK_WINDOW then
			lastClickTime[target.UserId] = nil
			openProfileCard(target)
		end
	end)
end

local function watchPlayer(target: Player)
	if target == player then
		return
	end
	target.CharacterAdded:Connect(function(character)
		watchCharacter(target, character)
	end)
	if target.Character then
		watchCharacter(target, target.Character)
	end
end

function ProfileCardController.Init()
	buildUI()

	getSummaryRemote = Net.GetRemoteFunction(RemoteNames.GetPlayerProfileSummary)
	requestJoinRemote = Net.GetRemoteEvent(RemoteNames.RequestJoinParty)
	requestDuelRemote = Net.GetRemoteEvent(RemoteNames.RequestDuel)
	respondDuelRemote = Net.GetRemoteEvent(RemoteNames.RespondToDuel)

	Net.GetRemoteEvent(RemoteNames.DuelRequestReceived).OnClientEvent:Connect(function(fromName: string)
		-- The server only ever sends this to the challenged player, and the
		-- toast's Accept/Decline buttons respond generically for whichever
		-- request is currently pending server-side -- no need to round-trip
		-- the challenger's userId back through the toast itself.
		showDuelToast(fromName)
	end)

	Net.GetRemoteEvent(RemoteNames.DuelCancelled).OnClientEvent:Connect(function(otherName: string)
		hideDuelToast()
		showNotice(otherName .. " left the duel.")
	end)

	Players.PlayerAdded:Connect(watchPlayer)
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end
end

return ProfileCardController
