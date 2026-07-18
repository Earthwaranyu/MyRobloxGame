local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)
local MatchStateController = require(script.Parent.MatchStateController)
local PlayButtonController = require(script.Parent.PlayButtonController)

-- Practice mode's whole point beyond "solo, no stakes" is this: race your
-- own best recorded run. Both recording and playback are entirely
-- client-side and purely cosmetic (no collision, doesn't touch anti-cheat or
-- scoring) -- the server only ever stores/returns the raw position array
-- (see GhostService), it has no opinion about how it's rendered.
local GhostController = {}

local SAMPLE_INTERVAL = Constants.Ghost.SampleIntervalSeconds
local ROOT_HALF_HEIGHT = 1.2

local player = Players.LocalPlayer

local currentStageId: string? = nil
local recording = false
local recordedPositions: { number } = {}
local raceStartTime = 0

local ghostModel: Model? = nil
local ghostRoot: BasePart? = nil
local ghostHead: BasePart? = nil
local ghostConnection: RBXScriptConnection? = nil
local ghostData: { Positions: { number }, TimeMs: number, SampleInterval: number }? = nil

local panel: CanvasGroup
local detailLabel: TextLabel

local function buildGhostModel(): (Model, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = "GhostRunner"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(2, 2.4, 1)
	root.Material = Enum.Material.ForceField
	root.Color = Color3.fromRGB(200, 140, 255)
	root.Transparency = 0.55
	root.CanCollide = false
	root.Anchored = true
	root.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.3, 1.3, 1.3)
	head.Material = Enum.Material.ForceField
	head.Color = Color3.fromRGB(220, 180, 255)
	head.Transparency = 0.5
	head.CanCollide = false
	head.Anchored = true
	head.Parent = model

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(200, 140, 255)
	light.Range = 10
	light.Brightness = 1.5
	light.Parent = root

	local nameTag = Instance.new("BillboardGui")
	nameTag.Name = "GhostLabel"
	nameTag.Size = UDim2.fromOffset(130, 26)
	nameTag.StudsOffset = Vector3.new(0, 1.3, 0)
	nameTag.AlwaysOnTop = true
	nameTag.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "GHOST (your best)"
	label.TextColor3 = Color3.fromRGB(220, 180, 255)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = nameTag

	model.Parent = Workspace
	return model, root, head
end

local function sampleAt(positions: { number }, index: number): Vector3
	local base = index * 3
	return Vector3.new(positions[base + 1], positions[base + 2], positions[base + 3])
end

local function startPlayback(data: { Positions: { number }, SampleInterval: number })
	local model, root, head = buildGhostModel()
	ghostModel = model
	ghostRoot = root
	ghostHead = head

	local positions = data.Positions
	local interval = data.SampleInterval
	local totalSamples = #positions / 3

	ghostConnection = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - raceStartTime
		local floatIndex = elapsed / interval
		local i0 = math.clamp(math.floor(floatIndex), 0, totalSamples - 1)
		local i1 = math.clamp(i0 + 1, 0, totalSamples - 1)
		local t = math.clamp(floatIndex - i0, 0, 1)

		local p0 = sampleAt(positions, i0)
		local p1 = sampleAt(positions, i1)
		local pos = p0:Lerp(p1, t)

		local direction = p1 - p0
		local lookCFrame = if direction.Magnitude > 0.05
			then CFrame.new(pos, pos + Vector3.new(direction.X, 0, direction.Z))
			else CFrame.new(pos)

		root.CFrame = lookCFrame
		head.CFrame = lookCFrame + Vector3.new(0, ROOT_HALF_HEIGHT + 0.9, 0)
	end)
end

local function stopPlayback()
	if ghostConnection then
		ghostConnection:Disconnect()
		ghostConnection = nil
	end
	if ghostModel then
		ghostModel:Destroy()
		ghostModel = nil
	end
	ghostRoot = nil
	ghostHead = nil
end

local function startRecording()
	recording = true
	recordedPositions = {}
	task.spawn(function()
		while recording do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local pos = root.Position
				table.insert(recordedPositions, pos.X)
				table.insert(recordedPositions, pos.Y)
				table.insert(recordedPositions, pos.Z)
			end
			task.wait(SAMPLE_INTERVAL)
		end
	end)
end

local function stopRecording()
	recording = false
end

-- Fired the moment "Racing" starts, only while PlayButtonController says
-- this queue attempt was Practice mode -- fetches the stored ghost (if any)
-- and kicks off both playback and a fresh recording in parallel.
local function onPracticeRaceStart()
	raceStartTime = os.clock()
	startRecording()

	if not currentStageId then
		return
	end
	local data = Net.GetRemoteFunction(RemoteNames.GetGhostRun):InvokeServer(currentStageId)
	ghostData = data
	if data then
		startPlayback(data)
	end
end

local function onPracticeComplete(elapsedSeconds: number)
	stopRecording()
	stopPlayback()

	if currentStageId and #recordedPositions > 0 then
		Net.GetRemoteEvent(RemoteNames.SubmitGhostRun):FireServer(
			currentStageId,
			recordedPositions,
			math.floor(elapsedSeconds * 1000)
		)
	end

	local minutes = math.floor(elapsedSeconds / 60)
	local seconds = elapsedSeconds - minutes * 60
	local previousBest = ghostData and (ghostData.TimeMs / 1000) or nil
	detailLabel.Text = ("Time: %d:%05.2f"):format(minutes, seconds)
		.. (if previousBest and elapsedSeconds < previousBest then "  -- NEW BEST!" else "")

	Sounds.Play("Victory")
	Widgets.Open(panel)
	task.wait(3.2)
	Widgets.Close(panel)
	task.wait(0.4)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GhostGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Same slot RaceOutcomeController uses -- a practice run can never be
	-- happening at the same time as a real race outcome, so there's no
	-- overlap sharing the position.
	panel = Widgets.Panel(UDim2.fromOffset(360, 130), UDim2.new(0.5, -180, 0.55, 0))
	panel.Parent = screenGui

	local title = Widgets.Label("PRACTICE COMPLETE", UDim2.new(1, -20, 0, 34), UDim2.fromOffset(10, 14), {
		Font = Theme.Font.Display,
		TextSize = 22,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.AccentB,
	})
	title.Parent = panel

	detailLabel = Widgets.Label("", UDim2.new(1, -20, 0, 28), UDim2.fromOffset(10, 60), {
		TextSize = 18,
		Align = Enum.TextXAlignment.Center,
	})
	detailLabel.Parent = panel
end

function GhostController.Init()
	buildUI()

	Net.GetRemoteEvent(RemoteNames.MapSelected).OnClientEvent:Connect(function(stageId: string)
		currentStageId = stageId
	end)

	Net.GetRemoteEvent(RemoteNames.PracticeComplete).OnClientEvent:Connect(onPracticeComplete)

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" and PlayButtonController.CurrentMode == "Practice" then
			onPracticeRaceStart()
		elseif state ~= "Racing" then
			-- Covers quitting mid-practice-run (Backspace) or any other exit
			-- that isn't the normal PracticeComplete flow -- stop everything
			-- and discard the in-progress recording rather than submitting a
			-- run that never finished.
			stopRecording()
			stopPlayback()
		end
	end)
end

return GhostController
