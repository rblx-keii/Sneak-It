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

--[[-[
	Creates a new Cycler object.
	@param data table - The data to cycle through.
	@return Cycler - The new Cycler object.
]-]]
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

--[[-[
	Gets the next value in the cycle.
	@return number - The index of the value.
	@return any - The key of the value.
	@return any - The value.
]-]]
function Cycler:Next(): (number, any, any)
	self.Index += 1
	if self.Index > #self.Keys then
		self.Index = 1
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

--[[-[
	Gets the previous value in the cycle.
	@return number - The index of the value.
	@return any - The key of the value.
	@return any - The value.
]-]]
function Cycler:Previous(): (number, any, any)
	self.Index -= 1
	if self.Index < 1 then
		self.Index = #self.Keys
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

--[[-[
	Gets the current value in the cycle.
	@return number - The index of the value.
	@return any - The key of the value.
	@return any - The value.
]-]]
function Cycler:Current(): (number, any, any)
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

--[[-[
	Sets the current index.
	@param newIndex number - The new index.
	@return number - The index of the value.
	@return any - The key of the value.
	@return any - The value.
]-]]
function Cycler:SetIndex(newIndex: number): (number, any, any)
	if newIndex >= 1 and newIndex <= #self.Keys then
		self.Index = newIndex
	end
	local key = self.Keys[self.Index]
	return self.Index, key, self.Values[self.Index]
end

--[[-[
	Gets the current index.
	@return number - The current index.
]-]]
function Cycler:GetIndex(): number
	return self.Index
end

--[[-[
	Gets the length of the cycle.
	@return number - The length of the cycle.
]-]]
function Cycler:GetLength(): number
	return #self.Keys
end

return Cycler
