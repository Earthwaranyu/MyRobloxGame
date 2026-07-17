local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTES_FOLDER_NAME = "Remotes"

local Net = {}

local function getOrCreateRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = REMOTES_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function waitForRemotesFolder(): Folder
	return ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME) :: Folder
end

-- Server-side: finds or creates the remote.
function Net.CreateRemoteEvent(name: string): RemoteEvent
	local folder = getOrCreateRemotesFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	return remote :: RemoteEvent
end

function Net.CreateRemoteFunction(name: string): RemoteFunction
	local folder = getOrCreateRemotesFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
	end
	return remote :: RemoteFunction
end

-- Client-side: waits for the server to have created it.
function Net.GetRemoteEvent(name: string): RemoteEvent
	return waitForRemotesFolder():WaitForChild(name) :: RemoteEvent
end

function Net.GetRemoteFunction(name: string): RemoteFunction
	return waitForRemotesFolder():WaitForChild(name) :: RemoteFunction
end

return Net
