-- Cloned by NpcService.Local.InjectActor into a fresh Actor parented under
-- each Crowd NPC at spawn — this is the per-NPC AI "brain," running in
-- genuinely parallel Luau (one independent VM per NPC).
--
-- It is intentionally dumb: given a snapshot of the NPC's current node/zone
-- context, it only ever COMPUTES a decision (which node to walk to next —
-- see Behaviors/) and reports it back via a shared BindableEvent. It never
-- touches the Humanoid and never calls PathfindingService itself — all
-- actual movement stays on the main thread in NpcService.
--
-- This mirrors legacy/NPCBrainScript.server.luau's design from this
-- project's earlier iteration: calling Humanoid:MoveTo directly from inside
-- an Actor (even after task.synchronize()) was tried this session and
-- didn't reliably take effect, so movement execution was moved back to the
-- main thread — only the decision math (reading/writing Attributes,
-- raycasting for line-of-sight, resolving Link/Entry ObjectValues) stays
-- here. Turns out none of that is actually exempt from synchronization
-- either (SetAttribute and mutating a RaycastParams' properties both throw
-- "not safe to call/modify in parallel" without it) — so `task.synchronize()`
-- is called once at the top of the handler below. That's sufficient for the
-- *entire* decision computation because nothing downstream (Behaviors/
-- NodeGraph) ever yields — synchronized state is only lost across a yield,
-- and there isn't one here (unlike PathfindingService:ComputeAsync, which is
-- why movement itself couldn't just stay synchronized in-place).
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

-- Since this script gets relocated (cloned into a fresh Actor elsewhere) it
-- can't reach Behaviors via `script.Parent` — reach it by its static
-- Services-registry path instead.
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
	})

	reportEvent:Fire(request.npc, nextNode, state, request.prefetch)
end)
