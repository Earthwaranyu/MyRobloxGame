local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Loader = require(Shared.Loader)
local PrivateServer = require(Shared.PrivateServer)

-- Before the services, so nothing can read the flag ahead of it being written
-- -- and well before any client can join, so the answer is already sitting in
-- ReplicatedStorage when their scripts start.
PrivateServer.Publish()

Loader.LoadAll(script.Services)
