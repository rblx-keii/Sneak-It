local StarterGui = game:GetService("StarterGui")

local Selection = require(script.Parent.Selection)
local Theme = require(script.Parent.Theme)

export type ListViewHandle = {
	SetFilter: (self: ListViewHandle, text: string) -> (),
	SelectAll: (self: ListViewHandle) -> (),
	DeselectAll: (self: ListViewHandle) -> (),
	GetSelectedNames: (self: ListViewHandle) -> { string },
	GetVisibleNames: (self: ListViewHandle) -> { string },
	SetOnSelectionChanged: (self: ListViewHandle, callback: () -> ()) -> (),
	Destroy: (self: ListViewHandle) -> (),
}

type Row = {
	frame: Frame,
	checkbox: TextButton,
	name: string,
}

local ROW_HEIGHT = 26
local CHECK_SIZE = 18
-- ChildAdded/ChildRemoved miss renames of an *existing* top-level child (the
-- old name lingers in `rows`, and since sync resolves names via
-- StarterGui:FindFirstChild, a renamed GUI would silently drop out of every
-- push until something forces a refresh). This periodic re-scan catches
-- renames — and anything else — without needing per-child Name listeners.
local REFRESH_INTERVAL = 2

local ListView = {}

local function getChildrenSorted(): { Instance }
	local children = {}
	for _, child in StarterGui:GetChildren() do
		if child.Archivable then
			table.insert(children, child)
		end
	end
	table.sort(children, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return children
end

local function setCheckboxVisual(checkbox: TextButton, checked: boolean)
	checkbox.Text = if checked then "v" else ""
	checkbox.BackgroundColor3 = if checked then Theme.Color.Accent else Theme.Color.Input
end

function ListView.new(parent: GuiObject): ListViewHandle
	local self = {} :: any

	local rows: { [string]: Row } = {}
	local filterText = ""
	local onSelectionChanged: (() -> ())? = nil

	local function fireSelectionChanged()
		if onSelectionChanged then
			onSelectionChanged()
		end
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent

	local function applyFilter(row: Row)
		row.frame.Visible = filterText == "" or row.name:lower():find(filterText, 1, true) ~= nil
	end

	local function createRow(name: string, layoutOrder: number): Row
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		frame.BackgroundColor3 = Theme.Color.Card
		frame.BackgroundTransparency = 1
		frame.LayoutOrder = layoutOrder
		frame.Parent = parent

		Theme.Round(frame, Theme.Radius.Pill)

		frame.MouseEnter:Connect(function()
			frame.BackgroundTransparency = 0
		end)
		frame.MouseLeave:Connect(function()
			frame.BackgroundTransparency = 1
		end)

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(1, -CHECK_SIZE - 14, 1, 0)
		label.Position = UDim2.new(0, 6, 0, 0)
		label.BackgroundTransparency = 1
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = Theme.Color.Text
		label.TextSize = 14
		label.Font = Theme.Font.Regular
		label.Text = name
		label.Parent = frame

		local checkbox = Instance.new("TextButton")
		checkbox.Name = "Checkbox"
		checkbox.Size = UDim2.new(0, CHECK_SIZE, 0, CHECK_SIZE)
		checkbox.Position = UDim2.new(1, -CHECK_SIZE - 4, 0.5, -CHECK_SIZE / 2)
		checkbox.AutoButtonColor = false
		checkbox.Font = Theme.Font.Bold
		checkbox.TextSize = 14
		checkbox.TextColor3 = Theme.Color.Text
		checkbox.Parent = frame

		Theme.Round(checkbox, Theme.Radius.Check)

		local row: Row = { frame = frame, checkbox = checkbox, name = name }
		setCheckboxVisual(checkbox, Selection.Get(name))

		checkbox.MouseButton1Click:Connect(function()
			Selection.Toggle(name)
			setCheckboxVisual(checkbox, Selection.Get(name))
			fireSelectionChanged()
		end)

		return row
	end

	function self:Refresh()
		local children = getChildrenSorted()
		local seen: { [string]: boolean } = {}

		for i, child in children do
			seen[child.Name] = true
			local row = rows[child.Name]
			if not row then
				row = createRow(child.Name, i)
				rows[child.Name] = row
			else
				row.frame.LayoutOrder = i
			end
			applyFilter(row)
		end

		for name, row in rows do
			if not seen[name] then
				row.frame:Destroy()
				rows[name] = nil
			end
		end

		fireSelectionChanged()
	end

	function self:SetFilter(text: string)
		filterText = text:lower()
		for _, row in rows do
			applyFilter(row)
		end
	end

	function self:SelectAll()
		local names = {}
		for _, row in rows do
			if row.frame.Visible then
				table.insert(names, row.name)
			end
		end
		Selection.SetAll(names, true)
		for _, row in rows do
			if row.frame.Visible then
				setCheckboxVisual(row.checkbox, true)
			end
		end
		fireSelectionChanged()
	end

	function self:DeselectAll()
		local names = {}
		for _, row in rows do
			if row.frame.Visible then
				table.insert(names, row.name)
			end
		end
		Selection.SetAll(names, false)
		for _, row in rows do
			if row.frame.Visible then
				setCheckboxVisual(row.checkbox, false)
			end
		end
		fireSelectionChanged()
	end

	function self:GetSelectedNames(): { string }
		local names = {}
		for name in rows do
			if Selection.Get(name) then
				table.insert(names, name)
			end
		end
		table.sort(names)
		return names
	end

	function self:GetVisibleNames(): { string }
		local names = {}
		for _, row in rows do
			if row.frame.Visible then
				table.insert(names, row.name)
			end
		end
		table.sort(names)
		return names
	end

	function self:SetOnSelectionChanged(callback: () -> ())
		onSelectionChanged = callback
	end

	local addedConn = StarterGui.ChildAdded:Connect(function()
		self:Refresh()
	end)
	local removedConn = StarterGui.ChildRemoved:Connect(function()
		self:Refresh()
	end)

	local refreshToken = 0

	function self:Destroy()
		refreshToken += 1
		addedConn:Disconnect()
		removedConn:Disconnect()
		for _, row in rows do
			row.frame:Destroy()
		end
	end

	self:Refresh()

	do
		refreshToken += 1
		local token = refreshToken
		task.spawn(function()
			while token == refreshToken do
				task.wait(REFRESH_INTERVAL)
				if token ~= refreshToken then
					break
				end
				self:Refresh()
			end
		end)
	end

	return (self :: any) :: ListViewHandle
end

return ListView
