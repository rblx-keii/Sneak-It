--|| Services
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

--|| References
local MapsFolder = ServerStorage:FindFirstChild("Maps")

--|| Variables
local _activeMap: Model? = nil

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	if not MapsFolder then
		warn("[MapService] ServerStorage.Maps folder not found — map loading will fail")
	end
end

function Shared.Start()

end

-- [[ Private Functions ]] --
function Local.PickRandomMapTemplate(): Model?
	if not MapsFolder then return nil end

	local candidates: {Model} = {}
	for _, child in MapsFolder:GetChildren() do
		if child:IsA("Folder") then
			table.insert(candidates, child)
		end
	end

	if #candidates == 0 then
		warn("[MapService] ServerStorage.Maps contains no Folder templates")
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

-- [[ Public Functions ]] --

function Shared.Load(): Model?
	if _activeMap then
		warn("[MapService] Load() called while a map is already active — cleaning up stale map first")
		Shared.Cleanup()
	end

	local template = Local.PickRandomMapTemplate()
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Parent = Workspace
	_activeMap = clone

	return clone
end

function Shared.GetActiveMap(): Model?
	return _activeMap
end

function Shared.Cleanup(): ()
	if not _activeMap then return end

	_activeMap:Destroy()
	_activeMap = nil
end

return Shared