--|| Services
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

--|| Constants
local LAUNCH_VELOCITY = Vector3.new(0, 100, 50) -- Adjust Y (upward) and Z/X (forward push)
local RECOVERY_TIME = 3.0 -- Seconds the pad stays offline
local COLOR_TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local BouncePad = {}
BouncePad.__index = BouncePad

function BouncePad.new(model: Model)
	local self = setmetatable({}, BouncePad)

	self.Model = model
	self.Hitbox = model:FindFirstChild("Hitbox") :: Part
	self.Pad = model:FindFirstChild("Pad") :: Part
	self.Controller = model:FindFirstChildOfClass("AnimationController") or model:FindFirstChildOfClass("Humanoid")

	self.IdleAnim = model:FindFirstChild("Animations") and model.Animations:FindFirstChild("Idle") :: Animation
	self.LaunchAnim = model:FindFirstChild("Animations") and model.Animations:FindFirstChild("Launch") :: Animation

	self.IsActive = true
	self.OriginalColor = self.Pad.Color
	self.DarkColor = Color3.new(self.OriginalColor.R * 0.3, self.OriginalColor.G * 0.3, self.OriginalColor.B * 0.3)

	self.Animator = self.Controller:FindFirstChildOfClass("Animator") or Instance.new("Animator", self.Controller)

	self.IdleTrack = self.Animator:LoadAnimation(self.IdleAnim)
	self.LaunchTrack = self.Animator:LoadAnimation(self.LaunchAnim)

	self._connections = {} :: {RBXScriptConnection}

	self:Init()
	return self
end

function BouncePad:Init()
	self.IdleTrack.Looped = true
	self.IdleTrack:Play()

	local touchConn = self.Hitbox.Touched:Connect(function(hit)
		if not self.IsActive then return end

		local character = hit.Parent
		local player = Players:GetPlayerFromCharacter(character)

		if player and character:FindFirstChild("HumanoidRootPart") then
			self:TriggerSequence()
		end
	end)
	table.insert(self._connections, touchConn)

	local markerConn = self.LaunchTrack:GetMarkerReachedSignal("Launch"):Connect(function()
		self:ExecuteLaunchForces()
	end)
	table.insert(self._connections, markerConn)

	local stopConn = self.LaunchTrack.Stopped:Connect(function()
		task.wait(RECOVERY_TIME)
		-- Pad may have been destroyed mid-cooldown
		if self.Reset then
			self:Reset()
		end
	end)
	table.insert(self._connections, stopConn)
end

function BouncePad:TriggerSequence()
	self.IsActive = false
	self.LaunchTrack:Play()

	TweenService:Create(self.Pad, COLOR_TWEEN_INFO, {Color = self.DarkColor}):Play()
end

function BouncePad:ExecuteLaunchForces()
	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = {self.Model}
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local partsInHitbox = workspace:GetPartsInPart(self.Hitbox, overlapParams)
	local uniqueCharacters = {}

	for _, part in partsInHitbox do
		local char = part:FindFirstAncestorWhichIsA("Model")
		if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") and not uniqueCharacters[char] then
			uniqueCharacters[char] = true
			local rootPart = char.HumanoidRootPart :: BasePart
			
			local lv = Instance.new("LinearVelocity")
			lv.MaxForce = math.huge
			lv.VectorVelocity = Vector3.new(0, 100, 0)
			lv.Attachment0 = rootPart.RootAttachment
			lv.Parent = rootPart
			game.Debris:AddItem(lv, 0.2)
		end
	end
end

function BouncePad:Reset()
	self.IsActive = true
	self.IdleTrack:Play()
	TweenService:Create(self.Pad, COLOR_TWEEN_INFO, {Color = self.OriginalColor}):Play()
end

function BouncePad:Destroy()
	for _, conn in self._connections do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)

	if self.IdleTrack then self.IdleTrack:Stop() self.IdleTrack:Destroy() end
	if self.LaunchTrack then self.LaunchTrack:Stop() self.LaunchTrack:Destroy() end

	self.Model = nil
	self.Hitbox = nil
	self.Pad = nil
	self.Animator = nil

	setmetatable(self, nil)
end

return BouncePad