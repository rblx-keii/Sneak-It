--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)

--|| Types

--|| Variables
local _stopCharacterObserver: (() -> ())? = nil

--|| Constants

--|| MAIN ||--
local Local = {}
local Shared = {}

--[[ Signals ]]--

--[[ Startup ]]--

function Shared.Init()
	PhysicsService:RegisterCollisionGroup("Players")
	PhysicsService:RegisterCollisionGroup("ItemBasePart")
	PhysicsService:RegisterCollisionGroup("RagdollLimb")
	PhysicsService:RegisterCollisionGroup("NPC")

	PhysicsService:CollisionGroupSetCollidable("Players", "Players", false)
	PhysicsService:CollisionGroupSetCollidable("Players", "ItemBasePart", false)
	PhysicsService:CollisionGroupSetCollidable("ItemBasePart", "ItemBasePart", false)
	PhysicsService:CollisionGroupSetCollidable("Players", "RagdollLimb", false)
	PhysicsService:CollisionGroupSetCollidable("Default", "RagdollLimb", true)
	PhysicsService:CollisionGroupSetCollidable("RagdollLimb", "RagdollLimb", false)
	-- NPCs standing close together (e.g. queued in a line) shouldn't physically
	-- push against each other — that's what was causing one to get shoved up
	-- and "climb" onto another when the one ahead hadn't moved yet.
	PhysicsService:CollisionGroupSetCollidable("NPC", "NPC", false)

	_stopCharacterObserver = Observers.observeCharacter(function(player: Player, character: Model)
		character:AddTag("Player")

		local stopDescendants = Observers.observeDescendants(character, function(part: BasePart)
			part.CollisionGroup = "Players"
		end, function(descendant: Instance)
			return descendant:IsA("BasePart")
		end)

		return function()
			stopDescendants()
		end
	end)
end

function Shared.Start()

end

--[[ Private Functions ]]--

--[[ Public Functions ]]--
function Shared.Destroy()
	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end
end

return Shared