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

local consists : {Engine.Entity : Consist} = {}

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
		local land = model.metadata["landVehicle"] as ModelMetadata.LandVehicle
		local extent = model.metadata["extent"] as Extent
		result.emptyKgs[#result.emptyKgs + 1] = land ~= nil and land.weightEmpty or 0
		if extent ~= nil then
			result.length = result.length + (extent.bbMax.x - extent.bbMin.x)
		end
	end
	consists[entity] = result
	return result
end

local function cargoLoads(tv : Engine.Component.TransportVehicle, entity : Engine.Entity) : {PgraceTrainGradeWeight.CargoLoad}
	local loads : {PgraceTrainGradeWeight.CargoLoad} = {}
	for i, capacity in ipairs(tv.config.capacities) do
		if capacity > 0 then
			local cargo : CargoTypeId = i - 1
			local count = api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(entity, cargo)
			if count > 0 then
				loads[#loads + 1] = { count = count, unitWeight = api.res.cargoTypeRep.get(cargo).weight }
			end
		end
	end
	return loads
end

-- Track or lane segments from the front edge backwards, enough to cover the vehicle.
local function segmentsBehind(movePath : Engine.Component.MovePath, vehicleLength : number) : {Segment}, {string}
	local segments : {Segment} = {}
	local flags : {string} = {}   -- PROBE (remove before release)
	local networks : {Engine.Entity : Engine.Component.TransportNetwork} = {}
	local front = movePath.dyn.pathPos.edgeIndex + 1   -- edgeIndex is zero-based
	local collected = 0.0
	local i = front
	while i >= 1 do
		local pair = movePath.path.edges[i]
		local edgeId = pair[1] as EdgeId
		local forward = pair[2] as boolean
		if not api.engine.entityExists(edgeId.entity) then
			break
		end
		local network = networks[edgeId.entity]
		if network == nil then
			network = api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			networks[edgeId.entity] = network
		end
		local edge = network.edges[edgeId.index + 1]   -- index is zero-based
		local geometry = edge.geometry
		segments[#segments + 1] = {
			length = geometry.length,
			heightAt = function(t : number) : number
				return api.engine.util.transport.calcPosition(geometry, t).z
			end,
			reversed = not forward,
		}
		flags[#flags + 1] = forward and "F" or "R"   -- PROBE (remove before release)
		collected = collected + geometry.length
		-- the front segment only partly lies behind the front, so keep one extra segment's worth
		if collected >= vehicleLength + segments[1].length then
			break
		end
		i = i - 1
	end
	return segments, flags
end

local probeCounter = 0   -- PROBE (remove before release)

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
	local segments : {Segment} = {}
	local flags : {string} = {}
	if movePath ~= nil and #movePath.path.edges > 0 then
		segments, flags = segmentsBehind(movePath, consist.length)
		g = grade.averageGrade(segments, movePath.dyn.pathPos.pos01, consist.length)
	end

	-- PROBE (remove before release): about once a second per open window (polled every 0.25 s)
	probeCounter = probeCounter + 1
	if probeCounter % 4 == 0 then
		local loadText : {string} = {}
		for _, load in ipairs(loads) do
			loadText[#loadText + 1] = tostring(load.count) .. "x" .. tostring(load.unitWeight)
		end
		local zFront : number = nil
		if #segments > 0 and movePath ~= nil then
			zFront = segments[1].heightAt(movePath.dyn.pathPos.pos01)
		end
		debugPrint(LOG_PREFIX .. "probe entity=" .. tostring(entity)
			.. " edgeIndex=" .. tostring(movePath and movePath.dyn.pathPos.edgeIndex)
			.. " pos01=" .. tostring(movePath and movePath.dyn.pathPos.pos01)
			.. " occupiedBack=" .. tostring(movePath and movePath.occupiedBackIndex)
			.. " occupiedFront=" .. tostring(movePath and movePath.occupiedFrontIndex)
			.. " edges=" .. tostring(movePath and #movePath.path.edges)
			.. " reverse=" .. tostring(movePath and movePath.reverse)
			.. " walked=" .. table.concat(flags, "")
			.. " zFront=" .. tostring(zFront)
			.. " length=" .. tostring(consist.length)
			.. " grade=" .. tostring(g)
			.. " loads=" .. table.concat(loadText, ",")
			.. " empty=" .. tostring(w.empty) .. " cargo=" .. tostring(w.cargo) .. " gross=" .. tostring(w.gross))
	end

	return { weight = w, grade = g }
end

return vehicle_data
