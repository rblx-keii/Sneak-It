-- Cloned by NPCAIService.Local.CreateBrainActor into a fresh Actor parented
-- under each Crowd NPC at spawn — this is the "AI decision" half of the
-- trait system, running in genuinely parallel Luau (one independent VM per
-- NPC). It is intentionally dumb: given a snapshot of the NPC's traits and
-- cooldown state (handed over in the message payload, since an Actor's Luau
-- state is isolated and can't see NPCAIService's tables directly), it rolls
-- which behavior category applies and reports the choice back — it never
-- touches an Instance, never resolves a specific target node/victim, and
-- never moves anything. All of that stays on the main thread in
-- NPCAIService, which is also the only place shared state (the node graph,
-- line queues, seat/occupancy bookkeeping) is allowed to be touched.
local actor = script:GetActor()
if not actor then
	warn("[NPCBrainScript] Not parented under an Actor — decisions will never run")
	return
end

local reportEventValue = script.Parent:WaitForChild("ReportEvent", 5) :: ObjectValue?
local reportEvent = reportEventValue and reportEventValue.Value :: BindableEvent?
if not reportEvent then
	warn("[NPCBrainScript] No ReportEvent found — cannot report decisions back to the main thread")
	return
end

--|| Types
type DecisionRequest = {
	uid: string,
	requestId: number,
	primaryTrait: string?, -- "WalkIn" | "Hasty" | "Loiterer"
	modifiers: { [string]: boolean }, -- "Weary" | "Caffeinated" | "Thief"
	thiefReady: boolean,
	caffeineReady: boolean,
	restChance: number,
	wanderChance: number,
	thiefChance: number,
	caffeineChance: number,
}

--|| MAIN ||--

-- Pure decision logic — no Instance mutation, just math.random against
-- numbers the main thread already resolved (per-NPC modifier state, cooldown
-- readiness, per-trait chance values). Mirrors the shape NPCAIService used
-- to compute in-process before the Actor split.
local function decide(request: DecisionRequest): string
	if request.primaryTrait == "Loiterer" then
		return "Loiter"
	end

	if request.primaryTrait == "Hasty" then
		return "Proceed" -- skips every detour, straight to the goal
	end

	if request.modifiers.Thief and request.thiefReady and math.random() < request.thiefChance then
		return "Theft"
	end

	if request.modifiers.Caffeinated and request.caffeineReady and math.random() < request.caffeineChance then
		return "CafeDivert"
	end

	if math.random() < request.restChance then
		return "Rest"
	end

	if math.random() < request.wanderChance then
		return "Wander"
	end

	return "Proceed"
end

actor:BindToMessageParallel("Decide", function(request: DecisionRequest)
	local action = decide(request)
	reportEvent:Fire(request.uid, request.requestId, action)
end)
