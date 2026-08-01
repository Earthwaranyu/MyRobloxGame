local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local RaceVisibilityController = require(script.Parent.RaceVisibilityController)

local AvatarThumbnail = require(script.Parent.Parent.AvatarThumbnail)
local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Responsive = require(script.Parent.Parent.Responsive)
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
local avatarFallbackIcon: Frame
local avatarStroke: UIStroke
local nameLabel: TextLabel
local rankLabel: TextLabel
local statRows: { [string]: TextLabel } = {}
local bestTimesLabels: { TextLabel } = {}
local duelButton: TextButton
local joinPartyButton: TextButton
local friendButton: TextButton
-- duelButton/joinPartyButton are fixed, reused instances (the card is
-- rebuilt in place for whoever was last double-clicked, not recreated per
-- open) -- their click handlers are wired ONCE in buildUI and read this
-- upvalue, rather than each openProfileCard call layering on another
-- one-shot closure (which would leak a stale listener per open targeting
-- the wrong player if the buttons were never clicked in between).
local currentTarget: Player? = nil
-- Shown instead of duelButton/joinPartyButton when the local player opened
-- their OWN profile (via the new "My Profile" HUD button below) -- dueling
-- or party-requesting yourself isn't a real action, so the buttons are
-- swapped out rather than left visible-but-nonfunctional.
local selfNoteLabel: TextLabel

local duelToast: CanvasGroup
local duelToastLabel: TextLabel

-- Duel toast reference geometry. TOAST_DROP is only the initial build value --
-- layoutToast positions the toast from the BOTTOM of the viewport, which is what
-- stopped it landing off-screen on a phone.
local TOAST_WIDTH, TOAST_HEIGHT = 360, 130
local TOAST_DROP = 300
local TOAST_PAD = 10
local TOAST_LABEL_HEIGHT, TOAST_TEXT = 44, 17
local TOAST_BUTTON_WIDTH, TOAST_BUTTON_HEIGHT, TOAST_BUTTON_TOP = 150, 40, 78
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

-- Roblox's own CDN headshot for this userId -- a real 3D render Roblox
-- generates server-side of the player's actual equipped avatar (hats/hair/
-- costume included), so it already looks like a proper profile picture
-- (matches the reference image exactly) with zero camera-framing code on our
-- end. The fetch/retry/never-renders handling lives in AvatarThumbnail, which
-- the in-race progress bar shares.
local function loadAvatarThumbnail(userId: number)
	-- AvatarThumbnail only ever calls back with a confirmed-ready photo, so
	-- the fallback icon simply stays up in every other case (still loading,
	-- or an account whose thumbnail will never render at all).
	AvatarThumbnail.Load(userId, function(content: string)
		-- The card may have been re-pointed at somebody else while this was
		-- in flight -- don't paint one player's face onto another's card.
		if not currentTarget or currentTarget.UserId ~= userId then
			return
		end
		avatarImage.Image = content
		avatarFallbackIcon.Visible = false
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
	for i, label in bestTimesLabels do
		label.Text = if i == 1 then "Loading..." else ""
	end
	task.spawn(function()
		local ok, bestTimes = pcall(function()
			return getBestTimesRemote:InvokeServer(userId)
		end)
		if not ok or not currentTarget or currentTarget.UserId ~= userId then
			return
		end

		-- One row per stage (was two stages packed onto each line, which
		-- only reads well up to 2-3 stages before it turns into a cramped
		-- grid) -- bestTimesLabels was built 1:1 against Stages in buildUI,
		-- so this always covers exactly as many rows as exist. BestTimes may
		-- come back empty (see LeaderboardService's BEST_TIMES_COOLDOWN) if
		-- this viewer already checked someone very recently; formatBestTime
		-- renders a missing entry as "--" either way, so this never shows a
		-- blank or an error.
		for i, stage in Stages do
			bestTimesLabels[i].Text = ("%s: %s"):format(stage.Name, formatBestTime(bestTimes and bestTimes[stage.Id]))
		end
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

	-- Duelling, party-requesting or friending yourself isn't a real action, so
	-- those three buttons are swapped for a small note whenever this is the
	-- local player's own profile (opened via the "My Profile" HUD button)
	-- rather than someone else's (opened via double-click).
	local isSelf = target == player
	duelButton.Visible = not isSelf
	joinPartyButton.Visible = not isSelf
	friendButton.Visible = not isSelf
	selfNoteLabel.Visible = isSelf

	nameLabel.Text = summary.Name
	rankLabel.Text = summary.Rank .. "  ·  " .. summary.Elo .. " elo"
	local rankColor = Theme.GetRankColor(summary.Rank)
	rankLabel.TextColor3 = rankColor
	avatarStroke.Color = rankColor
	avatarImage.Image = "" -- cleared until loadAvatarThumbnail resolves, rather than showing the last target's face
	avatarFallbackIcon.Visible = true -- shown until loadAvatarThumbnail confirms a real photo is ready
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
	-- 400 wide, height computed below (was 440x410 with the avatar/name
	-- pinned to the right of a narrower left-aligned stat column): centering
	-- the avatar/name/rank on their own row lets the stats below use the
	-- panel's FULL width as a symmetric 2-column grid instead of leaving the
	-- right half mostly empty, and every section now shares the same 16px
	-- side margin (buttons used to sit on an 8px margin while everything
	-- else used 16px).
	-- All geometry is computed up front, top to bottom, BEFORE Widgets.Modal
	-- is called, because the Best Times section's height now depends on
	-- #Stages (one row per stage instead of a fixed two-line block) -- the
	-- panel's total height has to be known at Modal-creation time, so
	-- everything below it (buttons) shifts automatically if a stage is added
	-- or removed later instead of needing its offsets hand-adjusted again.
	local PANEL_WIDTH = 400
	local PAD_X = 16
	local CONTENT_WIDTH = PANEL_WIDTH - PAD_X * 2

	local AVATAR_SIZE = 80
	local avatarY = 24
	local nameY = avatarY + AVATAR_SIZE + 6
	local rankY = avatarY + AVATAR_SIZE + 28

	-- Thin divider separating "who this is" from "their stats" -- purely
	-- decorative, but it's what keeps the identity block and the stat grid
	-- reading as two distinct groups instead of one undifferentiated stack.
	local dividerY = avatarY + AVATAR_SIZE + 50

	-- Stat grid: two columns of chips (Wins/Losses, then Win Rate/Playtime),
	-- then Ability alone on a full-width row -- ability names run longer
	-- than the other values and would be the one row likely to truncate if
	-- squeezed into half the width like the rest.
	local colGap = 12
	local colWidth = (CONTENT_WIDTH - colGap) / 2
	local col2X = PAD_X + colWidth + colGap
	local rowGap = 8

	local row1Y = dividerY + 14
	local row2Y = row1Y + STAT_ROW_HEIGHT + rowGap
	local row3Y = row2Y + STAT_ROW_HEIGHT + rowGap

	-- Best Times: one row per stage, in as many columns as it takes to keep
	-- the section (and therefore the whole panel) a sane height.
	--
	-- One row per stage was the fix for two stages sharing a single multi-line
	-- label, and it reads well -- but it grows the panel by 20px per stage,
	-- and at 8 stages that is a 646px-tall card that runs off the bottom of a
	-- phone screen. Columns cap the growth instead: the section stays 5 rows
	-- tall at most, and stage 6 starts a second column rather than a sixth
	-- row. Up to 5 stages this is byte-for-byte the old single-column layout.
	local BEST_TIME_HEADER_H = 22
	local BEST_TIME_ROW_H = 20
	local BEST_TIME_BOTTOM_PAD = 8
	local BEST_TIME_MAX_ROWS = 5
	local BEST_TIME_COL_GAP = 10
	local bestTimeColumns = math.ceil(#Stages / BEST_TIME_MAX_ROWS)
	local bestTimeRows = math.ceil(#Stages / bestTimeColumns)
	local bestTimeColWidth = (CONTENT_WIDTH - 16 - BEST_TIME_COL_GAP * (bestTimeColumns - 1)) / bestTimeColumns
	local bestTimesY = row3Y + STAT_ROW_HEIGHT + 12
	local bestTimesFrameHeight = BEST_TIME_HEADER_H + (bestTimeRows * BEST_TIME_ROW_H) + BEST_TIME_BOTTOM_PAD

	local duelY = bestTimesY + bestTimesFrameHeight + 12
	local joinY = duelY + 40 + 8
	local friendY = joinY + 40 + 8
	local PANEL_HEIGHT = friendY + 40 + PAD_X

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

	-- Deliberate placeholder for whenever there's genuinely no real photo to
	-- show (see loadAvatarThumbnail) -- a child of avatarImage so it always
	-- renders on top of whatever avatarImage.Image is doing underneath
	-- (loaded/unloaded/permanently-broken all look the same from here: just
	-- hide this once a real photo is confirmed ready). Reuses the same
	-- "Profile" glyph as the My Profile HUD button for visual consistency.
	avatarFallbackIcon = Instance.new("Frame")
	avatarFallbackIcon.Name = "AvatarFallbackIcon"
	avatarFallbackIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	avatarFallbackIcon.Position = UDim2.fromScale(0.5, 0.5)
	avatarFallbackIcon.Size = UDim2.fromOffset(AVATAR_SIZE * 0.6, AVATAR_SIZE * 0.6)
	avatarFallbackIcon.BackgroundTransparency = 1
	avatarFallbackIcon.Parent = avatarImage
	MenuIcons.Populate(avatarFallbackIcon, "Profile", Theme.Color.TextSecondary)

	nameLabel = Widgets.Label("", UDim2.fromOffset(300, 22), UDim2.fromOffset((PANEL_WIDTH - 300) / 2, nameY), {
		TextSize = 16,
		Align = Enum.TextXAlignment.Center,
		Bold = true,
	})
	nameLabel.Parent = panel

	rankLabel = Widgets.Label("", UDim2.fromOffset(300, 16), UDim2.fromOffset((PANEL_WIDTH - 300) / 2, rankY), {
		TextSize = 12,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextSecondary,
	})
	rankLabel.Parent = panel

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

	statRows.Wins = buildStatRow(panel, "Wins", PAD_X, row1Y, colWidth)
	statRows.Losses = buildStatRow(panel, "Losses", col2X, row1Y, colWidth)

	statRows.WinRate = buildStatRow(panel, "Practice", PAD_X, row2Y, colWidth) -- bullseye glyph reused for win-rate/accuracy
	statRows.Playtime = buildStatRow(panel, "Playtime", col2X, row2Y, colWidth)

	statRows.Ability = buildStatRow(panel, "Ability", PAD_X, row3Y, CONTENT_WIDTH)

	local bestTimesFrame = Instance.new("Frame")
	bestTimesFrame.Name = "BestTimesFrame"
	bestTimesFrame.Size = UDim2.fromOffset(CONTENT_WIDTH, bestTimesFrameHeight)
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

	-- One label per stage (was one shared multi-line label pairing two
	-- stages per line) -- built straight from Stages so the count always
	-- matches however many stages currently exist. Filled column-major, so
	-- reading down the left column and then the right gives stage order.
	bestTimesLabels = {}
	for i, stage in Stages do
		local column = math.floor((i - 1) / bestTimeRows)
		local row = (i - 1) % bestTimeRows
		local label = Widgets.Label(
			("%s: --"):format(stage.Name),
			UDim2.fromOffset(bestTimeColWidth, BEST_TIME_ROW_H),
			UDim2.fromOffset(
				8 + column * (bestTimeColWidth + BEST_TIME_COL_GAP),
				BEST_TIME_HEADER_H + row * BEST_TIME_ROW_H
			),
			{
				TextSize = 14,
				Color = Theme.Color.TextPrimary,
				Bold = false,
				Align = Enum.TextXAlignment.Left,
			}
		)
		label.Parent = bestTimesFrame
		bestTimesLabels[i] = label
	end

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

	-- Replaces the "Add Friend" the Roblox avatar context menu used to offer.
	-- That menu opened on the SAME double-click as this card and landed on top
	-- of it (see Init's AvatarContextMenuEnabled), so the two were competing
	-- for one gesture; disabling it there means the one action worth keeping
	-- has to live here instead.
	--
	-- Player:RequestFriendship is the local player asking, so it's called on
	-- the TARGET from the client -- no remote, and nothing the server needs to
	-- vouch for. It does nothing between Studio's simulated test accounts, so
	-- this button only really answers in a live session.
	friendButton = Widgets.Button("Add Friend", UDim2.fromOffset(CONTENT_WIDTH, 40), UDim2.fromOffset(PAD_X, friendY), {
		Variant = "Secondary",
		TextSize = 15,
	})
	friendButton.Parent = panel
	friendButton.MouseButton1Click:Connect(function()
		if not currentTarget then
			return
		end
		local ok = pcall(function()
			currentTarget:RequestFriendship()
		end)
		showNotice(if ok
			then "Friend request sent to " .. currentTarget.Name .. "!"
			else "Couldn't send a friend request right now.")
		closePanel()
	end)

	-- Same slot as duelButton/joinPartyButton/friendButton -- swapped in over
	-- all three (see openProfileCard's isSelf check) when viewing your own
	-- profile.
	selfNoteLabel = Widgets.Label("This is your profile", UDim2.fromOffset(CONTENT_WIDTH, friendY + 40 - duelY), UDim2.fromOffset(PAD_X, duelY), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextMuted,
	})
	selfNoteLabel.Visible = false
	selfNoteLabel.Parent = panel

	-- Persistent HUD button, own ScreenGui like the duel/notice toasts below --
	-- opens this same panel populated with the LOCAL player's own data
	-- (openProfileCard doesn't care who the target is, and watchPlayer's
	-- double-click path already skips the local player, so this button is
	-- the only way to reach your own profile). Row 3 of the left button
	-- column, directly below Leaderboard (y=60) and Inventory (y=116).
	local hudGui = Instance.new("ScreenGui")
	hudGui.Name = "MyProfileGui"
	hudGui.ResetOnSpawn = false
	hudGui.Parent = player:WaitForChild("PlayerGui")

	local myProfileButton = Widgets.Button("My Profile", UDim2.fromOffset(220, 48), UDim2.fromOffset(10, 172), {
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Profile", color)
		end,
	})
	myProfileButton.Parent = hudGui
	myProfileButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			openProfileCard(player)
		end
	end)

	-- Incoming duel challenge toast, separate GUI/panel from the profile card
	-- itself so it can pop up regardless of whether a card is currently open.
	local toastGui = Instance.new("ScreenGui")
	toastGui.Name = "DuelToastGui"
	toastGui.ResetOnSpawn = false
	toastGui.DisplayOrder = 12
	toastGui.Parent = player:WaitForChild("PlayerGui")

	duelToast = Widgets.Panel(
		UDim2.fromOffset(TOAST_WIDTH, TOAST_HEIGHT),
		UDim2.new(0.5, -TOAST_WIDTH / 2, 0.24, TOAST_DROP)
	)
	duelToast.Parent = toastGui

	duelToastLabel = Widgets.Label("", UDim2.new(1, -TOAST_PAD * 2, 0, TOAST_LABEL_HEIGHT), UDim2.fromOffset(TOAST_PAD, 12), {
		TextSize = TOAST_TEXT,
		Align = Enum.TextXAlignment.Center,
	})
	duelToastLabel.TextWrapped = true
	duelToastLabel.Parent = duelToast

	local acceptButton = Widgets.Button(
		"Accept",
		UDim2.fromOffset(TOAST_BUTTON_WIDTH, TOAST_BUTTON_HEIGHT),
		UDim2.fromOffset(20, TOAST_BUTTON_TOP),
		{ Variant = "Success", TextSize = 15 }
	)
	acceptButton.Parent = duelToast
	acceptButton.MouseButton1Click:Connect(function()
		respondDuelRemote:FireServer(true)
		hideDuelToast()
	end)

	local declineButton = Widgets.Button(
		"Decline",
		UDim2.fromOffset(TOAST_BUTTON_WIDTH, TOAST_BUTTON_HEIGHT),
		UDim2.fromOffset(190, TOAST_BUTTON_TOP),
		{ Variant = "Danger", TextSize = 15 }
	)
	declineButton.Parent = duelToast
	declineButton.MouseButton1Click:Connect(function()
		respondDuelRemote:FireServer(false)
		hideDuelToast()
	end)

	-- Was parked at `0.24 scale + 300 offset`, which resolves to y = 390 on a
	-- 375pt phone -- entirely below the viewport, and Widgets.Open only fades, it
	-- never moves a panel. An incoming 1v1 challenge simply could not be accepted
	-- or declined. Widgets.LayoutToast now owns the placement for all three of
	-- these toasts; StackIndex 0 puts this one nearest the bottom, which is where
	-- it sat relative to the party toasts before.
	Responsive.Observe(function()
		Widgets.LayoutToast({
			Toast = duelToast,
			Label = duelToastLabel,
			Accept = acceptButton,
			Decline = declineButton,
			StackIndex = 0,
		})
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

	-- Suppressed for the whole time you're committed to a race -- from the
	-- teleport to the start line through to crossing the finish -- not just
	-- while the clock is running.
	--
	-- Enforced HERE, on the detector's own callbacks, rather than by making the
	-- character unqueryable: a ClickDetector's MouseClick fires regardless of
	-- CanQuery, so the parts can be invisible to every spatial query and still
	-- open this card. The start grid was the visible symptom -- a third-person
	-- wait with a free mouse, next to racers you may not even be racing.
	local function suppressed(): boolean
		return RaceVisibilityController.IsInRace()
	end

	local function onHoverEnter()
		if suppressed() then
			return
		end
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
		if suppressed() then
			return
		end
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

	-- Roblox's avatar context menu opens on the same double-click as this card,
	-- so both appeared at once and the grey native menu landed squarely on top
	-- of the profile -- two panels competing for one gesture, with the smaller
	-- one covering the stats the player actually double-clicked to read.
	--
	-- Turned off for the whole session rather than only during races (which is
	-- where this started, as an anti-peeking measure) because the conflict is
	-- not race-specific: it was always the wrong second panel. Of what it
	-- offered, Add Friend now lives on the card; View duplicates the avatar
	-- already shown at the top of it, and Wave duplicates the emote wheel.
	--
	-- Retried on a short loop because SetCore silently does nothing if CoreGui
	-- hasn't registered the callback yet, which is common on the first frames
	-- of a session -- exactly when a controller's Init runs.
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCore("AvatarContextMenuEnabled", false)
			end)
			if ok then
				break
			end
			task.wait(0.5)
		end
	end)

	-- Already-open cards don't survive the teleport to the start line. Blocking
	-- new opens isn't enough on its own: a card opened a moment before the
	-- countdown would otherwise sit on screen over the start grid.
	Net.GetRemoteEvent(RemoteNames.PreRaceCountdown).OnClientEvent:Connect(function()
		closePanel()
	end)

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
