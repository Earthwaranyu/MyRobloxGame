local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Playing with friends is one of the strongest retention/virality levers a
-- multiplayer game has -- see PartyService for the server-side "why". This
-- is just the UI for it: invite other players currently in this server,
-- accept/decline incoming invites, and see your current roster.
local PartyController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()
local inviteList: ScrollingFrame
local rosterLabel: TextLabel
local leaveButton: TextButton

local inviteToast: CanvasGroup
local toastLabel: TextLabel
local toastFromName: string? = nil

-- Separate panel from inviteToast (not a shared/reused one) so an invite and
-- a join request landing at the same moment don't clobber each other's
-- pending-name state; positioned lower on screen so the two never overlap.
local joinRequestToast: CanvasGroup
local joinRequestLabel: TextLabel
local joinRequestFromName: string? = nil

local currentMembers: { string } = {}

local requestInviteRemote: RemoteEvent
local respondRemote: RemoteEvent
local leaveRemote: RemoteEvent
local requestJoinRemote: RemoteEvent
local respondJoinRemote: RemoteEvent

local function buildInviteRow(targetPlayer: Player, layoutOrder: number): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local isFriend = false
	pcall(function()
		isFriend = player:IsFriendsWith(targetPlayer.UserId)
	end)

	local nameLabel = Widgets.Label(
		(isFriend and "★ " or "") .. targetPlayer.Name,
		UDim2.new(1, -110, 1, 0),
		UDim2.fromOffset(12, 0),
		{ TextSize = 15, Color = if isFriend then Theme.Color.Warning else Theme.Color.TextPrimary }
	)
	nameLabel.Parent = row

	local inviteButton = Widgets.Button("Invite", UDim2.fromOffset(84, 32), UDim2.new(1, -92, 0.5, -16), {
		Variant = "Secondary",
		TextSize = 13,
	})
	inviteButton.Parent = row
	inviteButton.MouseButton1Click:Connect(function()
		requestInviteRemote:FireServer(targetPlayer.UserId)
		inviteButton.Text = "Sent!"
		inviteButton.Active = false
	end)

	return row
end

local function refreshInviteList()
	for _, child in inviteList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local memberSet: { [string]: boolean } = {}
	for _, name in currentMembers do
		memberSet[name] = true
	end

	local order = 0
	for _, other in Players:GetPlayers() do
		if other ~= player and not memberSet[other.Name] then
			order += 1
			buildInviteRow(other, order).Parent = inviteList
		end
	end

	if order == 0 then
		local empty = Widgets.Label("No one else to invite right now.", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 0), {
			TextSize = 13,
			Align = Enum.TextXAlignment.Center,
			Color = Theme.Color.TextMuted,
		})
		empty.Parent = inviteList
	end
end

local function refreshRoster()
	if #currentMembers <= 1 then
		rosterLabel.Text = "Playing solo -- invite someone below!"
		leaveButton.Visible = false
	else
		rosterLabel.Text = "YOUR PARTY: " .. table.concat(currentMembers, ", ")
		leaveButton.Visible = true
	end
end

local function hideToast()
	toastFromName = nil
	Widgets.Close(inviteToast)
end

local function showToast(fromName: string)
	toastFromName = fromName
	toastLabel.Text = fromName .. " invited you to a party!"
	Sounds.Play("Reveal")
	Widgets.Open(inviteToast)

	task.delay(12, function()
		if toastFromName == fromName then
			hideToast()
		end
	end)
end

local function hideJoinRequestToast()
	joinRequestFromName = nil
	Widgets.Close(joinRequestToast)
end

local function showJoinRequestToast(fromName: string)
	joinRequestFromName = fromName
	joinRequestLabel.Text = fromName .. " wants to join your party!"
	Sounds.Play("Reveal")
	Widgets.Open(joinRequestToast)

	task.delay(12, function()
		if joinRequestFromName == fromName then
			hideJoinRequestToast()
		end
	end)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PartyGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits directly below EmoteController's toggle button, same X.
	local toggleButton = Widgets.Button("Party", UDim2.fromOffset(140, 48), UDim2.fromOffset(240, 118))
	toggleButton.Parent = screenGui

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	panel, openPanel, closePanel = Widgets.Modal("Party", UDim2.fromOffset(360, 360), UDim2.new(0.5, -180, 0.5, -180), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("PARTY", UDim2.fromOffset(180, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	rosterLabel = Widgets.Label("Playing solo -- invite someone below!", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 34), {
		TextSize = 14,
		Color = Theme.Color.TextSecondary,
	})
	rosterLabel.TextWrapped = true
	rosterLabel.Parent = panel

	leaveButton = Widgets.Button("Leave Party", UDim2.new(1, -16, 0, 36), UDim2.fromOffset(8, 78), {
		Variant = "Danger",
		TextSize = 14,
	})
	leaveButton.Visible = false
	leaveButton.Parent = panel
	leaveButton.MouseButton1Click:Connect(function()
		leaveRemote:FireServer()
	end)

	local inviteHeader = Widgets.Label("INVITE PLAYERS IN THIS SERVER", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 122), {
		TextSize = 13,
		Color = Theme.Color.TextMuted,
	})
	inviteHeader.Parent = panel

	inviteList = Instance.new("ScrollingFrame")
	inviteList.Size = UDim2.new(1, -16, 1, -152)
	inviteList.Position = UDim2.fromOffset(8, 146)
	inviteList.BackgroundTransparency = 1
	inviteList.BorderSizePixel = 0
	inviteList.CanvasSize = UDim2.new(0, 0, 0, 0)
	inviteList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	inviteList.ScrollBarThickness = 6
	inviteList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = inviteList

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			refreshInviteList()
			openPanel()
		end
	end)

	-- Invite toast, separate small popup so it's visible even if the party
	-- panel itself is closed.
	local toastGui = Instance.new("ScreenGui")
	toastGui.Name = "PartyInviteToastGui"
	toastGui.ResetOnSpawn = false
	toastGui.DisplayOrder = 12
	toastGui.Parent = player:WaitForChild("PlayerGui")

	inviteToast = Widgets.Panel(UDim2.fromOffset(360, 130), UDim2.new(0.5, -180, 0.24, 0))
	inviteToast.Parent = toastGui

	toastLabel = Widgets.Label("", UDim2.new(1, -20, 0, 44), UDim2.fromOffset(10, 12), {
		TextSize = 17,
		Align = Enum.TextXAlignment.Center,
	})
	toastLabel.TextWrapped = true
	toastLabel.Parent = inviteToast

	local acceptButton = Widgets.Button("Accept", UDim2.fromOffset(150, 40), UDim2.fromOffset(20, 78), {
		Variant = "Success",
		TextSize = 15,
	})
	acceptButton.Parent = inviteToast
	acceptButton.MouseButton1Click:Connect(function()
		respondRemote:FireServer(true)
		hideToast()
	end)

	local declineButton = Widgets.Button("Decline", UDim2.fromOffset(150, 40), UDim2.fromOffset(190, 78), {
		Variant = "Danger",
		TextSize = 15,
	})
	declineButton.Parent = inviteToast
	declineButton.MouseButton1Click:Connect(function()
		respondRemote:FireServer(false)
		hideToast()
	end)

	-- Join-request toast (profile card's "Request to Join Party"), positioned
	-- well below inviteToast so the two can never overlap if both land at once.
	joinRequestToast = Widgets.Panel(UDim2.fromOffset(360, 130), UDim2.new(0.5, -180, 0.24, 150))
	joinRequestToast.Parent = toastGui

	joinRequestLabel = Widgets.Label("", UDim2.new(1, -20, 0, 44), UDim2.fromOffset(10, 12), {
		TextSize = 17,
		Align = Enum.TextXAlignment.Center,
	})
	joinRequestLabel.TextWrapped = true
	joinRequestLabel.Parent = joinRequestToast

	local joinAcceptButton = Widgets.Button("Accept", UDim2.fromOffset(150, 40), UDim2.fromOffset(20, 78), {
		Variant = "Success",
		TextSize = 15,
	})
	joinAcceptButton.Parent = joinRequestToast
	joinAcceptButton.MouseButton1Click:Connect(function()
		respondJoinRemote:FireServer(true)
		hideJoinRequestToast()
	end)

	local joinDeclineButton = Widgets.Button("Decline", UDim2.fromOffset(150, 40), UDim2.fromOffset(190, 78), {
		Variant = "Danger",
		TextSize = 15,
	})
	joinDeclineButton.Parent = joinRequestToast
	joinDeclineButton.MouseButton1Click:Connect(function()
		respondJoinRemote:FireServer(false)
		hideJoinRequestToast()
	end)
end

function PartyController.Init()
	buildUI()

	requestInviteRemote = Net.GetRemoteEvent(RemoteNames.RequestPartyInvite)
	respondRemote = Net.GetRemoteEvent(RemoteNames.RespondToPartyInvite)
	leaveRemote = Net.GetRemoteEvent(RemoteNames.LeaveParty)
	requestJoinRemote = Net.GetRemoteEvent(RemoteNames.RequestJoinParty)
	respondJoinRemote = Net.GetRemoteEvent(RemoteNames.RespondToJoinRequest)

	Net.GetRemoteEvent(RemoteNames.PartyInviteReceived).OnClientEvent:Connect(showToast)
	Net.GetRemoteEvent(RemoteNames.JoinRequestReceived).OnClientEvent:Connect(showJoinRequestToast)

	Net.GetRemoteEvent(RemoteNames.PartyUpdated).OnClientEvent:Connect(function(names: { string })
		currentMembers = names
		refreshRoster()
		if panel.Visible then
			refreshInviteList()
		end
	end)
end

return PartyController
