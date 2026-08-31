extends RefCounted

var stored_value := 0:
	get:
		return stored_value
	set(value):
		if(value > 0):
			stored_value = value


func keywords_in_text() -> String:
	var text = "if elif for while and or when"
	# if elif for while and or when
	return text


func choose(value: int, flag: bool) -> int:
	match(value):
		0:
			return 0
		1 when flag:
			return 1
		_:
			return 2


func owns_lambda() -> int:
	var callable = func():
		if(true):
			return 1
	return callable.call()


static func short_circuit(left: bool, right: bool) -> bool:
	return left && right or false
