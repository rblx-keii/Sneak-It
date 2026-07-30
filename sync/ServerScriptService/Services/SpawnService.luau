--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)

local MapService = require(script.Parent.MapService)

--|| Types
type SpawnResult = {
	success: boolean,
	cframe: CFrame
}

--|| Constants
local MAX_SPAWN_ATTEMPTS = 50
local RAYCAST_TOP_BUFFER = 10
local RAYCAST_MAX_DISTANCE = 200
local OVERLAP_PARAMS = OverlapParams.new()

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	OVERLAP_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
end

function Shared.Start()

end

-- [[ Private Functions ]] --

function Local.GetSpawnsFolder(): Folder?
	local activeMap = MapService.GetActiveMap()
	if not activeMap then
		warn("[SpawnService] No active map — cannot resolve team spawn zones")
		return nil
	end

	local spawnsFolder = activeMap:FindFirstChild("Spawns")
	if not spawnsFolder then
		warn("[SpawnService] Active map has no Spawns folder")
		return nil
	end

	return spawnsFolder
end

function Local.GetRandomXZInPart(part: BasePart): Vector3
	local halfX = part.Size.X / 2
	local halfZ = part.Size.Z / 2

	local localX = math.random() * 2 * halfX - halfX
	local localZ = math.random() * 2 * halfZ - halfZ

	local worldOffset = part.CFrame:VectorToWorldSpace(Vector3.new(localX, 0, localZ))
	return part.Position + worldOffset
end

function Local.RaycastFloor(xzPosition: Vector3, zoneTop: number, ignoreList: {Instance}): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList

	local origin = Vector3.new(xzPosition.X, zoneTop + RAYCAST_TOP_BUFFER, xzPosition.Z)
	local direction = Vector3.new(0, -RAYCAST_MAX_DISTANCE, 0)

	local result = Workspace:Raycast(origin, direction, params)
	return result and result.Position or nil
end

function Local.IsHitPartOfCharacter(hitPart: BasePart): boolean
	local ancestor = hitPart.Parent
	while ancestor do
		if ancestor:FindFirstChildWhichIsA("Humanoid") then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

function Local.IsPositionClear(position: Vector3, halfSize: Vector3, characterToIgnore: Model): boolean
	OVERLAP_PARAMS.FilterDescendantsInstances = { characterToIgnore }

	local hits = Workspace:GetPartBoundsInBox(
		CFrame.new(position),
		halfSize * 2,
		OVERLAP_PARAMS
	)

	for _, hit in hits do
		if Local.IsHitPartOfCharacter(hit) then
			local hitCharacterModel = hit:FindFirstAncestorWhichIsA("Model")
			if hitCharacterModel and Players:GetPlayerFromCharacter(hitCharacterModel) then
				return false
			end
			continue
		end

		if hit.CanCollide then
			return false
		end
	end

	return true
end

-- Measured from the live bounding box rather than Humanoid.HipHeight, which can read stale right after CharacterAdded
function Local.GetRootToFeetOffset(character: Model, hrp: BasePart): number
	local boundsCFrame, boundsSize = character:GetBoundingBox()
	local feetY = boundsCFrame.Position.Y - boundsSize.Y / 2
	return hrp.Position.Y - feetY
end

function Local.ResolveSpawnCFrame(spawnZone: BasePart, character: Model): CFrame
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart

	if not humanoid or not hrp then
		warn("[SpawnService] Character missing Humanoid or HumanoidRootPart — using zone center fallback")
		return spawnZone.CFrame
	end

	local hrpHalfSize = hrp.Size / 2
	local zoneTop = spawnZone.Position.Y + (spawnZone.Size.Y / 2)
	local rootToFeetOffset = Local.GetRootToFeetOffset(character, hrp)

	for attempt = 1, MAX_SPAWN_ATTEMPTS do
		local candidateXZ = Local.GetRandomXZInPart(spawnZone)
		local floorHit = Local.RaycastFloor(candidateXZ, zoneTop, { character })

		if floorHit then
			local candidatePos = Vector3.new(
				floorHit.X,
				floorHit.Y + rootToFeetOffset,
				floorHit.Z
			)

			if Local.IsPositionClear(candidatePos, hrpHalfSize, character) then
				return CFrame.new(candidatePos)
			end
		end

		if attempt == MAX_SPAWN_ATTEMPTS then
			warn(`[SpawnService] All {MAX_SPAWN_ATTEMPTS} spawn attempts blocked — using raycast-corrected zone center fallback`)
		end
	end

	local centerFloor = Local.RaycastFloor(spawnZone.Position, zoneTop, { character })
	local fallbackY = if centerFloor
		then centerFloor.Y + rootToFeetOffset
		else zoneTop + rootToFeetOffset

	return CFrame.new(spawnZone.Position.X, fallbackY, spawnZone.Position.Z)
end

function Local.GetRandomLobbySpawnLocation(): SpawnLocation?
	local candidates: {SpawnLocation} = {}

	for _, instance in Workspace:GetDescendants() do
		if instance:IsA("SpawnLocation") and instance.Enabled then
			if instance.Neutral or instance.TeamColor == nil then
				table.insert(candidates, instance)
			end
		end
	end

	if #candidates == 0 then
		warn("[SpawnService] No enabled neutral SpawnLocation found for lobby return")
		return nil
	end

	return candidates[math.random(1, #candidates)]
end

-- [[ Public Functions ]] --

function Shared.SpawnPlayer(player: Player, teamName: string)
	local spawnsFolder = Local.GetSpawnsFolder()
	if not spawnsFolder then return end

	local spawnZone = spawnsFolder:FindFirstChild(teamName:upper()) :: BasePart
	if not spawnZone then
		warn(`[SpawnService] No spawn zone found for team "{teamName:upper()}"`)
		return
	end

	local function doSpawn()
		local character = player.Character
		if not character then return end

		local spawnCFrame = Local.ResolveSpawnCFrame(spawnZone, character)
		character:PivotTo(spawnCFrame)
	end

	if player.Character then
		doSpawn()
	else
		local conn
		conn = player.CharacterAdded:Connect(function()
			conn:Disconnect()
			task.defer(doSpawn)
		end)
	end
end

function Shared.SpawnPlayerToIntermission(player: Player)
	local character = player.Character
	if not character then return end

	local spawnLocation = Local.GetRandomLobbySpawnLocation()
	if not spawnLocation then return end

	character:PivotTo(spawnLocation.CFrame + Vector3.new(0, 3, 0))
end

return Shared