# Vehicle Grade and Weight: design

**Mod:** `pgrace_train_grade` (display name "Vehicle Grade and Weight")
**Date:** 2026-10-12
**Origin:** a player request (`TrainAddition.png`): show a train's combined weight and the grade it's on, next to the
speed in the vehicle window. Widened during design from trains to all land vehicles.

## Goal

In a **land vehicle's** window (train, tram, bus or truck), the speed strip under the camera view shows two extra entries before the speed:

```
en route:    ⛁ 1,240 t   ⛰ +1.8%   ⏲ 39 km/h
waiting:     ⛁ 1,240 t   ⛰ −0.4%   ⏲ Waiting for Free Path
at station:  ⏱ Loading  [coal] 117/120 ...   (unchanged)
```

- **Weight:** gross weight (vehicles + cargo on board) in the player's units (`api.util.formatWeight`). Tooltip:
  `Empty {empty} · Cargo {cargo}`.
- **Grade:** average grade over the vehicle's length (the whole consist for a train), signed in the direction of travel (+ climbing, − descending),
  one decimal. |grade| < 0.05% shows as `0.0%` without a sign. Unknown grade shows `—`.
- **When:** only for vehicles with `carrier` RAIL, TRAM or ROAD whose `state` is not `AT_TERMINAL` (that is, running, stopping, stopped,
  waiting for a path or no path). At terminals, and for ships, aircraft and people in cars, the strip is
  exactly the base game's.
- The mod stays `cosmetic` (UI only).

## Approach

Replace `entity_window_util.SpeedIndicator` (exported, `Recipe<Engine.Entity>`) through a
`react-replacement-config`. The replacement **wraps** the base widget:

a horizontal `BoxLayout` of `[weight pill] [grade pill]` followed by
`react.CallOriginalRecipe(entity_window_util.SpeedIndicator, entityId)`. The tree is always the same; the pills get the
`invisible` style class unless the entity is a land vehicle that isn't at a terminal, so the original's state survives them
showing and hiding. The pills are styled by our own stylesheet, a copy of the base `R::SpeedIndicator` rules, because
those rules don't reach our recipe.

The base widget keeps its own behaviour (Stopped, No Path, loading messages). Rejected options:
- copying and extending the base recipe (it goes stale on game updates);
- a `VehicleEowExtensionPoint` card (kept as the fallback if the strip proves too tight).

Risk: another mod replacing `SpeedIndicator` conflicts with this one. Accepted.

## Files

```
mod/pgrace_train_grade/
  content/gui/pgrace_train_grade/
    speed_strip_replacement.res.lua   react-replacement-config; doReplaceFn → ReplaceRecipe
    speed_strip.script.tl             replacement recipe: polling, rendering
    vehicle_data.tl                     all api.* reads; builds inputs for the pure modules
    grade.tl                          pure: average grade over a path span
    weight.tl                         pure: weight sums, unit conversion, grade text formatting
  strings.json                        only if release-check requires entries
tests/grade_test.lua, tests/weight_test.lua
```

Remove the template's Hello industry plugin and its files. Global record names use the `PgraceTrainGrade` prefix,
with the tealdefs registered in `tealdef/pgrace_train_grade_def.d.tl` as usual.

## Data flow

Polled with `useStepStateTimer(fn, 0.25)` in the replacement recipe. Everything that touches `api` goes through
`vehicle_data.tl`, inside `pcall`.

1. **Land vehicle check:** `TRANSPORT_VEHICLE.carrier` is `RAIL`, `TRAM` or `ROAD`, and `state ~= AT_TERMINAL`.
2. **Static data**, cached and keyed by the list of part model ids, so a replaced consist refreshes it: for each
   `transportVehicleConfig.vehicles[i].part.modelId`, read `modelRep.get(id).metadata`:
   - `landVehicle.weightEmpty` (kg);
   - length `extent.bbMax.x − extent.bbMin.x`.

   The vehicle's length is the sum of the part lengths (one part for most road vehicles).
3. **Cargo** (live): for each cargo id with `config.capacities[cargo + 1] > 0`, the count on board
   (`simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(vehicle, cargo)`) times
   `cargoTypeRep.get(cargo).weight`.
4. **Grade** (live):
   - From `MOVE_PATH`, read `path.edges` and `dyn.pathPos` (`edgeIndex`, `pos01`).
   - Walk edges from `edgeIndex` backwards until they cover the vehicle's length plus the front edge, reading each
     geometry at `TRANSPORT_NETWORK(edgeId.entity).edges[edgeId.index + 1].geometry`. Cache network components
     within one poll. `occupiedBackIndex` is logged by the probe but not relied on.
   - Each edge becomes a segment `{length, heightAt(t) = api.engine.util.transport.calcPosition(geom, t).z, reversed}`.
   - `grade.tl` walks back from the front over `vehicleLength` metres along the track and returns
     `(zFront − zBack) / distanceCovered`, using the distance actually covered if the path runs out, or `nil` if
     that's under 1 m.
5. **Render:** two pills matching the base entries (icon `ImageView`, horizontal spacer, `TextView` with
   `font-scale-body`), with the tooltip on the weight pill. Text is formatted once per poll.
   - Weight icon: `::/gui/line_vehicle_mgmt/icons/symbol_weight.tga`.
   - Grade icon: the track builder's slope arrows `::/gui/construction/build_control/symbol_slope_<n>_20.tga`, with
     n = 0 for flat (inside ±0.05%), ±1 under 2% and ±2 from 2%, signed like the grade.

### Pure module interfaces

```teal
-- grade.tl
record Segment
	length : number                      -- metres along the track
	heightAt : function(t : number) : number   -- t in [0, 1] along the edge's own direction
	reversed : boolean                   -- true if travel runs from t = 1 to t = 0
end
-- segments[1] is the front edge, then backwards. frontT is pathPos.pos01 on segments[1].
averageGrade : function(segments : {Segment}, frontT : number, vehicleLength : number) : number   -- nil if < 1 m
formatGrade : function(grade : number) : string                                                  -- "+1.8%", "0.0%", "—"
iconFor : function(grade : number) : string                                                      -- slope arrow path

-- weight.tl
record CargoLoad
	count : integer
	unitWeight : number
end
record Weight   -- tons
	gross : number
	empty : number
	cargo : number
end
sum : function(emptyKgs : {number}, loads : {CargoLoad}) : Weight
```

The units of `unitWeight` are pinned down by the probe; `sum` converts to tons.

## Error handling

- Any error in `vehicle_data.tl`, or data that doesn't fit (no `MOVE_PATH`, missing metadata), means we render only the
  original widget. We `debugPrint("[train_grade] ...")` once per window, not on every poll.
- A grade of `nil` shows `—`, and the weight still shows.
- Edges from a removed network: guard with `api.engine.entityExists` before `getComponent`.

## Assumptions to verify (probe)

- a. Trains, trams and road vehicles carry `MOVE_PATH`, and `dyn.pathPos` is the **front** of the vehicle.
- a2. Road and tram path edges are lane edges whose height follows the street.
- b. The meaning of the direction flag in `path.edges`: whether `pos01` is in edge or travel direction.
- c. `occupiedBackIndex` is the edge under the last vehicle.
- d. The units of `CargoType.weight`, checked against a full wagon's `weightMaxPayload`.
- e. `calcPos` returns absolute world z.

Fallback if (a) or (c) is wrong: walk from `edgeIndex` over `vehicleLength`, in whichever direction the vehicle extends.

## Testing

**Unit tests:**
- `grade_test.lua`:
  - flat track gives 0;
  - a constant 2% slope gives 0.02, on one edge or across three;
  - a crest with the train split evenly gives about 0;
  - a reversed edge flips the sign;
  - a path shorter than the train uses the distance covered;
  - under 1 m gives nil;
  - `formatGrade`: the sign, the dead band, rounding and nil;
  - `iconFor`: flat, gentle and steep, both ways.
- `weight_test.lua`: an empty train, mixed cargo, the kg-to-t conversion.

**In-game session 1:** the full feature plus `-- PROBE` debugPrints, about one per second per open window:
- `edgeIndex`, `pos01`, `occupiedBackIndex`, `#path.edges` and the direction flags;
- front and back z, the grade, the vehicle's length;
- the cargo counts × unit weights and the weight totals;
- `zFront`, to check that heights are absolute.

Whether `pathPos` is the front is checked visually: over a crest, the grade must start falling as soon as the
locomotive (which the camera follows) passes it.

Checklist for the user:
1. A loaded freight train on a known grade, going over a crest and a dip.
2. A train reversing at a terminus.
3. A passenger train; a bus or truck on a hill; a tram.
4. A ship, an aircraft and a person in a car, which should be unchanged.
5. A train and a bus arriving and departing: the entries hide at the terminal and come back.

**Pass criteria:**
- Grade about 0 on flat ground, the sign flips over a crest, the sign is correct after reversing.
- The gross weight matches the empty weight plus cargo.
- No UI errors, and ship, aircraft and person windows are unchanged.

**Session 2** (if needed): fixes, the probe removed, then a check of the layout and the tooltip.

## Out of scope

- Ships and aircraft, the window card, a settings toggle.
- Translations beyond what release-check needs (German could follow later).
