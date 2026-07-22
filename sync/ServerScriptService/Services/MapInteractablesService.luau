--|| Services
const CollectionService = game:GetService("CollectionService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local Network = require(ReplicatedStorage.Modules.Network)
local Observers = require(ReplicatedStorage.Modules.Libs.Observers)

local Setup = require(ReplicatedStorage.Modules.Configs.MapInteractables)

--|| Variables

--|| Constants

--|| Types

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	Observers.observeTag("MapInteractable", function(instance: Instance): (() -> ())? 
		local interactible = Setup(instance)
		return function ()
			if interactible and interactible.Destroy then
				interactible:Destroy()
			end
		end
	end)
end

function Shared.Start()
	
end

-- [[ Private Functions ]] --

-- [[ Public Functions ]] --

return Shared