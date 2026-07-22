--!strict
local Zone = require("@self/Zone")

export type Signal<T = (...any) -> ()> = {
	Connect: (self: Signal<T>, callback: T) -> RBXScriptConnection,
	Wait: (self: Signal<T>) -> ...any,
	DisconnectAll: (self: Signal<T>) -> (),
	Once: (self: Signal<T>, callback: T) -> (),
	Fire: (self: Signal<T>, ...any) -> (),
}

export type ZoneType = {
	playerEntered: Signal<(player: Player) -> ()>,
	playerExited: Signal<(player: Player) -> ()>,
	playerInside: Signal<(player: Player) -> ()>,

	localPlayerEntered: Signal,
	localPlayerExited: Signal,
	localPlayerInside: Signal,

	SetAccuracy: (self: ZoneType, seconds: number) -> (),
	GetRandomPoint: (self: ZoneType) -> Vector3,

	isPointInZone: (self: ZoneType, point: Vector3) -> boolean,
	isPartInZone: (self: ZoneType, part: BasePart) -> boolean,
	isPlayerInZone: (self: ZoneType, player: Player) -> boolean,
	isCharacterInZone: (self: ZoneType, character: Model) -> boolean,

	destroy: (self: ZoneType) -> (),
	Destroy: (self: ZoneType) -> (),
}

local function new(zoneSource: BasePart | { BasePart }): ZoneType
	local zone = Zone.new(zoneSource) :: any

	return zone
end

return {
	new = new,
}
