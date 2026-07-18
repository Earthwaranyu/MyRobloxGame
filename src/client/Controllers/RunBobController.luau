local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SprintController = require(script.Parent.SprintController)
local SettingsController = require(script.Parent.SettingsController)
local MatchStateController = require(script.Parent.MatchStateController)

-- Modeled on how a real human sprint actually reads to the runner's own eyes
-- (the well-documented reference point for FPS "run cam" work), not just a
-- generic wobble:
--   - Vertical bob happens ONCE PER FOOTSTEP, not once per stride. A raw
--     sine wave only has one bump per full cycle (= one bump per two steps),
--     which reads as floating/swimming rather than running.
--   - Each footstep is asymmetric: a quick, sharp rise as the leg pushes off
--     (~30% of the step), then a slower, longer fall through the airborne
--     "float" phase into the next plant. A symmetric sine can't produce that
--     -- it needs a piecewise curve.
--   - Lateral sway and hip roll alternate in a two-step cycle (left plant
--     pulls the camera one way, right plant the other), at HALF the vertical
--     bob's frequency.
--   - A real sprinter's cadence is roughly 4-4.5 steps/sec, way faster than
--     a casual walk-cycle bob -- using a slow frequency was a big part of
--     why the old version didn't feel like sprinting.
--   - Real gait isn't perfectly periodic: each stride lands with slightly
--     different force. That's stride-to-stride amplitude variance rolled
--     once per step, not fast uncorrelated jitter added every frame (which
--     just reads as noisy static rather than physical motion).
--   - Slightly widened FOV while sprinting, a well-worn technique for
--     selling speed in first person.
-- All of it layered onto Roblox's own first-person camera every frame
-- (RenderStepped, one priority tick after the built-in camera updates)
-- rather than replacing it. IMPORTANT: every rotation/position term here has
-- to average out to exactly zero over a full cycle. A first version added a
-- constant forward lean on top of this and it made the camera creep steadily
-- downward every frame instead of settling into a lean -- Roblox's own
-- camera script smooths toward its target using the previous frame's CFrame
-- as part of its basis, so a non-oscillating (non-zero-mean) offset applied
-- every frame compounds instead of cancelling out the way the bob/sway/roll
-- do. Don't add a constant offset here again without accounting for that.
local RunBobController = {}

local BIND_NAME = "RunBob"
local STEP_FREQUENCY = 4.3 -- steps/sec, sprint cadence
local IMPACT_FRACTION = 0.32 -- fraction of each step spent on the push-off rise
local VERTICAL_AMPLITUDE = 0.16
local LATERAL_AMPLITUDE = 0.075
local ROLL_AMPLITUDE_DEG = 1.7
local FOV_BOOST = 6
local BLEND_SPEED = 10 -- how fast the effect fades in/out when sprint state flips
local STRIDE_VARIANCE = 0.18 -- +/- amplitude randomness, rolled once per step

local elapsed = 0
local blend = 0 -- 0..1, smoothed so starting/stopping sprint doesn't snap
local lastStepIndex = -1
local strideAmpScale = 1
local baseFOV: number? = nil

local function shouldBob(): boolean
	return SprintController.Sprinting
		and SettingsController.WindEffectEnabled
		and MatchStateController.CurrentState == "Racing"
end

local function update(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if baseFOV == nil then
		baseFOV = camera.FieldOfView
	end

	local target = if shouldBob() then 1 else 0
	blend += (target - blend) * math.min(1, BLEND_SPEED * dt)

	if blend < 0.001 then
		elapsed = 0
		lastStepIndex = -1
		camera.FieldOfView = baseFOV :: number
		return
	end

	elapsed += dt

	local stepPos = elapsed * STEP_FREQUENCY
	local stepIndex = math.floor(stepPos)
	local phase = stepPos - stepIndex -- 0..1 within the current step

	if stepIndex ~= lastStepIndex then
		lastStepIndex = stepIndex
		strideAmpScale = 1 + (math.random() * 2 - 1) * STRIDE_VARIANCE
	end

	-- Sharp rise, slower fall -- an impact-and-float curve instead of a
	-- symmetric sine. Triangular 0->1->0 shape, mean 0.5 regardless of skew,
	-- so subtracting exactly 0.5 (not just roughly) keeps this zero-mean.
	local verticalCurve
	if phase < IMPACT_FRACTION then
		verticalCurve = phase / IMPACT_FRACTION
	else
		verticalCurve = 1 - (phase - IMPACT_FRACTION) / (1 - IMPACT_FRACTION)
	end
	local vertical = (verticalCurve - 0.5) * VERTICAL_AMPLITUDE * strideAmpScale

	-- Alternates left/right every other step; sin(phase*pi) rises from 0 to
	-- 1 and back to 0 across a single step so consecutive steps join smoothly
	-- with no snap at the boundary.
	local strideSide = if stepIndex % 2 == 0 then 1 else -1
	local swayEnvelope = math.sin(phase * math.pi)
	local lateral = swayEnvelope * LATERAL_AMPLITUDE * strideSide * strideAmpScale
	local roll = swayEnvelope * ROLL_AMPLITUDE_DEG * strideSide * strideAmpScale

	local offset = CFrame.new(lateral, vertical, 0) * CFrame.Angles(0, 0, math.rad(roll))
	local blended = CFrame.new():Lerp(offset, blend)

	camera.CFrame = camera.CFrame * blended
	camera.FieldOfView = (baseFOV :: number) + FOV_BOOST * blend
end

function RunBobController.Init()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, update)
end

return RunBobController
