extends RefCounted


class Inner:
	func nested(
		value: int,
		flag: bool,
	) -> int:
		if(flag): return value
		return 0


func top_level() -> int: return 1


func multiline_statement(flag: bool) -> int:
	var result = (
		1
		+ 2
	)
	if(
		flag
		and result > 0
	):
		return result
	return 0


func inline_match(value: int) -> int:
	match(value):
		0: return 10
		_: return 20


func returns_lambda() -> Callable:
	return func(value): return 1 if value else 0
