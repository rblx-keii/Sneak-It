--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)
local CharacterController = require(ReplicatedStorage.Modules.Shared.CharacterController)

--|| Types

--|| Variables
local _stopCharacterObserver: (() -> ())? = nil
local _stopBarricadeObserver: (() -> ())? = nil
local _playerActionTracks: { [Player]: CharacterController.AnimationSet } = {}

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
	PhysicsService:RegisterCollisionGroup("DoorOpen")
	PhysicsService:RegisterCollisionGroup("NPCBarricade")

	PhysicsService:CollisionGroupSetCollidable("Players", "Players", false)
	PhysicsService:CollisionGroupSetCollidable("Players", "ItemBasePart", false)
	PhysicsService:CollisionGroupSetCollidable("ItemBasePart", "ItemBasePart", false)
	PhysicsService:CollisionGroupSetCollidable("Players", "RagdollLimb", false)
	PhysicsService:CollisionGroupSetCollidable("Default", "RagdollLimb", true)
	PhysicsService:CollisionGroupSetCollidable("RagdollLimb", "RagdollLimb", false)
	PhysicsService:CollisionGroupSetCollidable("NPC", "NPC", false)
	PhysicsService:CollisionGroupSetCollidable("DoorOpen", "Default", false)
	PhysicsService:CollisionGroupSetCollidable("DoorOpen", "Players", false)
	PhysicsService:CollisionGroupSetCollidable("DoorOpen", "NPC", false)
	PhysicsService:CollisionGroupSetCollidable("Players", "NPCBarricade", false)

	_stopCharacterObserver = Observers.observeCharacter(function(player: Player, character: Model)
		character:AddTag("Player")

		local stopDescendants = Observers.observeDescendants(character, function(part: BasePart)
			part.CollisionGroup = "Players"
		end, function(descendant: Instance)
			return descendant:IsA("BasePart")
		end)

		local defaultAnimate = character:FindFirstChild("Animate")
		if defaultAnimate then
			defaultAnimate:Destroy()
		end

		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if humanoid then
			_playerActionTracks[player] = CharacterController.Setup(humanoid)
		end

		return function()
			stopDescendants()
			_playerActionTracks[player] = nil
		end
	end)

	_stopBarricadeObserver = Observers.observeTag("NPCBarricade", function(instance: Instance)
		if instance:IsA("BasePart") then
			instance.CollisionGroup = "NPCBarricade"
			return nil
		end

		return Observers.observeDescendants(instance, function(part: BasePart)
			part.CollisionGroup = "NPCBarricade"
		end, function(descendant: Instance)
			return descendant:IsA("BasePart")
		end)
	end)
end

function Shared.Start()

end

--[[ Private Functions ]]--

--[[ Public Functions ]]--

function Shared.GetActionTracks(player: Player): CharacterController.AnimationSet?
	return _playerActionTracks[player]
end

function Shared.Destroy()
	if _stopCharacterObserver then
		_stopCharacterObserver()
		_stopCharacterObserver = nil
	end
	if _stopBarricadeObserver then
		_stopBarricadeObserver()
		_stopBarricadeObserver = nil
	end
end

return Shared