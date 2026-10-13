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
	payloadMaxKg : number   -- PROBE (remove before release)
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
	local result : Consist = { key = key, emptyKgs = {}, length = 0, payloadMaxKg = 0 }   -- PROBE (remove before release)
	for _, part in ipairs(tv.transportVehicleConfig.vehicles) do
		local model = api.res.modelRep.get(part.part.modelId)
		local emptyKg = 0.0
		if model ~= nil then
			local land = model.metadata["landVehicle"] as ModelMetadata.LandVehicle
			local extent = model.metadata["extent"] as Extent
			emptyKg = land ~= nil and land.weightEmpty or 0
			if land ~= nil and land.weightMaxPayload ~= nil then   -- PROBE (remove before release)
				result.payloadMaxKg = result.payloadMaxKg + land.weightMaxPayload   -- PROBE (remove before release)
			end   -- PROBE (remove before release)
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
local cargoLogged : {CargoTypeId : boolean} = {}   -- PROBE (remove before release)

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
	if not cargoLogged[cargo] then   -- PROBE (remove before release)
		cargoLogged[cargo] = true   -- PROBE (remove before release)
		debugPrint(LOG_PREFIX .. "probe cargo=" .. tostring(cargo) .. " weightFactor=" .. tostring(factor) .. " weight=" .. tostring(plain))   -- PROBE (remove before release)
	end   -- PROBE (remove before release)
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

local lastWalk : {string} = {}   -- PROBE (remove before release)

local function segmentsBehind(movePath : Engine.Component.MovePath, vehicleLength : number) : {Segment}, {string}
	lastWalk = {}   -- PROBE (remove before release)
	local segments : {Segment} = {}
	local flags : {string} = {}   -- PROBE (remove before release)
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
		flags[#flags + 1] = forward and "F" or "R"   -- PROBE (remove before release)
		local z0, z1 = "?", "?"   -- PROBE (remove before release)
		local ok0, v0 = pcall(function() : number return api.engine.util.transport.calcPosition(geometry, 0).z end)   -- PROBE (remove before release)
		local ok1, v1 = pcall(function() : number return api.engine.util.transport.calcPosition(geometry, 1).z end)   -- PROBE (remove before release)
		if ok0 then z0 = string.format("%.2f", v0 as number) end   -- PROBE (remove before release)
		if ok1 then z1 = string.format("%.2f", v1 as number) end   -- PROBE (remove before release)
		lastWalk[#lastWalk + 1] = tostring(edgeId.entity) .. ":" .. tostring(edgeId.index)   -- PROBE (remove before release)
			.. (forward and " F" or " R") .. " len=" .. string.format("%.1f", geometry.length)   -- PROBE (remove before release)
			.. " z0=" .. z0 .. " z1=" .. z1   -- PROBE (remove before release)
		collected = collected + geometry.length
		-- the front segment only partly lies behind the front, so keep one extra segment's worth
		if collected >= vehicleLength + segments[1].length then
			break
		end
		i = i - 1
	end
	return segments, flags
end

local probeCounts : {Engine.Entity : integer} = {}   -- PROBE (remove before release)

local probeSeen : {Engine.Entity : boolean} = {}   -- PROBE (remove before release)

function vehicle_data.read(entity : Engine.Entity) : PgraceTrainGradeVehicleData.Reading
	local tv = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
	if not probeSeen[entity] then   -- PROBE (remove before release)
		probeSeen[entity] = true   -- PROBE (remove before release)
		debugPrint(LOG_PREFIX .. "probe read entity=" .. tostring(entity) .. " tv=" .. tostring(tv ~= nil)   -- PROBE (remove before release)
			.. " carrier=" .. tostring(tv and tv.carrier) .. " (" .. type(tv and tv.carrier) .. ")"   -- PROBE (remove before release)
			.. " rail=" .. tostring(api.type["enum"].Carrier.RAIL) .. " (" .. type(api.type["enum"].Carrier.RAIL) .. ")"   -- PROBE (remove before release)
			.. " inSet=" .. tostring(tv ~= nil and LAND_CARRIERS[tv.carrier] == true)   -- PROBE (remove before release)
			.. " state=" .. tostring(tv and tv.state))   -- PROBE (remove before release)
	end   -- PROBE (remove before release)
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
		-- a failed grade read must not hide the weight
		local ok, res = pcall(function() : number
			segments, flags = segmentsBehind(movePath, consist.length)
			return grade.averageGrade(segments, frontParam(segments, movePath.dyn.pathPos.pos01), consist.length)
		end)
		if ok then
			g = res as number
		elseif not gradeErrorLogged[entity] then
			gradeErrorLogged[entity] = true
			debugPrint(LOG_PREFIX .. "grade failed for " .. tostring(entity) .. ": " .. tostring(res))
		end
	end

	-- PROBE (remove before release): about once a second per open window (polled every 0.25 s)
	local n = (probeCounts[entity] or 0) + 1   -- PROBE (remove before release)
	probeCounts[entity] = n   -- PROBE (remove before release)
	if n % 4 == 0 then   -- PROBE (remove before release)
		local loadText : {string} = {}
		for _, load in ipairs(loads) do
			loadText[#loadText + 1] = tostring(load.count) .. "x" .. tostring(load.unitWeight)
		end
		local zFront : number = nil   -- PROBE (remove before release)
		if #segments > 0 and movePath ~= nil then   -- PROBE (remove before release)
			local zOk, zRes = pcall(function() : number   -- PROBE (remove before release)
				return segments[1].heightAt(frontParam(segments, movePath.dyn.pathPos.pos01))   -- PROBE (remove before release)
			end)   -- PROBE (remove before release)
			if zOk then   -- PROBE (remove before release)
				zFront = zRes as number   -- PROBE (remove before release)
			end   -- PROBE (remove before release)
		end   -- PROBE (remove before release)
		local pos : number = nil   -- PROBE (remove before release)
		local edgeType : string = nil   -- PROBE (remove before release)
		if movePath ~= nil then   -- PROBE (remove before release)
			local pOk, pRes = pcall(function() : number   -- PROBE (remove before release)
				return movePath.dyn.pathPos.pos   -- PROBE (remove before release)
			end)   -- PROBE (remove before release)
			if pOk then   -- PROBE (remove before release)
				pos = pRes as number   -- PROBE (remove before release)
			end   -- PROBE (remove before release)
			local eOk, eRes = pcall(function() : string   -- PROBE (remove before release)
				if #movePath.path.edges > 0 then   -- PROBE (remove before release)
					return type(movePath.path.edges[1])   -- PROBE (remove before release)
				end   -- PROBE (remove before release)
				return "none"   -- PROBE (remove before release)
			end)   -- PROBE (remove before release)
			if eOk then   -- PROBE (remove before release)
				edgeType = eRes as string   -- PROBE (remove before release)
			end   -- PROBE (remove before release)
		end   -- PROBE (remove before release)
		local frontLen : number = nil   -- PROBE (remove before release)
		if #segments > 0 then   -- PROBE (remove before release)
			frontLen = segments[1].length   -- PROBE (remove before release)
		end   -- PROBE (remove before release)
		debugPrint(LOG_PREFIX .. "probe entity=" .. tostring(entity)
			.. " name=" .. tostring(api.engine.util.getEntityName(entity))   -- PROBE (remove before release)
			.. " carrier=" .. tostring(tv.carrier)   -- PROBE (remove before release)
			.. " state=" .. tostring(tv.state)   -- PROBE (remove before release)
			.. " edgeIndex=" .. tostring(movePath and movePath.dyn.pathPos.edgeIndex)
			.. " pos01=" .. tostring(movePath and movePath.dyn.pathPos.pos01)
			.. " pos=" .. tostring(pos)   -- PROBE (remove before release)
			.. " frontLen=" .. tostring(frontLen)   -- PROBE (remove before release)
			.. " occupiedBack=" .. tostring(movePath and movePath.occupiedBackIndex)
			.. " occupiedFront=" .. tostring(movePath and movePath.occupiedFrontIndex)
			.. " edges=" .. tostring(movePath and #movePath.path.edges)
			.. " edgeType=" .. tostring(edgeType)   -- PROBE (remove before release)
			.. " reverse=" .. tostring(movePath and movePath.reverse)
			.. " walked=" .. table.concat(flags, "")
			.. " zFront=" .. tostring(zFront)
			.. " length=" .. tostring(consist.length)
			.. " payloadMax=" .. tostring(consist.payloadMaxKg)   -- PROBE (remove before release)
			.. " grade=" .. tostring(g)
			.. " loads=" .. table.concat(loadText, ",")
			.. " empty=" .. tostring(w.empty) .. " cargo=" .. tostring(w.cargo) .. " gross=" .. tostring(w.gross))
		if g ~= nil and math.abs(g) > 0.15 then   -- PROBE (remove before release)
			debugPrint(LOG_PREFIX .. "probe spike entity=" .. tostring(entity) .. " grade=" .. tostring(g)   -- PROBE (remove before release)
				.. " walk: " .. table.concat(lastWalk, " | "))   -- PROBE (remove before release)
		end   -- PROBE (remove before release)
	end

	return { weight = w, grade = g }
end

return vehicle_data
