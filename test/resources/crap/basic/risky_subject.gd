extends RefCounted


func risky(value: int, flag: bool) -> int:
	var result := 0
	if(value > 0):
		result += 1
	elif(value < 0):
		result -= 1
	for i in range(2):
		if(flag and i == 0):
			result += i
	return result
