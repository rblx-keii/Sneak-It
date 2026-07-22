local TweenService = game:GetService("TweenService")

local RadialProgress = {}
RadialProgress.__index = RadialProgress

export type RadialProgressConfig = {
	CornerRadius: UDim?,
	Thickness: number?,
	Color: Color3?,
	ParentToParentFrame: boolean?,
}

export type ClassType = typeof(setmetatable({} :: {
	-- || Properties
	Container: Frame,
	Scale: UIScale,
	RightRing: Frame,
	RightGradient: UIGradient,
	RightCorner: UICorner,
	RightStroke: UIStroke,
	LeftRing: Frame,
	LeftGradient: UIGradient,
	LeftCorner: UICorner,
	LeftStroke: UIStroke,

	-- State
	_parentFrame: Frame,
	_innerRadius: UDim,
	_thickness: number?,
	_padding: number?,
	_activeTween: Tween?,

	-- Connections
	_tweenTracker: NumberValue,
	_tweenConnection: RBXScriptConnection,
	_parentSizeConn: RBXScriptConnection,

	-- || Public Methods
	SetProgress: (self: ClassType, percent: number) -> (),
	TweenProgress: (self: ClassType, targetPercent: number, tweenInfo: TweenInfo) -> Tween,
	SetCornerRadius: (self: ClassType, udim: UDim) -> (),
	SetThickness: (self: ClassType, thickness: number) -> (),
	SetColor: (self: ClassType, color: Color3) -> (),
	Destroy: (self: ClassType) -> (),

	-- || Private Methods
	_updateUI: (self: ClassType, percent: number) -> (),
	_ApplyPadding: (self: ClassType, padding: number) -> (),
	_RecalculatePadding: (self: ClassType) -> (),
}, RadialProgress))

-- [[ Private Helpers ]] --
local function HasDirectLayout(instance: Instance): boolean
	for _, child in instance:GetChildren() do
		if child:IsA("UILayout") then
			return true
		end
	end
	return false
end

local function ResolveContainerParent(subjectFrame: Frame, wantsParentToParentFrame: boolean?): Instance
	local candidateParent = subjectFrame.Parent

	local shouldUseParent = wantsParentToParentFrame
	if shouldUseParent == nil then
		shouldUseParent = candidateParent ~= nil and not HasDirectLayout(candidateParent)
	end

	if shouldUseParent and candidateParent and candidateParent:IsA("GuiObject") then
		return candidateParent
	end

	return subjectFrame
end

--|| MAIN ||--
function RadialProgress.new(parentFrame: Frame, config: RadialProgressConfig?): ClassType
	local self = setmetatable({} :: any, RadialProgress)

	self._parentFrame = parentFrame

	local containerParent = ResolveContainerParent(parentFrame, config and config.ParentToParentFrame)

	self.Container = Instance.new("Frame")
	self.Container.Name = "ProgressContainer"
	self.Container.AnchorPoint = Vector2.new(0.5, 0.5)
	self.Container.Position = UDim2.fromScale(0.5, 0.5)
	self.Container.Size = UDim2.fromScale(1, 1)
	self.Container.BackgroundTransparency = 1
	self.Container.ZIndex = -5
	self.Container.Parent = containerParent

	self.Scale = Instance.new("UIScale")
	self.Scale.Parent = self.Container

	local function createHalf(name: string, clipPos: UDim2, ringPos: UDim2)
		local clip = Instance.new("CanvasGroup")
		clip.Name = name .. "Clip"
		clip.Size = UDim2.fromScale(0.5, 1)
		clip.Position = clipPos
		clip.ClipsDescendants = true
		clip.BackgroundTransparency = 1
		clip.Parent = self.Container

		local ring = Instance.new("Frame")
		ring.Name = name .. "Ring"
		ring.Size = UDim2.fromScale(2, 1)
		ring.Position = ringPos
		ring.BackgroundTransparency = 1
		ring.Parent = clip

		local corner = Instance.new("UICorner")
		corner.Parent = ring

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
		stroke.ZIndex = -5
		stroke.Parent = ring

		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(0.501, 1),
			NumberSequenceKeypoint.new(1, 1)
		})
		gradient.Parent = stroke

		return ring, gradient, corner, stroke
	end

	self.RightRing, self.RightGradient, self.RightCorner, self.RightStroke = createHalf("Right", UDim2.fromScale(0.5, 0), UDim2.fromScale(-1, 0))
	self.LeftRing, self.LeftGradient, self.LeftCorner, self.LeftStroke = createHalf("Left", UDim2.fromScale(0, 0), UDim2.fromScale(0, 0))

	self._tweenTracker = Instance.new("NumberValue")
	self._tweenTracker.Value = 0
	self._tweenConnection = self._tweenTracker.Changed:Connect(function(value)
		self:_updateUI(value)
	end)

	local parentCorner = parentFrame:FindFirstChildOfClass("UICorner")
	self._innerRadius = (parentCorner and parentCorner.CornerRadius) or (config and config.CornerRadius) or UDim.new(0.05, 0)

	self._parentSizeConn = parentFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_RecalculatePadding()
	end)

	self:SetThickness(config and config.Thickness or 0.05)
	self:SetColor(config and config.Color or Color3.fromRGB(255, 255, 255))

	self:SetProgress(0)

	return self
end

-- [[ Private Methods ]] --
function RadialProgress._updateUI(self: ClassType, percent: number)
	percent = math.clamp(percent, 0, 1)

	local rightProgress = math.clamp(percent * 2, 0, 1)
	if rightProgress == 0 then
		self.RightRing.Visible = false
	elseif rightProgress == 1 then
		self.RightRing.Visible = true
		self.RightGradient.Enabled = false
	else
		self.RightRing.Visible = true
		self.RightGradient.Enabled = true
		self.RightGradient.Rotation = rightProgress * 180
	end

	local leftProgress = math.clamp((percent - 0.5) * 2, 0, 1)
	if leftProgress == 0 then
		self.LeftRing.Visible = false
	elseif leftProgress == 1 then
		self.LeftRing.Visible = true
		self.LeftGradient.Enabled = false
	else
		self.LeftRing.Visible = true
		self.LeftGradient.Enabled = true
		self.LeftGradient.Rotation = 180 + (leftProgress * 180)
	end
end

function RadialProgress._ApplyPadding(self: ClassType, padding: number)
	self._padding = padding
	self.Container.Size = UDim2.new(1, padding * 2, 1, padding * 2)
	self:SetCornerRadius(self._innerRadius)
end

function RadialProgress._RecalculatePadding(self: ClassType)
	if not self._thickness then
		return
	end

	local refSize = self._parentFrame.AbsoluteSize
	if refSize.X <= 0 or refSize.Y <= 0 then
		return
	end

	self:_ApplyPadding(self._thickness * math.min(refSize.X, refSize.Y))
end

-- [[ Public Methods ]] --
function RadialProgress.SetProgress(self: ClassType, percent: number)
	if self._activeTween then
		self._activeTween:Cancel()
	end
	self._tweenTracker.Value = percent
end

function RadialProgress.TweenProgress(self: ClassType, targetPercent: number, tweenInfo: TweenInfo)
	if self._activeTween then
		self._activeTween:Cancel()
	end

	self._activeTween = TweenService:Create(self._tweenTracker, tweenInfo, {Value = targetPercent})
	if self._activeTween then
		self._activeTween:Play()
	end

	return self._activeTween
end

function RadialProgress.SetCornerRadius(self: ClassType, udim: UDim)
	self.RightCorner.CornerRadius = udim
	self.LeftCorner.CornerRadius = udim
end

function RadialProgress.SetThickness(self: ClassType, thickness: number)
	self._thickness = thickness

	self.RightStroke.Thickness = thickness
	self.LeftStroke.Thickness = thickness
	self:_RecalculatePadding()
end

function RadialProgress.SetColor(self: ClassType, color: Color3)
	self.RightStroke.Color = color
	self.LeftStroke.Color = color
end

function RadialProgress.Destroy(self: ClassType)
	if self._tweenConnection then
		self._tweenConnection:Disconnect()
	end
	if self._parentSizeConn then
		self._parentSizeConn:Disconnect()
	end
	if self.Container then
		self.Container:Destroy()
	end

	setmetatable(self :: any, nil)
	table.clear(self :: any)
end

return RadialProgress