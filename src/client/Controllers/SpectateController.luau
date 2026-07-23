local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Shown while state == "Spectating" (see MatchService.PlayerReachedFinish /
-- LeaveSpectate): finishing/losing a race no longer yanks you straight back
-- to the lobby if others are still racing.
--
-- Third person only -- first-person spectate (Scriptable camera snapped to
-- the watched racer's head) was cut. It went through three separate fixes
-- (camera targeting, a stuck-POV regression, then a visibility bug) and each
-- one only surfaced the next failure mode instead of actually landing. It
-- was never the core of this feature; third person + the prev/next arrows is.
--
-- Docked to the right edge below Shop/Gacha, NOT the old centered-at-y=56
-- slot this used to share with RaceHudController's timer panel. That slot
-- only ever worked for RaceHudController's own 240-wide panel -- this one
-- needs to be wider (prev/next arrows + a name) and was never actually
-- resized to match, so on anything but a very wide window it overlapped BOTH
-- the Emotes/Party button column AND QuitMatchController's "Stop Watching"
-- button (which assumes only RaceHudController's narrower panel sits to its
-- left -- see that module's own comment). Moving down here clears the entire
-- top button stack (nothing persistent extends past y=220) without needing
-- every other controller's geometry to line up with this one's width.
local SpectateController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local statusLabel: TextLabel
local nameLabel: TextLabel
local prevButton: TextButton
local nextButton: TextButton

local currentRacers: { Player } = {}
local watchedIndex = 1
local watchedPlayer: Player? = nil

-- Single connection driving the camera for the entire spectating session
-- (started/stopped alongside the "Spectating" state).
local spectateCameraConn: RBXScriptConnection? = nil

local function ownHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Fixed chase-cam offset behind and above the watched racer's own facing
-- direction -- recomputed from scratch every single frame directly off
-- their HumanoidRootPart.CFrame, with NO CameraSubject/CameraMode/Custom
-- camera type involved anywhere in this path.
--
-- This trades away free mouse-orbit/zoom while spectating (Custom mode's
-- own perk) for something more important: certainty about which character
-- is actually being rendered. Every previous version of this feature routed
-- through Roblox's built-in Custom camera (CameraSubject-driven), and across
-- several rounds of testing it kept ending up pointed at the wrong
-- character or visibly stuck despite the underlying CameraSubject/
-- watchedPlayer reference provably being correct -- strong evidence that
-- built-in module was doing something with CameraMode/zoom state that never
-- got fully pinned down. A camera.CFrame computed fresh every frame purely
-- from the target's own position has no other system that can contest it.
local CAMERA_BACK_DISTANCE = 10
local CAMERA_HEIGHT = 4
local CAMERA_LOOK_HEIGHT = 2.5

local function spectateCameraStep()
	local camera = Workspace.CurrentCamera
	local target = watchedPlayer
	if not camera or not target then
		return
	end

	local character = target.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local lookVector = root.CFrame.LookVector
	local cameraPosition = root.Position - lookVector * CAMERA_BACK_DISTANCE + Vector3.new(0, CAMERA_HEIGHT, 0)
	camera.CFrame = CFrame.lookAt(cameraPosition, root.Position + Vector3.new(0, CAMERA_LOOK_HEIGHT, 0))
end

local function startSpectateCamera()
	if not spectateCameraConn then
		spectateCameraConn = RunService.RenderStepped:Connect(spectateCameraStep)
	end
end

local function stopSpectateCamera()
	if spectateCameraConn then
		spectateCameraConn:Disconnect()
		spectateCameraConn = nil
	end
end

local function restoreOwnCamera()
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	player.CameraSubject = ownHumanoid()
end

local function watch(target: Player)
	watchedPlayer = target
	nameLabel.Text = target.Name
end

-- Wraps around both ends (prev from the first racer jumps to the last, and
-- vice versa) so the arrows never dead-end.
local function watchIndex(index: number)
	local count = #currentRacers
	if count == 0 then
		watchedPlayer = nil
		nameLabel.Text = ""
		return
	end
	watchedIndex = ((index - 1) % count) + 1
	watch(currentRacers[watchedIndex])
end

-- With 0-1 racers left there's nothing for prev/next to switch TO, so a
-- click is correctly a no-op -- but with no visual difference from a
-- genuinely broken button, that no-op reads as "this is broken" instead of
-- "there's nothing else to watch right now" (confirmed: exactly what got
-- reported). Dimming them the same way AbilityController dims DASH on
-- cooldown makes the no-op state visually obvious instead of silent.
local ARROW_ENABLED =
	{ Face = Color3.fromRGB(255, 255, 255), Shadow = Color3.fromRGB(205, 205, 220), Text = Color3.fromRGB(24, 24, 28) }
local ARROW_DISABLED =
	{ Face = Theme.Color.PanelLight, Shadow = Color3.fromRGB(20, 21, 30), Text = Theme.Color.TextMuted }

local function updateArrowState()
	local enabled = #currentRacers > 1
	local style = if enabled then ARROW_ENABLED else ARROW_DISABLED
	Widgets.SetButtonColors(prevButton, style.Face, style.Shadow, style.Text)
	Widgets.SetButtonColors(nextButton, style.Face, style.Shadow, style.Text)
end

local function onSpectateStatus(racers: { Player })
	currentRacers = racers
	statusLabel.Text = if #racers == 1 then "1 racer still going" else ("%d racers still going"):format(#racers)
	updateArrowState()

	local stillGoingAt = watchedPlayer and table.find(racers, watchedPlayer)
	if stillGoingAt then
		watchedIndex = stillGoingAt
	elseif racers[1] then
		-- Watched racer finished/quit (or this is the first update) -- fall
		-- back to whoever's first so there's always something to see.
		watchIndex(1)
	else
		watchedPlayer = nil
		nameLabel.Text = ""
	end
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SpectateGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local PANEL_WIDTH = 280
	local ARROW_SIZE = 40

	panel = Widgets.Panel(UDim2.fromOffset(PANEL_WIDTH, 120), UDim2.new(1, -(PANEL_WIDTH + 10), 0, 230))
	panel.Parent = screenGui

	local title = Widgets.Label("SPECTATING", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 8), {
		TextSize = 14,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = panel

	statusLabel = Widgets.Label("Watching the finish...", UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 30), {
		Font = Theme.Font.Heading,
		TextSize = 16,
		Align = Enum.TextXAlignment.Center,
	})
	statusLabel.Parent = panel

	-- Prev/next carousel: cycles through every still-racing player (see the
	-- reference the "Click a name" button-row approach was replaced with),
	-- rather than a row of small per-racer buttons that only worked at all
	-- for a couple of racers before running out of room.
	prevButton = Widgets.Button("", UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE), UDim2.fromOffset(8, 62), {
		Variant = "Secondary",
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "ArrowLeft", color)
		end,
	})
	prevButton.Parent = panel
	prevButton.MouseButton1Click:Connect(function()
		if #currentRacers > 1 then
			watchIndex(watchedIndex - 1)
		end
	end)

	nextButton = Widgets.Button(
		"",
		UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE),
		UDim2.fromOffset(PANEL_WIDTH - 8 - ARROW_SIZE, 62),
		{
			Variant = "Secondary",
			Icon = function(holder, color)
				MenuIcons.Populate(holder, "ArrowRight", color)
			end,
		}
	)
	nextButton.Parent = panel
	nextButton.MouseButton1Click:Connect(function()
		if #currentRacers > 1 then
			watchIndex(watchedIndex + 1)
		end
	end)

	local nameX = 8 + ARROW_SIZE + 6
	nameLabel = Widgets.Label("", UDim2.fromOffset(PANEL_WIDTH - nameX * 2, ARROW_SIZE), UDim2.fromOffset(nameX, 62), {
		TextSize = 16,
		Bold = true,
		Align = Enum.TextXAlignment.Center,
	})
	nameLabel.Parent = panel
end

function SpectateController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Spectating" then
			Widgets.Open(panel)
			startSpectateCamera()
		else
			if panel.Visible then
				Widgets.Close(panel)
			end
			if spectateCameraConn then
				stopSpectateCamera()
				restoreOwnCamera()
			end
			watchedPlayer = nil
			currentRacers = {}
		end
	end)

	Net.GetRemoteEvent(RemoteNames.SpectateStatus).OnClientEvent:Connect(onSpectateStatus)
end

return SpectateController
