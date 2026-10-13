-- Pure grade maths (no api.* calls), so tests/grade_test.lua can run it in plain Lua.
global record PgraceTrainGradeGrade
	-- One track or lane edge the vehicle covers. t runs 0..1 in the edge's own direction.
	record Segment
		-- metres along the track
		length : number
		-- world height at t
		heightAt : function(t : number) : number
		-- true when the vehicle travels from t = 1 towards t = 0
		reversed : boolean
	end

	-- Average grade (rise / distance, 0.02 = 2%) over the vehicleLength metres behind the front, signed in the direction
	-- of travel. segments[1] holds the front, at frontT; later segments lie further behind. If the segments run out,
	-- uses the distance they cover. nil if that's under 1 m.
	averageGrade : function(segments : {Segment}, frontT : number, vehicleLength : number) : number

	-- "+1.8%", "-0.4%"; "0.0%" inside +-0.05%; "—" for nil.
	formatGrade : function(grade : number) : string

	-- The track builder's slope arrow for a grade: flat, gentle (under 2%) or steep, up or down.
	iconFor : function(grade : number) : string
end
