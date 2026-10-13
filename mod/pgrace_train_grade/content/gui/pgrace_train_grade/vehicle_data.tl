local grade = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/grade.tl" as PgraceTrainGradeGrade
local weight = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/weight.tl" as PgraceTrainGradeWeight

local vehicle_data : PgraceTrainGradeVehicleData = {}

local LOG_PREFIX = "[train_grade] "

-- Trains, trams, buses and trucks; not ships or aircraft.
local LAND_CARRIERS : {Carrier : boolean} = {
	[api.type["enum"].Carrier.RAIL] = true,
	[api.type["enum"].Carrier.TRAM] = true,
	[api.type["enum"].Carrier.ROAD] = true,
}

local type Segment = PgraceTrainGradeGrade.Segment

-- Per-consist data from the vehicle models, cached by the list of part model ids.
local record Consist
	key : string
	emptyKgs : {number}
	length : number
end

-- Intentionally never pruned: one small entry per vehicle viewed.
local consists : {Engine.Entity : Consist} = {}

local gradeErrorLogged : {Engine.Entity : boolean} = {}

local function consistOf(tv : Engine.Component.TransportVehicle, entity : Engine.Entity) : Consist
	local ids : {string} = {}
	for _, part in ipairs(tv.transportVehicleConfig.vehicles) do
		ids[#ids + 1] = tostring(part.part.modelId)
	end
	local key = table.concat(ids, ",")
	local cached = consists[entity]
	if cached ~= nil and cached.key == key then
		return cached
	end
	local result : Consist = { key = key, emptyKgs = {}, length = 0 }
	for _, part in ipairs(tv.transportVehicleConfig.vehicles) do
		local model = api.res.modelRep.get(part.part.modelId)
		local emptyKg = 0.0
		if model ~= nil then
			local land = model.metadata["landVehicle"] as ModelMetadata.LandVehicle
			local extent = model.metadata["extent"] as Extent
			emptyKg = land ~= nil and land.weightEmpty or 0
			if extent ~= nil then
				result.length = result.length + (extent.bbMax.x - extent.bbMin.x)
			end
		end
		result.emptyKgs[#result.emptyKgs + 1] = emptyKg
	end
	consists[entity] = result
	return result
end

-- The cargo files set `weightFactor` (coal 1.0, passengers 1/6), taken as tons per unit; the tealdef's `weight`
-- reads nil in-game. Neither may exist on every cargo, so both reads are guarded; unknown counts as 0 kg.
local record CargoWeightFields
	weightFactor : number
	weight : number
end

local KG_PER_TON = 1000
local unitKgs : {CargoTypeId : number} = {}

local function readField(ct : CargoWeightFields, field : string) : number
	local ok, value = pcall(function() : number
		if field == "weightFactor" then
			return ct.weightFactor
		end
		return ct.weight
	end)
	if ok then
		return value as number
	end
	return nil
end

local function unitKg(cargo : CargoTypeId) : number
	local cached = unitKgs[cargo]
	if cached ~= nil then
		return cached
	end
	local ct = api.res.cargoTypeRep.get(cargo) as any as CargoWeightFields
	local factor : number = nil
	local plain : number = nil
	if ct ~= nil then
		factor = readField(ct, "weightFactor")
		plain = readField(ct, "weight")
	end
	local kg = 0.0
	if factor ~= nil then
		kg = factor * KG_PER_TON
	elseif plain ~= nil then
		kg = plain * KG_PER_TON
	end
	unitKgs[cargo] = kg
	return kg
end

local function cargoLoads(tv : Engine.Component.TransportVehicle, entity : Engine.Entity) : {PgraceTrainGradeWeight.CargoLoad}
	local loads : {PgraceTrainGradeWeight.CargoLoad} = {}
	for i, capacity in ipairs(tv.config.capacities) do
		if capacity > 0 then
			local cargo : CargoTypeId = i - 1
			local count = api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(entity, cargo)
			if count > 0 then
				loads[#loads + 1] = { count = count, unitWeight = unitKg(cargo) }
			end
		end
	end
	return loads
end

-- In-game, path entries are EdgeIdDir userdata (`.edgeId`, `.dir`), not the `{EdgeId, boolean}` pairs the tealdef
-- declares. Accept both.
local record EdgeIdDirFields
	edgeId : EdgeId
	dir : boolean
end

local function edgeOf(entry : any) : EdgeId, boolean
	if type(entry) == "table" then
		local pair = entry as {any}
		return pair[1] as EdgeId, pair[2] as boolean
	end
	local fields = entry as EdgeIdDirFields
	return fields.edgeId, fields.dir
end

-- Track or lane segments from the front edge backwards, enough to cover the vehicle.
-- pathPos.pos01 runs in the direction of travel (verified in-game), so on a reversed edge the edge's own parameter
-- is 1 - pos01.
local function frontParam(segments : {Segment}, pos01 : number) : number
	if #segments > 0 and segments[1].reversed then
		return 1 - pos01
	end
	return pos01
end

local function segmentsBehind(movePath : Engine.Component.MovePath, vehicleLength : number) : {Segment}
	local segments : {Segment} = {}
	local networks : {Engine.Entity : Engine.Component.TransportNetwork} = {}
	local front = movePath.dyn.pathPos.edgeIndex + 1   -- edgeIndex is zero-based
	local collected = 0.0
	local i = front
	while i >= 1 do
		local entry = movePath.path.edges[i]
		if entry == nil then
			break
		end
		local edgeId, forward = edgeOf(entry)
		if edgeId == nil or not api.engine.entityExists(edgeId.entity) then
			break
		end
		local network = networks[edgeId.entity]
		if network == nil then
			network = api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			networks[edgeId.entity] = network
		end
		if network == nil then
			break
		end
		local edge = network.edges[edgeId.index + 1]   -- index is zero-based
		if edge == nil then
			break
		end
		local geometry = edge.geometry
		segments[#segments + 1] = {
			length = geometry.length,
			heightAt = function(t : number) : number
				return api.engine.util.transport.calcPosition(geometry, t).z
			end,
			reversed = not forward,
		}
		collected = collected + geometry.length
		-- the front segment only partly lies behind the front, so keep one extra segment's worth
		if collected >= vehicleLength + segments[1].length then
			break
		end
		i = i - 1
	end
	return segments
end

function vehicle_data.read(entity : Engine.Entity) : PgraceTrainGradeVehicleData.Reading
	local tv = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
	if tv == nil or not LAND_CARRIERS[tv.carrier] then
		return nil
	end
	if tv.state == api.type["enum"].TransportVehicleState.AT_TERMINAL then
		return nil
	end

	local consist = consistOf(tv, entity)
	local loads = cargoLoads(tv, entity)
	local w = weight.sum(consist.emptyKgs, loads)

	local g : number = nil
	local movePath = api.engine.getComponent(entity, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
	if movePath ~= nil and #movePath.path.edges > 0 then
		-- a failed grade read must not hide the weight
		local ok, res = pcall(function() : number
			local segments = segmentsBehind(movePath, consist.length)
			return grade.averageGrade(segments, frontParam(segments, movePath.dyn.pathPos.pos01), consist.length)
		end)
		if ok then
			g = res as number
		elseif not gradeErrorLogged[entity] then
			gradeErrorLogged[entity] = true
			debugPrint(LOG_PREFIX .. "grade failed for " .. tostring(entity) .. ": " .. tostring(res))
		end
	end

	return { weight = w, grade = g }
end

return vehicle_data
