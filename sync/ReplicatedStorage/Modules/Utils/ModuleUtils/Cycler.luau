export type Cycler = {
	Next: (self: Cycler) -> (number, any, any),
	Previous: (self: Cycler) -> (number, any, any),
	Current: (self: Cycler) -> (number, any, any),
	SetIndex: (self: Cycler, newIndex: number) -> (number, any, any),
	GetIndex: (self: Cycler) -> number,
	GetLength: (self: Cycler) -> number,
}

local Cycler = {}
Cycler.__index = Cycler

function Cycler.new(data: { [any]: any }): Cycler
	local self = setmetatable({}, Cycler)

	self.Values = {}
	self.Keys = {}
	self.Index = 1

	for key, value in pairs(data) do
		if key == 0 then
			continue
		end
		table.insert(self.Keys, key)
		table.insert(self.Values, value)
	end

	return self
end

function Cycler:Next(): (number, any, any)
	self.Index += 1
	if self.Index > #self.Keys then
		self.Index = 1
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

function Cycler:Previous(): (number, any, any)
	self.Index -= 1
	if self.Index < 1 then
		self.Index = #self.Keys
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

function Cycler:Current(): (number, any, any)
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

function Cycler:SetIndex(newIndex: number): (number, any, any)
	if newIndex >= 1 and newIndex <= #self.Keys then
		self.Index = newIndex
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

function Cycler:GetIndex(): number
	return self.Index
end

function Cycler:GetLength(): number
	return #self.Keys
end

return Cycler
