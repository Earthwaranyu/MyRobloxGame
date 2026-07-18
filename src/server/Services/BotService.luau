local Workspace = game:GetService("Workspace")

-- Bots are non-physical "hologram" NPCs (not real Humanoids): they glide
-- CFrame-to-CFrame between the same platform waypoints a real racer would
-- use, on a fixed, generous per-hop duration well slower than a competent
-- human racer, so they're "easy to beat" by design rather than by a weak AI
-- that might get stuck. CanCollide = false on every part is deliberate: a
-- hologram is intangible, which is also exactly what "players and bots
-- can't push each other" requires -- one property covers both asks.
local BotService = {}

export type BotHandle = {
	model: Model,
	cancelled: boolean,
}

local HOP_DURATION_MIN = 3.2
local HOP_DURATION_MAX = 4.4
local HOVER_HEIGHT = 2.2

local function getWaypoints(stageId: string): { BasePart }
	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	if not stageFolder then
		return {}
	end

	local waypoints: { BasePart } = {}
	local start = stageFolder:FindFirstChild("Platform_Start")
	if start and start:IsA("BasePart") then
		table.insert(waypoints, start)
	end

	local i = 1
	while stageFolder:FindFirstChild("Platform_" .. i) do
		local platform = stageFolder["Platform_" .. i]
		if platform:IsA("BasePart") then
			table.insert(waypoints, platform)
		end
		i += 1
	end

	local finish = stageFolder:FindFirstChild("Platform_Finish")
	if finish and finish:IsA("BasePart") then
		table.insert(waypoints, finish)
	end

	return waypoints
end

local function buildModel(spawnCFrame: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "RaceBot"

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2.4, 1)
	torso.Material = Enum.Material.ForceField -- built-in scrolling hologram shader, no custom texture needed
	torso.Color = Color3.fromRGB(90, 220, 255)
	torso.Transparency = 0.25
	torso.CanCollide = false
	torso.Anchored = true
	torso.CFrame = spawnCFrame
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.3, 1.3, 1.3)
	head.Material = Enum.Material.ForceField
	head.Color = Color3.fromRGB(150, 235, 255)
	head.Transparency = 0.2
	head.CanCollide = false
	head.Anchored = true
	head.CFrame = spawnCFrame + Vector3.new(0, 1.8, 0)
	head.Parent = model

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(120, 220, 255)
	light.Range = 12
	light.Brightness = 2
	light.Parent = torso

	local nameTag = Instance.new("BillboardGui")
	nameTag.Name = "BotLabel"
	nameTag.Size = UDim2.fromOffset(110, 26)
	nameTag.StudsOffset = Vector3.new(0, 2.2, 0)
	nameTag.AlwaysOnTop = true
	nameTag.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "BOT"
	label.TextColor3 = Color3.fromRGB(150, 235, 255)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = nameTag

	model.PrimaryPart = torso
	model.Parent = Workspace

	return model
end

-- No physics, so no TweenService dependency on Model:PivotTo either -- a
-- plain per-frame lerp loop is simple and cancellable mid-flight.
local function glideTo(bot: BotHandle, targetCFrame: CFrame, duration: number)
	local startCFrame = bot.model:GetPivot()
	local startTime = os.clock()

	while not bot.cancelled do
		local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
		bot.model:PivotTo(startCFrame:Lerp(targetCFrame, alpha))
		if alpha >= 1 then
			return
		end
		task.wait()
	end
end

function BotService.SpawnBot(stageId: string): BotHandle?
	local waypoints = getWaypoints(stageId)
	local start = waypoints[1]
	if not start then
		return nil
	end

	local model = buildModel(start.CFrame + Vector3.new(0, HOVER_HEIGHT, 0))
	return { model = model, cancelled = false }
end

-- Glides through every waypoint in order, then calls onFinished() -- unless
-- DespawnBot cancelled it first, in which case onFinished is never called.
function BotService.RunBot(bot: BotHandle, stageId: string, onFinished: () -> ())
	local waypoints = getWaypoints(stageId)

	task.spawn(function()
		for _, waypoint in waypoints do
			if bot.cancelled then
				return
			end
			local duration = HOP_DURATION_MIN + math.random() * (HOP_DURATION_MAX - HOP_DURATION_MIN)
			glideTo(bot, waypoint.CFrame + Vector3.new(0, HOVER_HEIGHT, 0), duration)
		end
		if not bot.cancelled then
			onFinished()
		end
	end)
end

function BotService.DespawnBot(bot: BotHandle?)
	if not bot then
		return
	end
	bot.cancelled = true
	if bot.model and bot.model.Parent then
		bot.model:Destroy()
	end
end

return BotService
