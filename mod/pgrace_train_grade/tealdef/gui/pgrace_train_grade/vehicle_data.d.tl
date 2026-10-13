-- Reads game state for the speed strip. Verified in-game, not unit-tested.
global record PgraceTrainGradeVehicleData
	record Reading
		weight : PgraceTrainGradeWeight.Weight
		-- nil when unknown
		grade : number
	end

	-- nil unless the entity is a land vehicle (rail, tram or road) that isn't at a terminal. May throw; callers pcall it.
	read : function(entity : Engine.Entity) : Reading
end
