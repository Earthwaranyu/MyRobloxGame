local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Loader = require(Shared.Loader)

Loader.LoadAll(script.Controllers)
