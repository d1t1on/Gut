extends RefCounted

var values: Array[int] = [1, 2]


func sum_values() -> int:
	var total := 0
	for value: int in values:
		total += value
	return total
