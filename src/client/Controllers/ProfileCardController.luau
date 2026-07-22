local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- Hover another player for a white highlight + "double-click for details"
-- hint, then double-click to see their profile (rank, win rate, equipped
-- ability, wins/losses, playtime, best time per stage, request 1v1, request
-- to join party). ClickDetector is created and owned entirely client-side,
-- one per OTHER player's character (see TrailVisualsController for the same
-- watch-every-player CharacterAdded pattern) -- it never needs to replicate,
-- since only the local player's own clicks/hovers on it matter.
local ProfileCardController = {}

local DOUBLE_CLICK_WINDOW = 0.4
-- ClickDetector.MaxActivationDistance only gates MouseClick -- NOT
-- MouseHoverEnter/MouseHoverLeave, which fire regardless of distance. That
-- mismatch is exactly what made the hover highlight/hint show up while
-- double-clicking silently did nothing: standing just past this distance
-- still triggers hover, but the click gets dropped before it ever reaches
-- onClick below. Generous on purpose so normal "standing near someone in the
-- lobby" distances comfortably qualify.
local CLICK_ACTIVATION_DISTANCE = 24
local DUEL_REQUEST_TTL_DISPLAY = 30

local player = Players.LocalPlayer

local getSummaryRemote: RemoteFunction
local getBestTimesRemote: RemoteFunction
local requestJoinRemote: RemoteEvent
local requestDuelRemote: RemoteEvent
local respondDuelRemote: RemoteEvent

local lastClickTime: { [number]: number } = {}

local panel: CanvasGroup
-- Declared here (not down by buildUI, where they're assigned) and NEVER
-- re-declared with `local` again anywhere else in this file -- Lua doesn't
-- hoist locals, so a second `local openPanel`/`local closePanel` further
-- down (where this used to live, right before buildUI) would shadow these
-- from that point on, leaving openProfileCard's call to openPanel() (defined
-- earlier in the file, so it closes over THIS declaration) reading a
-- never-assigned global instead of buildUI's real one. That's exactly what
-- was happening: double-click detection worked, the server call worked, and
-- then openPanel() errored as "attempt to call a nil value".
local openPanel: () -> ()
local closePanel: () -> ()
local avatarImage: ImageLabel
local avatarStroke: UIStroke
local nameLabel: TextLabel
local rankLabel: TextLabel
local statRows: { [string]: TextLabel } = {}
local bestTimesLabel: TextLabel
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

-- Same "M:SS.ss" shape as LeaderboardController's formatTime -- "--" for a
-- stage this player has never actually finished (BestTimes has no entry).
local function formatBestTime(ms: number?): string
	if not ms then
		return "--"
	end
	local totalSeconds = ms / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds - minutes * 60
	return ("%d:%05.2f"):format(minutes, seconds)
end

local function formatPlaytime(totalSeconds: number): string
	local minutes = math.floor(totalSeconds / 60)
	if minutes < 60 then
		return ("%dm"):format(minutes)
	end
	local hours = math.floor(minutes / 60)
	return ("%dh %dm"):format(hours, minutes % 60)
end

-- Roblox's own CDN thumbnail for this userId -- yields, so this has to run
-- off to the side rather than blocking openProfileCard. Guards against a
-- slow-resolving fetch from a PREVIOUS double-click landing after the viewer
-- has already moved on to someone else (same stale-callback shape as
-- duelToastToken/noticeToken below, just keyed on the target instead).
local function loadAvatarThumbnail(userId: number)
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and currentTarget and currentTarget.UserId == userId then
			avatarImage.Image = content
		end
	end)
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

-- Fetched separately from the rest of the card (see getBestTimesRemote's
-- server-side comment) so it can pop in a beat after the panel's already
-- open instead of stalling it. Guards against a slow-resolving fetch from a
-- PREVIOUS double-click landing after the viewer has already moved on to
-- someone else -- same stale-callback shape as loadAvatarThumbnail.
local function loadBestTimes(userId: number)
	bestTimesLabel.Text = "Loading..."
	task.spawn(function()
		local ok, bestTimes = pcall(function()
			return getBestTimesRemote:InvokeServer(userId)
		end)
		if not ok or not currentTarget or currentTarget.UserId ~= userId then
			return
		end

		-- Two stages per line -- BestTimes may come back empty (see
		-- LeaderboardService's BEST_TIMES_COOLDOWN) if this viewer already
		-- checked someone very recently; formatBestTime renders a missing
		-- entry as "--" either way, so this never shows a blank or an error.
		local bestTimeLines = {}
		for i = 1, #Stages, 2 do
			local a, b = Stages[i], Stages[i + 1]
			local line = ("%s: %s"):format(a.Name, formatBestTime(bestTimes and bestTimes[a.Id]))
			if b then
				line ..= ("    %s: %s"):format(b.Name, formatBestTime(bestTimes and bestTimes[b.Id]))
			end
			table.insert(bestTimeLines, line)
		end
		bestTimesLabel.Text = table.concat(bestTimeLines, "\n")
	end)
end

local function openProfileCard(target: Player)
	local summary = getSummaryRemote:InvokeServer(target.UserId)
	if not summary then
		-- Double-click WAS detected (we got this far) but the server had
		-- nothing to show -- most likely target's profile hadn't finished
		-- loading yet. Warn rather than fail silently, so "double-click does
		-- nothing" is distinguishable from "the click never registered at all".
		warn(("ProfileCardController: no summary returned for %s (%d)"):format(target.Name, target.UserId))
		return
	end

	currentTarget = target

	nameLabel.Text = summary.Name
	rankLabel.Text = summary.Rank .. "  ·  " .. summary.Elo .. " elo"
	local rankColor = Theme.GetRankColor(summary.Rank)
	rankLabel.TextColor3 = rankColor
	avatarStroke.Color = rankColor
	avatarImage.Image = "" -- cleared until loadAvatarThumbnail resolves, rather than showing the last target's face
	loadAvatarThumbnail(target.UserId)

	local winRatePercent = math.floor(summary.WinRate * 100 + 0.5)
	statRows.Wins.Text = ("Wins: %d"):format(summary.Wins)
	statRows.Losses.Text = ("Losses: %d"):format(summary.Losses)
	statRows.WinRate.Text = ("Win Rate: %d%%"):format(winRatePercent)
	statRows.Ability.Text = ("Ability: %s"):format(summary.EquippedAbility)
	statRows.Playtime.Text = ("Playtime: %s"):format(formatPlaytime(summary.PlaytimeSeconds))

	Sounds.Play("Reveal")
	openPanel()

	loadBestTimes(target.UserId)
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

local STAT_ROW_HEIGHT = 32
local STAT_ROW_ICON_SIZE = 22
local STAT_ROW_PAD = 8

-- One icon + label row (Wins/Losses/Win Rate/Ability/Playtime), drawn as a
-- subtle rounded "chip" (own tinted background, not just bare text on the
-- panel) so the stat block reads as a grid of cards instead of a loose list.
-- x/width are passed in per-call so the same builder serves both the
-- two-column rows and the full-width Ability row -- built once per row in
-- buildUI, returns the label so openProfileCard can just set .Text on the
-- same 5 instances each open, same "build once, mutate on open" shape
-- nameLabel/rankLabel already used.
local function buildStatRow(parent: Instance, iconId: string, x: number, y: number, width: number): TextLabel
	local row = Instance.new("Frame")
	row.Size = UDim2.fromOffset(width, STAT_ROW_HEIGHT)
	row.Position = UDim2.fromOffset(x, y)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BackgroundTransparency = 0.4
	row.BorderSizePixel = 0
	row.Parent = parent

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 8)
	rowCorner.Parent = row

	local iconHolder = Instance.new("Frame")
	iconHolder.Size = UDim2.fromOffset(STAT_ROW_ICON_SIZE, STAT_ROW_ICON_SIZE)
	iconHolder.Position = UDim2.new(0, STAT_ROW_PAD, 0.5, -STAT_ROW_ICON_SIZE / 2)
	iconHolder.BackgroundTransparency = 1
	iconHolder.Parent = row
	MenuIcons.Populate(iconHolder, iconId, Theme.Color.TextSecondary)

	local labelX = STAT_ROW_PAD + STAT_ROW_ICON_SIZE + 6
	local label = Widgets.Label("", UDim2.new(1, -labelX - STAT_ROW_PAD, 1, 0), UDim2.fromOffset(labelX, 0), {
		TextSize = 14,
		Bold = false,
	})
	label.Parent = row
	return label
end

local function buildUI()
	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) -- this panel
	-- has no persistent toggle button (it only opens from a double-click),
	-- so click-outside/✕ are the ONLY way to dismiss it besides its own
	-- buttons, which makes them non-optional here, not just a nicety.
	--
	-- 400x480, identity block centered (was 440x410 with the avatar/name
	-- pinned to the right of a narrower left-aligned stat column): centering
	-- the avatar/name/rank on their own row lets the stats below use the
	-- panel's FULL width as a symmetric 2-column grid instead of leaving the
	-- right half mostly empty, and every section now shares the same 16px
	-- side margin (buttons used to sit on an 8px margin while everything
	-- else used 16px).
	local PANEL_WIDTH = 400
	local PANEL_HEIGHT = 480
	local PAD_X = 16
	local CONTENT_WIDTH = PANEL_WIDTH - PAD_X * 2

	panel, openPanel, closePanel = Widgets.Modal(
		"ProfileCard",
		UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2),
		{ DisplayOrder = 30 }
	)

	local ribbon = Widgets.Ribbon("PROFILE", UDim2.fromOffset(200, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	-- Avatar thumbnail, centered at the top -- Roblox's own CDN headshot for
	-- whoever was double-clicked (see loadAvatarThumbnail), bordered in their
	-- rank color the same way rankLabel's text is. Fully round (radius = 1
	-- scale, was a squircle) reads more like a classic profile picture.
	local AVATAR_SIZE = 80
	local avatarY = 24
	avatarImage = Instance.new("ImageLabel")
	avatarImage.Name = "AvatarImage"
	avatarImage.Size = UDim2.fromOffset(AVATAR_SIZE, AVATAR_SIZE)
	avatarImage.Position = UDim2.fromOffset((PANEL_WIDTH - AVATAR_SIZE) / 2, avatarY)
	avatarImage.BackgroundColor3 = Theme.Color.PanelLight
	avatarImage.BorderSizePixel = 0
	avatarImage.Image = ""
	avatarImage.Parent = panel

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatarImage

	avatarStroke = Instance.new("UIStroke")
	avatarStroke.Thickness = 3
	avatarStroke.Color = Theme.Color.Stroke
	avatarStroke.Parent = avatarImage

	nameLabel = Widgets.Label("", UDim2.fromOffset(300, 22), UDim2.fromOffset((PANEL_WIDTH - 300) / 2, avatarY + AVATAR_SIZE + 6), {
		TextSize = 16,
		Align = Enum.TextXAlignment.Center,
		Bold = true,
	})
	nameLabel.Parent = panel

	rankLabel = Widgets.Label("", UDim2.fromOffset(300, 16), UDim2.fromOffset((PANEL_WIDTH - 300) / 2, avatarY + AVATAR_SIZE + 28), {
		TextSize = 12,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextSecondary,
	})
	rankLabel.Parent = panel

	-- Thin divider separating "who this is" from "their stats" -- purely
	-- decorative, but it's what keeps the identity block and the stat grid
	-- reading as two distinct groups instead of one undifferentiated stack.
	local dividerY = avatarY + AVATAR_SIZE + 50
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.fromOffset(CONTENT_WIDTH, 2)
	divider.Position = UDim2.fromOffset(PAD_X, dividerY)
	divider.BackgroundColor3 = Theme.Color.Stroke
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel = 0
	divider.Parent = panel

	local dividerCorner = Instance.new("UICorner")
	dividerCorner.CornerRadius = UDim.new(1, 0)
	dividerCorner.Parent = divider

	-- Stat grid: two columns of chips (Wins/Losses, then Win Rate/Playtime),
	-- then Ability alone on a full-width row -- ability names run longer
	-- than the other values and would be the one row likely to truncate if
	-- squeezed into half the width like the rest.
	local colGap = 12
	local colWidth = (CONTENT_WIDTH - colGap) / 2
	local col2X = PAD_X + colWidth + colGap
	local rowGap = 8

	local row1Y = dividerY + 14
	statRows.Wins = buildStatRow(panel, "Wins", PAD_X, row1Y, colWidth)
	statRows.Losses = buildStatRow(panel, "Losses", col2X, row1Y, colWidth)

	local row2Y = row1Y + STAT_ROW_HEIGHT + rowGap
	statRows.WinRate = buildStatRow(panel, "Practice", PAD_X, row2Y, colWidth) -- bullseye glyph reused for win-rate/accuracy
	statRows.Playtime = buildStatRow(panel, "Playtime", col2X, row2Y, colWidth)

	local row3Y = row2Y + STAT_ROW_HEIGHT + rowGap
	statRows.Ability = buildStatRow(panel, "Ability", PAD_X, row3Y, CONTENT_WIDTH)

	local bestTimesY = row3Y + STAT_ROW_HEIGHT + 12
	local bestTimesFrame = Instance.new("Frame")
	bestTimesFrame.Name = "BestTimesFrame"
	bestTimesFrame.Size = UDim2.fromOffset(CONTENT_WIDTH, 72)
	bestTimesFrame.Position = UDim2.fromOffset(PAD_X, bestTimesY)
	bestTimesFrame.BackgroundColor3 = Theme.Color.Panel
	bestTimesFrame.BorderSizePixel = 0
	bestTimesFrame.Parent = panel

	local bestTimesCorner = Instance.new("UICorner")
	bestTimesCorner.CornerRadius = UDim.new(0, 10)
	bestTimesCorner.Parent = bestTimesFrame

	local bestTimesHeader = Widgets.Label("BEST TIMES", UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 6), {
		TextSize = 12,
		Color = Theme.Color.TextMuted,
	})
	bestTimesHeader.Parent = bestTimesFrame

	bestTimesLabel = Widgets.Label("", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 26), {
		TextSize = 14,
		Color = Theme.Color.TextPrimary,
		Bold = false,
	})
	bestTimesLabel.TextWrapped = true
	bestTimesLabel.Parent = bestTimesFrame

	local duelY = bestTimesY + 72 + 12
	duelButton = Widgets.Button("Request 1v1", UDim2.fromOffset(CONTENT_WIDTH, 40), UDim2.fromOffset(PAD_X, duelY), {
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

	local joinY = duelY + 40 + 8
	joinPartyButton = Widgets.Button("Ask to Join Party", UDim2.fromOffset(CONTENT_WIDTH, 40), UDim2.fromOffset(PAD_X, joinY), {
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

-- Built once per character and just toggled Enabled on hover, rather than
-- created/destroyed on every enter/leave -- same "build once, mutate on
-- state change" shape the rest of this controller already uses for the duel/
-- notice toasts.
local function buildHoverHint(head: BasePart): BillboardGui
	-- OverheadDisplayService's rank tag sits at 2.6, EmoteDisplayController's
	-- emote bubble at 4.9 -- 3.5 sits clear of both with room to spare.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ProfileHoverHint"
	billboard.Size = UDim2.fromOffset(168, 30)
	billboard.StudsOffset = Vector3.new(0, 3.5, 0)
	billboard.MaxDistance = CLICK_ACTIVATION_DISTANCE + 8
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = head

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(15, 16, 22)
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = backdrop

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.9, 0.8)
	label.Position = UDim2.fromScale(0.05, 0.1)
	label.BackgroundTransparency = 1
	label.Text = "Double-click for details"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = backdrop

	return billboard
end

local function watchCharacter(target: Player, character: Model)
	if not character:WaitForChild("HumanoidRootPart", 5) then
		return
	end
	local head = character:WaitForChild("Head", 5) :: BasePart?

	-- White highlight + "double-click for details" hint while the mouse is
	-- over this player -- purely a local visual cue pointing at the
	-- click-to-open-profile-card interaction below, no server round trip.
	local highlight = Instance.new("Highlight")
	highlight.Name = "ProfileHoverHighlight"
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0
	highlight.Enabled = false
	highlight.Parent = character

	local hint = head and buildHoverHint(head)

	local function onHoverEnter()
		highlight.Enabled = true
		if hint then
			hint.Enabled = true
		end
	end

	local function onHoverLeave()
		highlight.Enabled = false
		if hint then
			hint.Enabled = false
		end
	end

	local function onClick()
		local now = os.clock()
		local last = lastClickTime[target.UserId]
		lastClickTime[target.UserId] = now
		if last and now - last <= DOUBLE_CLICK_WINDOW then
			lastClickTime[target.UserId] = nil
			-- Positive confirmation the click side of the pipeline actually
			-- fired -- if the card still doesn't open, check the dev console
			-- (F9) for this: no line at all means the click itself never
			-- registered (distance/detector issue); this line but no panel
			-- means it got as far as the server request (see openProfileCard's
			-- own warn for that half).
			print("ProfileCardController: double-click detected on " .. target.Name)
			openProfileCard(target)
		end
	end

	local function attachClickDetector(part: BasePart)
		if part:FindFirstChildOfClass("ClickDetector") then
			return
		end
		local clickDetector = Instance.new("ClickDetector")
		clickDetector.Name = "ProfileCardClickDetector"
		clickDetector.MaxActivationDistance = CLICK_ACTIVATION_DISTANCE
		clickDetector.Parent = part

		clickDetector.MouseHoverEnter:Connect(onHoverEnter)
		clickDetector.MouseHoverLeave:Connect(onHoverLeave)
		clickDetector.MouseClick:Connect(onClick)
	end

	-- One ClickDetector per visible BasePart, not just HumanoidRootPart --
	-- the root part is invisible and sits behind/inside the actual visible
	-- geometry, so a raycast at whatever you actually see almost always hits
	-- THAT part first. GetDescendants (not GetChildren) because avatar
	-- accessories/costumes (hats, hair, a full-body "Generated Accessory"
	-- skin -- confirmed via a live character's structure: those are Accessory
	-- instances with the actual visible mesh one level down, in a nested
	-- Handle part) live one level deeper than the body's own BaseParts, and a
	-- shallow scan silently misses every one of them. DescendantAdded covers
	-- any accessory that streams in slightly after the character does.
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			attachClickDetector(part)
		end
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			attachClickDetector(descendant)
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
	getBestTimesRemote = Net.GetRemoteFunction(RemoteNames.GetPlayerBestTimes)
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
