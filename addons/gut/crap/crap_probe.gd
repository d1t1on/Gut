extends RefCounted

static var _active = false
static var _hits = {}
static var _mutex = Mutex.new()


static func reset():
	_mutex.lock()
	_hits.clear()
	_active = false
	_mutex.unlock()


static func start():
	_mutex.lock()
	_hits.clear()
	_active = true
	_mutex.unlock()


static func hit(script_id: int, line: int):
	_mutex.lock()
	if(!_active):
		_mutex.unlock()
		return
	if(!_hits.has(script_id)):
		_hits[script_id] = {}
	_hits[script_id][line] = int(_hits[script_id].get(line, 0)) + 1
	_mutex.unlock()


static func stop() -> Dictionary:
	_mutex.lock()
	_active = false
	var result = _hits.duplicate(true)
	_mutex.unlock()
	return result
