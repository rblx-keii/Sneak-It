local actor = script:GetActor()
if not actor then
	warn("[NpcService ActorScript] Not parented under an Actor — decisions will never run")
	return
end

local reportEventValue = script.Parent:WaitForChild("ReportEvent", 5) :: ObjectValue?
local reportEvent = reportEventValue and reportEventValue.Value :: BindableEvent?
if not reportEvent then
	warn("[NpcService ActorScript] No ReportEvent found — cannot report decisions back to the main thread")
	return
end

local Behaviors = require(game:GetService("ServerScriptService").Services.NpcService.Behaviors)

--|| Types
type DecisionRequest = {
	npc: Model,
	nodesFolder: Instance,
	currentNode: BasePart,
	lastNode: BasePart?,
	arrivedViaLink: boolean,
	behaviorType: string,
	lastRestTime: number,
	willBoard: boolean?,
	holdingBag: boolean?,
	pendingBagNode: BasePart?,
	prefetch: boolean?,
}

--|| MAIN ||--

actor:BindToMessageParallel("Decide", function(request: DecisionRequest)
	task.synchronize()

	local behavior = Behaviors.Get(request.behaviorType)
	if not behavior then
		warn(`[NpcService ActorScript] No Behavior module registered for "{request.behaviorType}"`)
		reportEvent:Fire(request.npc, nil, "Arrived", request.prefetch)
		return
	end

	local nextNode, state = behavior.GetNextTarget({
		npc = request.npc,
		nodesFolder = request.nodesFolder,
		currentNode = request.currentNode,
		lastNode = request.lastNode,
		arrivedViaLink = request.arrivedViaLink,
		lastRestTime = request.lastRestTime,
		willBoard = request.willBoard,
		holdingBag = request.holdingBag,
		pendingBagNode = request.pendingBagNode,
	})

	reportEvent:Fire(request.npc, nextNode, state, request.prefetch)
end)
