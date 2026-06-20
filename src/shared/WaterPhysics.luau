--!strict
--[[
	WaterPhysics — legacy swimming. Per Heartbeat it looks up the character's cell
	in the voxel buffer (no physics query); when it's water it applies a buoyancy
	VectorForce (near-neutral so the player can swim with normal movement) plus a
	flow force decoded from the cell's force/direction bits, and puts the Humanoid
	in the Swimming state. Out of water the force is cleared.
]]

local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local WaterRender = require(script.Parent.WaterRender)

local CELL = Constants.CELL
local WATER = Constants.Material.Water

-- Water byte1: bits 0-2 = flow force, bits 3-5 = flow direction (legacy SetWaterCell). Indexed by the
-- legacy Enum.WaterDirection value (NegX=0, X=1, NegY=2, Y=3, NegZ=4, Z=5). See Constants.unpackWater.
local FLOW_DIR = {
	[0] = Vector3.new(-1, 0, 0), -- NegX
	[1] = Vector3.new(1, 0, 0), -- X
	[2] = Vector3.new(0, -1, 0), -- NegY
	[3] = Vector3.new(0, 1, 0), -- Y
	[4] = Vector3.new(0, 0, -1), -- NegZ
	[5] = Vector3.new(0, 0, 1), -- Z
}

local WaterPhysics = {}

-- Horizontal drag coefficient: water resists swim velocity so movement feels heavy
-- (force = -horizontalVelocity * mass * DRAG). Vertical bob has its own damping.
WaterPhysics.DRAG = 2.5

-- Buoyant lift: a constant UPWARD acceleration (studs/s^2) applied ON TOP of
-- cancelling gravity, so a swimmer rises to the surface instead of sinking. It is
-- applied as force = mass * (g + LIFT); because force scales with mass, the
-- resulting acceleration -- and therefore the float behaviour -- is identical for
-- every avatar regardless of weight. VDRAG damps the vertical bob; terminal rise
-- speed settles around LIFT / VDRAG studs/s.
WaterPhysics.LIFT = 12.0
WaterPhysics.VDRAG = 2.0

-- Attaches swimming to a character against `store`. Returns a cleanup function. --
function WaterPhysics.attach(store, character: Model): () -> ()
	local hrp = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not hrp or not humanoid then
		return function() end
	end

	local att = Instance.new("Attachment")
	att.Name = "WaterBuoyancy"
	att.Parent = hrp
	local vf = Instance.new("VectorForce")
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.zero
	vf.Parent = hrp

	-- Toggle swim lock only on the enter/exit transition (not every frame).
	-- Disabling GettingUp stops Roblox's state machine from auto-standing the
	-- humanoid out of the swim state; re-enabling on exit restores locomotion.
	local inWater = false
	local function setInWater(state: boolean)
		if state == inWater then
			return
		end
		inWater = state
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, not state)
		if state then
			humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
		end
	end

	local conn = RunService.Heartbeat:Connect(function()
		if not hrp.Parent or humanoid.Health <= 0 then
			setInWater(false)
			vf.Force = Vector3.zero
			return
		end
		local p = hrp.Position
		local cellX, cellY, cellZ = math.floor(p.X / CELL), math.floor(p.Y / CELL), math.floor(p.Z / CELL)
		local mat, byte1 = store:getCell(cellX, cellY, cellZ)
		-- Swim in ACTUAL water and in RENDERED water (waterlogged shoreline slopes): 4-stud
		-- cells are large enough to otherwise stand out of swim mode underwater on a slope.
		-- The waterlog check is data-driven (rendered-water mask), never a part collision.
		local inRenderedWater = mat == WATER or WaterRender.isRenderedWater(cellX, cellY, cellZ)
		if inRenderedWater then
			local mass = hrp.AssemblyMass
			local g = workspace.Gravity
			local vel = hrp.AssemblyLinearVelocity
			-- buoyant lift (mass-scaled): cancel gravity + a constant upward accel so you float up, never sink; vertical drag damps the bob
			local up = mass * (g + WaterPhysics.LIFT) - vel.Y * mass * WaterPhysics.VDRAG
			-- horizontal drag: water resists swim velocity (heavier-feeling movement)
			local dragX = -vel.X * mass * WaterPhysics.DRAG
			local dragZ = -vel.Z * mass * WaterPhysics.DRAG
			-- flow only from real water cells (a slope's byte1 holds shape bits, not flow)
			local flow = Vector3.zero
			if mat == WATER then
				local force, dir = Constants.unpackWater(byte1)
				flow = (FLOW_DIR[dir] or Vector3.zero) * (force * mass * 3)
			end
			vf.Force = Vector3.new(flow.X + dragX, up + flow.Y, flow.Z + dragZ)
			setInWater(true)
			if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
				humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
			end
		else
			vf.Force = Vector3.zero
			setInWater(false)
		end
	end)

	-- Never leave GettingUp disabled on a dead character (respawn must be normal).
	local diedConn = humanoid.Died:Connect(function()
		setInWater(false)
	end)

	return function()
		conn:Disconnect()
		diedConn:Disconnect()
		setInWater(false) -- restore GettingUp on teardown
		vf:Destroy()
		att:Destroy()
	end
end

return WaterPhysics
