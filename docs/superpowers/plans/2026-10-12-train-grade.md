# Train Grade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a train's vehicle window, show the gross weight (with an empty/cargo tooltip) and the average grade over
the train's length as two pills before the speed in the camera strip.

**Architecture:** A `react-replacement-config` replaces the base `entity_window_util.SpeedIndicator` with our recipe,
which renders `[weight pill] [grade pill]` followed by `react.CallOriginalRecipe(SpeedIndicator, entityId)`. The pills
hide (style class `invisible`) unless the entity is a rail vehicle that isn't at a terminal. Pure logic (grade
walk, weight sums, text and icon choice) lives in unit-tested modules; `train_data.tl` does every `api.*` read.

**Tech Stack:** Teal 0.24.8 (type-checked against the TF3 tealdefs), plain Lua 5.4 tests (`tools/test.lua`), `just`.

**Spec:** `docs/superpowers/specs/2026-10-12-train-grade-design.md`

---

## Background for the implementer

- Read `../AGENTS.md` (the kit notes) first, especially *Teal gotchas*, *Dev loop* and the rule that **a recipe must
  return a layout**.
- Each module has a canonical type file at `mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/<name>.d.tl`,
  registered in `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl`. `just check` mirrors these into
  `content/` (never edit the copies) and rewrites `_content.json`.
- Tests load a module with `t.requireTl("gui/pgrace_train_grade/<file>.tl")`; helpers are `t.test(name, fn)` and
  `t.eq(actual, expected, label)`. The runner fails if zero tests pass.
- Game paths: the TF3 install is `/run/host/var/Fun/SteamLibrary/steamapps/common/Transport Fever 3`. Base GUI source
  for reference: `gui/gui/entity_window/entity_window_util.tl` (the `SpeedIndicator` recipe, about line 2299) and
  `gui/gui/entity_window/entity_window.css.lua` (its styles, about line 872), inside `base/content/gui.zip`.
- Heights: `t` along an edge is treated as proportional to distance. Fine for a grade readout.
- The agent can't run the game. Tasks 1–5 end with `just verify` passing; Task 6 is the user's in-game session.

## File map

| File | Responsibility |
| --- | --- |
| `tealdef/gui/pgrace_train_grade/grade.d.tl` + `content/.../grade.tl` | Pure: average grade over a path span, grade text, grade icon |
| `tealdef/gui/pgrace_train_grade/weight.d.tl` + `content/.../weight.tl` | Pure: weight sums in tons |
| `tealdef/gui/pgrace_train_grade/train_data.d.tl` + `content/.../train_data.tl` | All `api.*` reads; returns a `Reading` or nil |
| `content/.../speed_strip.script.tl` | Replacement recipe, pill recipe, `doReplace` |
| `content/.../speed_strip_replacement.res.lua` | Registers the replacement config |
| `content/.../speed_strip.css.lua` | Pill styles, copied from the base `R::SpeedIndicator` rules |
| `tests/grade_test.lua`, `tests/weight_test.lua` | Unit tests |
| removed: `industry_plugin.res.lua`, `pgrace_train_grade.script.tl`, `util.*`, `tests/util_test.lua` | Template sample |

All `content/...` paths are `mod/pgrace_train_grade/content/gui/pgrace_train_grade/`.

---

### Task 0: Feature branch

- [ ] **Step 1: Branch**

```bash
cd /home/pgrace/repos/tf3_mods/tf3_train_grade
git checkout -b feat/weight-and-grade
```

(The staging-area symlink points at this checkout, so no repointing is needed. Don't use a worktree.)

---

### Task 1: `grade.tl`, the average grade walk

**Files:**
- Create: `mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/grade.d.tl`
- Modify: `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl`
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/grade.tl`
- Test: `tests/grade_test.lua`

- [ ] **Step 1: Write the type file**

`mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/grade.d.tl`:

```teal
-- Pure grade maths (no api.* calls), so tests/grade_test.lua can run it in plain Lua.
global record PgraceTrainGradeGrade
	-- One track edge the train covers. t runs 0..1 in the edge's own direction.
	record Segment
		-- metres along the track
		length : number
		-- world height at t
		heightAt : function(t : number) : number
		-- true when the train travels from t = 1 towards t = 0
		reversed : boolean
	end

	-- Average grade (rise / distance, 0.02 = 2%) over the trainLength metres behind the front, signed in the direction
	-- of travel. segments[1] holds the front, at frontT; later segments lie further behind. If the segments run out,
	-- uses the distance they cover. nil if that's under 1 m.
	averageGrade : function(segments : {Segment}, frontT : number, trainLength : number) : number

	-- "+1.8%", "-0.4%"; "0.0%" inside +-0.05%; "—" for nil.
	formatGrade : function(grade : number) : string

	-- The track builder's slope arrow for a grade: flat, gentle (under 2%) or steep, up or down.
	iconFor : function(grade : number) : string
end
```

- [ ] **Step 2: Register it**

Replace the contents of `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl` with:

```teal
require "gui.pgrace_train_grade.util"
require "gui.pgrace_train_grade.grade"
```

(`util` goes in Task 3.)

- [ ] **Step 3: Write the failing tests**

`tests/grade_test.lua`:

```lua
local t = ...
local grade = t.requireTl("gui/pgrace_train_grade/grade.tl")

-- A straight edge rising `rise` metres over `length` metres, starting at height z0.
local function edge(length, z0, rise, reversed)
	return {
		length = length,
		heightAt = function(u) return z0 + rise * u end,
		reversed = reversed or false,
	}
end

local function near(actual, expected, label)
	if actual == nil or math.abs(actual - expected) > 1e-9 then
		error(("%s: expected %s, got %s"):format(label or "near", tostring(expected), tostring(actual)), 2)
	end
end

t.test("averageGrade: flat track is 0", function()
	near(grade.averageGrade({ edge(500, 10, 0) }, 0.8, 200), 0)
end)

t.test("averageGrade: constant 2% on one edge", function()
	-- front at 400 m into a 500 m edge rising 10 m; the train covers 200..400 m
	near(grade.averageGrade({ edge(500, 0, 10) }, 0.8, 200), 0.02)
end)

t.test("averageGrade: constant 2% across three edges", function()
	local segments = {
		edge(100, 4, 2),   -- front edge, 4 m..6 m; front at t = 0.5 (z = 5)
		edge(100, 2, 2),
		edge(100, 0, 2),
	}
	-- 50 m on the front edge, 100 m on the next, 50 m on the last: 200 m, back at z = 1
	near(grade.averageGrade(segments, 0.5, 200), 0.02)
end)

t.test("averageGrade: a crest split evenly averages about 0", function()
	local segments = {
		edge(100, 2, -2),  -- front edge going down from the crest (z 2 -> 0)
		edge(100, 0, 2),   -- the edge behind, climbing to the crest (z 0 -> 2)
	}
	-- front at the bottom of the descent (t = 1, z = 0), back at the start of the climb (z = 0)
	near(grade.averageGrade(segments, 1.0, 200), 0)
end)

t.test("averageGrade: a reversed edge flips the sign", function()
	-- The edge rises 10 m over 500 m in its own direction; travelling it backwards is a 2% descent.
	-- Front at t = 0.2 (100 m into the edge, so 400 m of it lie behind the front).
	near(grade.averageGrade({ edge(500, 0, 10, true) }, 0.2, 200), -0.02)
end)

t.test("averageGrade: a path shorter than the train uses what it covers", function()
	-- front at t = 0.5 of a 100 m edge rising 2 m: only 50 m behind the front, 1 m of rise
	near(grade.averageGrade({ edge(100, 0, 2) }, 0.5, 300), 0.02)
end)

t.test("averageGrade: under 1 m covered is nil", function()
	t.eq(grade.averageGrade({ edge(100, 0, 2) }, 0.005, 300), nil)
	t.eq(grade.averageGrade({}, 0.5, 300), nil)
end)

t.test("formatGrade: signs, rounding, dead band, nil", function()
	t.eq(grade.formatGrade(0.018), "+1.8%")
	t.eq(grade.formatGrade(-0.004), "-0.4%")
	t.eq(grade.formatGrade(0.0004), "0.0%")
	t.eq(grade.formatGrade(-0.0004), "0.0%")
	t.eq(grade.formatGrade(0.03456), "+3.5%")
	t.eq(grade.formatGrade(nil), "—")
end)

t.test("iconFor: flat, gentle, steep, both ways", function()
	local base = "::/gui/construction/build_control/symbol_slope_"
	t.eq(grade.iconFor(nil), base .. "0_20.tga")
	t.eq(grade.iconFor(0.0004), base .. "0_20.tga")
	t.eq(grade.iconFor(0.01), base .. "1_20.tga")
	t.eq(grade.iconFor(0.025), base .. "2_20.tga")
	t.eq(grade.iconFor(-0.01), base .. "-1_20.tga")
	t.eq(grade.iconFor(-0.025), base .. "-2_20.tga")
end)
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `just test`
Expected: FAIL. The new tests error with something like `cannot open .../grade.tl` (the module doesn't exist yet);
the template's `util` tests still pass.

- [ ] **Step 5: Implement**

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/grade.tl`:

```teal
local grade : PgraceTrainGradeGrade = {}

local type Segment = PgraceTrainGradeGrade.Segment

local FLAT = 0.0005   -- |grade| below this shows as 0.0%
local STEEP = 0.02    -- 2% and up gets the steep arrow
local ICON_BASE = "::/gui/construction/build_control/symbol_slope_"

function grade.averageGrade(segments : {Segment}, frontT : number, trainLength : number) : number
	if #segments == 0 then
		return nil
	end
	local zFront = segments[1].heightAt(frontT)
	local remaining = trainLength
	local covered = 0.0
	local zBack = zFront
	for i, seg in ipairs(segments) do
		-- the travel-wise end of this segment's part behind the front, in t
		local tEnd : number
		if i == 1 then
			tEnd = frontT
		elseif seg.reversed then
			tEnd = 0.0
		else
			tEnd = 1.0
		end
		-- metres of this segment behind tEnd (walking against the direction of travel)
		local available : number
		if seg.reversed then
			available = (1.0 - tEnd) * seg.length
		else
			available = tEnd * seg.length
		end
		local step = math.min(available, remaining)
		local tBack : number
		if seg.length <= 0 then
			tBack = tEnd
		elseif seg.reversed then
			tBack = tEnd + step / seg.length
		else
			tBack = tEnd - step / seg.length
		end
		zBack = seg.heightAt(tBack)
		covered = covered + step
		remaining = remaining - step
		if remaining <= 0 then
			break
		end
	end
	if covered < 1.0 then
		return nil
	end
	return (zFront - zBack) / covered
end

function grade.formatGrade(g : number) : string
	if g == nil then
		return "—"
	end
	if math.abs(g) < FLAT then
		return "0.0%"
	end
	return string.format("%+.1f%%", g * 100)
end

function grade.iconFor(g : number) : string
	local level = 0
	if g ~= nil and math.abs(g) >= FLAT then
		level = math.abs(g) >= STEEP and 2 or 1
		if g < 0 then
			level = -level
		end
	end
	return ICON_BASE .. tostring(level) .. "_20.tga"
end

return grade
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `just test`
Expected: all `grade` tests PASS, and the summary reads `11 passed, 0 failed` (9 grade tests and 2 util tests).

- [ ] **Step 7: Type-check**

Run: `just check`
Expected: `0 error(s)`.

- [ ] **Step 8: Commit**

```bash
git add tests/grade_test.lua mod/pgrace_train_grade/tealdef mod/pgrace_train_grade/content/gui/pgrace_train_grade/grade.tl mod/pgrace_train_grade/content/gui/pgrace_train_grade/grade.d.tl mod/pgrace_train_grade/_content.json
git commit -m "feat: average grade over a path span"
```

---

### Task 2: `weight.tl`, weight sums

**Files:**
- Create: `mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/weight.d.tl`
- Modify: `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl`
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/weight.tl`
- Test: `tests/weight_test.lua`

- [ ] **Step 1: Write the type file**

`mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/weight.d.tl`:

```teal
-- Pure weight sums (no api.* calls), so tests/weight_test.lua can run them in plain Lua.
global record PgraceTrainGradeWeight
	-- One cargo type on board.
	record CargoLoad
		count : integer
		-- kg per unit (CargoType.weight; unit confirmed by the probe)
		unitWeight : number
	end

	-- Tons.
	record Weight
		gross : number
		empty : number
		cargo : number
	end

	-- emptyKgs: each vehicle part's empty weight in kg.
	sum : function(emptyKgs : {number}, loads : {CargoLoad}) : Weight
end
```

- [ ] **Step 2: Register it**

`mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl` becomes:

```teal
require "gui.pgrace_train_grade.util"
require "gui.pgrace_train_grade.grade"
require "gui.pgrace_train_grade.weight"
```

- [ ] **Step 3: Write the failing tests**

`tests/weight_test.lua`:

```lua
local t = ...
local weight = t.requireTl("gui/pgrace_train_grade/weight.tl")

t.test("sum: empty train has no cargo weight", function()
	local w = weight.sum({ 80000, 20000, 20000 }, {})
	t.eq(w.empty, 120, "empty")
	t.eq(w.cargo, 0, "cargo")
	t.eq(w.gross, 120, "gross")
end)

t.test("sum: mixed cargo adds up", function()
	local w = weight.sum({ 50000, 25000 }, {
		{ count = 30, unitWeight = 1000 },   -- 30 t
		{ count = 10, unitWeight = 500 },    -- 5 t
	})
	t.eq(w.empty, 75, "empty")
	t.eq(w.cargo, 35, "cargo")
	t.eq(w.gross, 110, "gross")
end)

t.test("sum: zero counts add nothing", function()
	local w = weight.sum({ 1000 }, { { count = 0, unitWeight = 1000 } })
	t.eq(w.cargo, 0, "cargo")
	t.eq(w.gross, 1, "gross")
end)
```

- [ ] **Step 4: Run the tests and watch them fail**

Run: `just test`
Expected: the three `sum` tests FAIL (`cannot open .../weight.tl`); everything else passes.

- [ ] **Step 5: Implement**

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/weight.tl`:

```teal
local weight : PgraceTrainGradeWeight = {}

local KG_PER_TON = 1000

function weight.sum(emptyKgs : {number}, loads : {PgraceTrainGradeWeight.CargoLoad}) : PgraceTrainGradeWeight.Weight
	local emptyKg = 0.0
	for _, kg in ipairs(emptyKgs) do
		emptyKg = emptyKg + kg
	end
	local cargoKg = 0.0
	for _, load in ipairs(loads) do
		cargoKg = cargoKg + load.count * load.unitWeight
	end
	local empty = emptyKg / KG_PER_TON
	local cargo = cargoKg / KG_PER_TON
	return { gross = empty + cargo, empty = empty, cargo = cargo }
end

return weight
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `just test`
Expected: `14 passed, 0 failed`.

- [ ] **Step 7: Type-check**

Run: `just check`
Expected: `0 error(s)`.

- [ ] **Step 8: Commit**

```bash
git add tests/weight_test.lua mod/pgrace_train_grade/tealdef mod/pgrace_train_grade/content/gui/pgrace_train_grade/weight.tl mod/pgrace_train_grade/content/gui/pgrace_train_grade/weight.d.tl mod/pgrace_train_grade/_content.json
git commit -m "feat: train weight sums"
```

---

### Task 3: Remove the template sample

**Files:**
- Delete: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/industry_plugin.res.lua`
- Delete: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/pgrace_train_grade.script.tl`
- Delete: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/util.tl`, `util.d.tl`
- Delete: `mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/util.d.tl`
- Delete: `tests/util_test.lua`
- Modify: `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl`

- [ ] **Step 1: Delete the files**

```bash
git rm -q mod/pgrace_train_grade/content/gui/pgrace_train_grade/industry_plugin.res.lua \
  mod/pgrace_train_grade/content/gui/pgrace_train_grade/pgrace_train_grade.script.tl \
  mod/pgrace_train_grade/content/gui/pgrace_train_grade/util.tl \
  mod/pgrace_train_grade/content/gui/pgrace_train_grade/util.d.tl \
  mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/util.d.tl \
  tests/util_test.lua
```

- [ ] **Step 2: Update the registry**

`mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl` becomes:

```teal
require "gui.pgrace_train_grade.grade"
require "gui.pgrace_train_grade.weight"
```

- [ ] **Step 3: Verify**

Run: `just verify`
Expected: `0 error(s)`, then `12 passed, 0 failed`, then release-check passes. `_content.json` lists only `grade.*`
and `weight.*`.

- [ ] **Step 4: Commit**

```bash
git add -A mod/pgrace_train_grade tests
git commit -m "chore: remove template sample plugin"
```

---

### Task 4: `train_data.tl`, engine reads (with the probe)

This module is verified in-game, not unit-tested.

**Files:**
- Create: `mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/train_data.d.tl`
- Modify: `mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl`
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/train_data.tl`

- [ ] **Step 1: Write the type file**

`mod/pgrace_train_grade/tealdef/gui/pgrace_train_grade/train_data.d.tl`:

```teal
-- Reads game state for the speed strip. Verified in-game, not unit-tested.
global record PgraceTrainGradeTrainData
	record Reading
		weight : PgraceTrainGradeWeight.Weight
		-- nil when unknown
		grade : number
	end

	-- nil unless the entity is a rail vehicle that isn't at a terminal. May throw; callers pcall it.
	read : function(entity : Engine.Entity) : Reading
end
```

- [ ] **Step 2: Register it**

`mod/pgrace_train_grade/tealdef/pgrace_train_grade_def.d.tl` becomes:

```teal
require "gui.pgrace_train_grade.grade"
require "gui.pgrace_train_grade.weight"
require "gui.pgrace_train_grade.train_data"
```

- [ ] **Step 3: Implement**

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/train_data.tl`:

```teal
local grade = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/grade.tl" as PgraceTrainGradeGrade
local weight = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/weight.tl" as PgraceTrainGradeWeight

local train_data : PgraceTrainGradeTrainData = {}

local LOG_PREFIX = "[train_grade] "

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

-- Track segments from the front edge backwards, enough to cover the train.
local function segmentsBehind(movePath : Engine.Component.MovePath, trainLength : number) : {Segment}, {string}
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
		if collected >= trainLength + segments[1].length then
			break
		end
		i = i - 1
	end
	return segments, flags
end

local probeCounter = 0   -- PROBE (remove before release)

function train_data.read(entity : Engine.Entity) : PgraceTrainGradeTrainData.Reading
	local tv = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
	if tv == nil or tv.carrier ~= api.type["enum"].Carrier.RAIL then
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

return train_data
```

- [ ] **Step 4: Type-check**

Run: `just check`
Expected: `0 error(s)`. (`CargoTypeId` is a plain `integer` alias, so the cargo loop needs no casts.)

- [ ] **Step 5: Commit**

```bash
git add mod/pgrace_train_grade/tealdef mod/pgrace_train_grade/content/gui/pgrace_train_grade/train_data.tl mod/pgrace_train_grade/content/gui/pgrace_train_grade/train_data.d.tl mod/pgrace_train_grade/_content.json
git commit -m "feat: read train weight and grade from the engine (with probe)"
```

---

### Task 5: The speed strip replacement

**Files:**
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip.script.tl`
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip_replacement.res.lua`
- Create: `mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip.css.lua`

- [ ] **Step 1: Write the replacement recipe**

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip.script.tl`:

```teal
local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local entity_window_util = ug_require "::/gui/entity_window/entity_window_util.tl" as EntityWindowUtil
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local lang_util = ug_require "::/scripts/lang_util.tl" as LangUtil
local grade = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/grade.tl" as PgraceTrainGradeGrade
local train_data = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/train_data.tl" as PgraceTrainGradeTrainData

local LOG_PREFIX = "[train_grade] "
local WEIGHT_ICON = "::/gui/line_vehicle_mgmt/icons/symbol_weight.tga"

local record StripState
	visible : boolean
	weightText : string
	weightTooltip : string
	gradeText : string
	gradeIcon : string
end

local record EntryParams
	visible : boolean
	icon : string
	text : string
	tooltip : string
end

-- Entities whose read failed; the error is logged once per entity, not on every poll.
local reported : {Engine.Entity : boolean} = {}

local function computeState(entity : Engine.Entity) : StripState
	local ok, readingOrError = pcall(function() : PgraceTrainGradeTrainData.Reading
		return train_data.read(entity)
	end)
	if not ok then
		if not reported[entity] then
			reported[entity] = true
			debugPrint(LOG_PREFIX .. "read failed for " .. tostring(entity) .. ": " .. tostring(readingOrError))
		end
		return { visible = false, weightText = "", weightTooltip = "", gradeText = "", gradeIcon = "" }
	end
	local reading = readingOrError as PgraceTrainGradeTrainData.Reading
	if reading == nil then
		return { visible = false, weightText = "", weightTooltip = "", gradeText = "", gradeIcon = "" }
	end
	return {
		visible = true,
		weightText = api.util.formatWeight(reading.weight.gross),
		weightTooltip = lang_util.format(_("Empty {empty} · Cargo {cargo}"), {
			empty = api.util.formatWeight(reading.weight.empty),
			cargo = api.util.formatWeight(reading.weight.cargo),
		}),
		gradeText = grade.formatGrade(reading.grade),
		gradeIcon = grade.iconFor(reading.grade),
	}
end

-- One pill, built like a base SpeedIndicator entry; styled by speed_strip.css.lua.
local Entry = react.RegisterRecipe("PgraceTrainGradeStripEntry", function(params : EntryParams) : TreeNodeId
	if not params.visible then
		react.setStyleClasses("invisible")
	end
	return builtin.BoxLayout{
		child = builtin.Component{
			meta = { tooltip = params.tooltip, },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{
						meta = { class = "leftmost-icon", },
						path = params.icon,
						scaling = builtin.type.ImageViewScaling.AutoFit,
					},
					gui_react_util.makeHorizontalSpacer(),
					builtin.TextView{
						meta = { class = "font-scale-body", },
						text = params.text,
					},
				},
			},
		},
	}
end)

-- Replaces entity_window_util.SpeedIndicator (vehicle and person windows). The original always renders, in the same
-- place in the tree, so its own state survives our pills showing and hiding.
local SpeedStrip = react.RegisterRecipe("PgraceTrainGradeSpeedStrip", function(entityId : Engine.Entity) : TreeNodeId
	local state = engine_react_util.useStepStateTimer(function() : StripState
		return computeState(entityId)
	end, 0.25)
	local s = state:old()
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			Entry{ visible = s.visible, icon = WEIGHT_ICON, text = s.weightText, tooltip = s.weightTooltip },
			Entry{ visible = s.visible, icon = s.gradeIcon, text = s.gradeText, tooltip = "" },
			react.CallOriginalRecipe(entity_window_util.SpeedIndicator, entityId),
		},
	}
end)

local function doReplace(replacementApi : ReactReplacementApi)
	replacementApi.ReplaceRecipe(entity_window_util.SpeedIndicator, SpeedStrip)
end

debugPrint(LOG_PREFIX .. "script loaded")

return {
	doReplace = doReplace,
}
```

- [ ] **Step 2: Register the replacement**

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip_replacement.res.lua`:

```lua
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "pgrace_train_grade::/gui/pgrace_train_grade/speed_strip.script",
			doReplaceFn = "doReplace",
			order = 0,
		}
	}
end
```

- [ ] **Step 3: Style the pills like the base strip**

The base `R::SpeedIndicator` rules (in `entity_window.css.lua`) don't reach our recipe, so copy them, keyed on our
pill recipe.

`mod/pgrace_train_grade/content/gui/pgrace_train_grade/speed_strip.css.lua`:

```lua
local color_util = require "::/gui/main/color_util.tl"
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data

	-- Same box as the game's speed readout (entity_window.css.lua, R::SpeedIndicator), one per pill.
	a("R::PgraceTrainGradeStripEntry", {
		backgroundImage1 = {
			fileName = "::/gui/entity_window/icons/card_border.tga",
			horizontal = { 0, 8, 9, 17 },
			vertical = { 0, 8, 9, 17 },
		},
		backgroundColor1 = color_util.withTransparencyRaw(colorDefault.BaseVeryDark, transparency.Low),
		padding = { 1, 1, 1, 1 },
		margin = { 1, 0, 1, 0 },
	})
	a("R::PgraceTrainGradeStripEntry TextView", {
		margin = { 0, 2, 0, 2 },
	})
	a("R::PgraceTrainGradeStripEntry ImageView!leftmost-icon", {
		margin = { 0, 2, 0, 0 },
	})

	return result
end
```

- [ ] **Step 4: Verify**

Run: `just verify`
Expected: `0 error(s)`, `12 passed, 0 failed`, release-check passes. `_content.json` now lists
`speed_strip.css.lua`, `speed_strip.script.tl` and `speed_strip_replacement.res.lua` alongside the modules.

If release-check complains that `_("Empty {empty} · Cargo {cargo}")` has no translation: there's no `strings.json`,
so it shouldn't. If it does, add `mod/pgrace_train_grade/strings.json` containing `{}` and re-run.

- [ ] **Step 5: Commit**

```bash
git add mod/pgrace_train_grade
git commit -m "feat: weight and grade pills in the vehicle window's speed strip"
```

---

### Task 6: Install, then the user's in-game session

- [ ] **Step 1: Install**

Run: `just install`
Expected: a symlink in the staging area pointing at `mod/pgrace_train_grade` (idempotent if it's already there).

- [ ] **Step 2: Hand the user this checklist**

> Restart TF3, enable **Train Grade** if it's not already on, load a save with freight trains, then:
> 1. Open a loaded freight train's window while it's running on a known grade. Watch it over a **crest** and a
>    **dip**. As the locomotive (which the camera follows) passes the crest, the grade should start falling **right
>    away**. If it only changes after the last wagon passes, the path position is the back of the train, not the
>    front.
> 2. Watch a train **reverse** at a terminus, if a line does that. Uphill should still read +.
> 3. Open a **passenger train**'s window, then a **bus**'s window, then a **person in a car**. The bus and the person
>    should look exactly as before.
> 4. Watch a train **arrive** at a station and **depart**: the two pills should vanish at the platform and come back
>    when it leaves.
> 5. Hover the weight pill and check the tooltip (Empty · Cargo).
> 6. Tell me when you're done; a screenshot of the strip helps too.

- [ ] **Step 3: Read the probe**

```bash
grep -h "\[train_grade\]" ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt | tail -60
```

Check against the spec's assumptions:
- **a. `pathPos` is the front.** Confirmed by checklist item 1.
- **b. The meaning of `pos01` on reversed edges.** `walked` shows `R` on reversed edges. If the grade's sign is wrong
  only when the front edge is `R`, `pos01` runs in travel direction: in `train_data.read`, pass
  `segments[1].reversed and (1 - pos01) or pos01` as `frontT`.
- **c. `occupiedBackIndex`.** For information only: the walk doesn't depend on it.
- **d. `CargoType.weight` units.** `loads=` shows `countxunitWeight`. If a full coal wagon's `cargo` comes out about
  1000× off its payload, change `KG_PER_TON` handling: weights are already in tons, so `unitWeight` needs no `/ 1000`.
  Adjust `weight.tl` and its test to match.
- **e. `calcPosition(...).z` is absolute.** `zFront` should be in the tens to hundreds and change smoothly. A value
  near 0 that jumps at each edge boundary means it's relative.

- [ ] **Step 4: Fix what the probe shows, remove the probe, record the findings**

- Delete every line marked `-- PROBE (remove before release)`, along with the `flags` return value and the
  `probeCounter` block in `train_data.tl`. `segmentsBehind` then returns only `{Segment}`; update its caller.
- Record the verified facts (`MOVE_PATH` on trains, the meaning of `pathPos`, the `pos01` direction, the
  `CargoType.weight` unit, `calcPosition` z) in the kit's `../AGENTS.md` under *Game data facts*, and commit that in
  the kit repo.
- Run `just verify`, then commit in the mod repo:

```bash
git commit -am "fix: apply probe findings; remove probe"
```

- [ ] **Step 5: The user re-tests the layout and tooltip**, then merges to `main` locally (`superpowers:finishing-a-development-branch`).
