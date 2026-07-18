local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Shown while state == "Spectating" (see MatchService.PlayerReachedFinish /
-- LeaveSpectate): finishing/losing a race no longer yanks you straight back
-- to the lobby if others are still racing -- you get to watch them fight it
-- out in the same 3D space (normal multiplayer visibility already shows you
-- their characters; no custom camera/replication needed for that part). This
-- is the only new UI: how many racers are left, and a reminder of how to
-- leave (QuitMatchController's button/Backspace already covers that).
local SpectateController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local statusLabel: TextLabel

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SpectateGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Same slot RaceHudController's race timer panel uses -- "Racing" and
	-- "Spectating" are mutually exclusive states, so there's no overlap.
	panel = Widgets.Panel(UDim2.fromOffset(280, 88), UDim2.new(0.5, -140, 0, 56))
	panel.Parent = screenGui

	local title = Widgets.Label("SPECTATING", UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 8), {
		TextSize = 15,
		Color = Theme.Color.TextMuted,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = panel

	statusLabel = Widgets.Label("Watching the finish...", UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 34), {
		Font = Theme.Font.Heading,
		TextSize = 18,
		Align = Enum.TextXAlignment.Center,
	})
	statusLabel.Parent = panel
end

local function updateStatus(remaining: number)
	statusLabel.Text = if remaining == 1 then "1 racer still going" else ("%d racers still going"):format(remaining)
end

function SpectateController.Init()
	buildUI()

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Spectating" then
			Widgets.Open(panel)
		elseif panel.Visible then
			Widgets.Close(panel)
		end
	end)

	Net.GetRemoteEvent(RemoteNames.SpectateStatus).OnClientEvent:Connect(updateStatus)
end

return SpectateController
