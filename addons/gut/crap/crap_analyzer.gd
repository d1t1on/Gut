extends RefCounted

const DEFAULT_THRESHOLD = 30.0
const SCHEMA_VERSION = 1
const CrapProbe = preload("res://addons/gut/crap/crap_probe.gd")
const PROBE_EXPRESSION = 'preload("res://addons/gut/crap/crap_probe.gd").hit(%s, %s); '

var _config = {}
var _diagnostics = []
var _files = []
var _methods = []
var _scripts = {}
var _original_sources = {}
var _excluded_lambdas = 0
var _prepared = false
var _begun = false
var _finished = false
var _restart_required = false
var _last_signature = ""
var _report = {"status": "disabled"}


func _normalize_config(options: Dictionary) -> Dictionary:
	return {
		"dirs": options.get("dirs", []).duplicate(),
		"excludes": options.get("excludes", []).duplicate() + options.get("hard_excludes", []).duplicate(),
		"threshold": float(options.get("threshold", DEFAULT_THRESHOLD)),
		"fail_on_threshold": bool(options.get("fail_on_threshold", false)),
		"json_file": str(options.get("json_file", "")),
	}


func _configuration_signature(source_by_path: Dictionary) -> String:
	var source_entries = []
	var paths = source_by_path.keys()
	paths.sort()
	for path in paths:
		source_entries.append({
			"path": path,
			"sha256": str(source_by_path[path]).sha256_text(),
		})
	return JSON.stringify({
		"dirs": _config.dirs,
		"excludes": _config.excludes,
		"threshold": _config.threshold,
		"fail_on_threshold": _config.fail_on_threshold,
		"json_file": _config.json_file,
		"sources": source_entries,
	}).sha256_text()


func _is_excluded(path: String) -> bool:
	var normalized_path = path.simplify_path()
	for configured_exclude in _config.get("excludes", []):
		var exclude = str(configured_exclude).simplify_path()
		if(exclude.find("*") != -1 or exclude.find("?") != -1):
			if(normalized_path.match(exclude)):
				return true
		else:
			var prefix = exclude.trim_suffix("/") + "/"
			if(normalized_path == exclude or normalized_path.begins_with(prefix)):
				return true
	return false


func _add_diagnostic(severity: String, code: String, message: String, path := "", line := 0):
	_diagnostics.append({
		"severity": severity,
		"code": code,
		"message": message,
		"path": path,
		"line": line,
	})


func _collect_gd_files(path: String, found: Array):
	var directory = DirAccess.open(path)
	if(directory == null):
		_add_diagnostic("error", "DIRECTORY_NOT_FOUND", "CRAP source directory does not exist.", path)
		return

	directory.list_dir_begin()
	var entry = directory.get_next()
	while(entry != ""):
		if(entry != "." and entry != ".."):
			var child_path = path.path_join(entry).simplify_path()
			if(_is_excluded(child_path)):
				entry = directory.get_next()
				continue
			if(directory.current_is_dir()):
				_collect_gd_files(child_path, found)
			elif(entry.ends_with(".gd")):
				found.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()


func _read_source(path: String) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if(file == null):
		_add_diagnostic("error", "SOURCE_UNREADABLE", "Could not read GDScript source.", path)
		return ""
	return file.get_as_text()


func _leading_indent(line: String) -> int:
	var result = 0
	for character in line:
		if(character == "\t"):
			result += 4
		elif(character == " "):
			result += 1
		else:
			break
	return result


func _sanitize_source(source: String) -> Array:
	var sanitized = []
	var in_string = false
	var triple = false
	var quote = ""
	var escaped = false

	for original_line in source.split("\n", true):
		var output = ""
		var index = 0
		while(index < original_line.length()):
			var character = original_line[index]
			var three = original_line.substr(index, 3) if index + 2 < original_line.length() else ""

			if(in_string):
				if(triple and three == quote.repeat(3)):
					output += "   "
					index += 3
					in_string = false
					triple = false
					continue
				if(!triple and !escaped and character == quote):
					output += " "
					index += 1
					in_string = false
					continue
				escaped = !triple and !escaped and character == "\\"
				if(character != "\\"):
					escaped = false
				output += " "
				index += 1
				continue

			if(character == "#"):
				output += " ".repeat(original_line.length() - index)
				break
			if(three == "\"\"\"" or three == "'''"):
				in_string = true
				triple = true
				quote = character
				output += "   "
				index += 3
				continue
			if(character == "\"" or character == "'"):
				in_string = true
				triple = false
				quote = character
				escaped = false
				output += " "
				index += 1
				continue

			output += character
			index += 1
		sanitized.append(output)

	return sanitized


func _function_name(stripped: String) -> String:
	var func_position = stripped.find("func ")
	if(func_position == -1):
		return ""
	var name_start = func_position + 5
	var parenthesis = stripped.find("(", name_start)
	if(parenthesis == -1):
		return ""
	return stripped.substr(name_start, parenthesis - name_start).strip_edges()


func _word_count(text: String, word: String) -> int:
	var count = 0
	var token = ""
	for character in text + " ":
		if(character.is_valid_identifier() or character == "_"):
			token += character
		else:
			if(token == word):
				count += 1
			token = ""
	return count


func _match_arm_count(body_lines: Array) -> int:
	var result = 0
	var match_indents = []
	var pattern_indents = []
	for body_line in body_lines:
		var line = str(body_line)
		var stripped = line.strip_edges()
		if(stripped == ""):
			continue
		var indent = _leading_indent(line)
		while(!match_indents.is_empty() and indent <= match_indents.back()):
			match_indents.pop_back()
			pattern_indents.pop_back()
		if(stripped.begins_with("match(") or stripped.begins_with("match ")):
			match_indents.append(indent)
			pattern_indents.append(-1)
			continue
		var colon = _top_level_colon(stripped)
		if(match_indents.is_empty() or indent <= match_indents.back() or colon == -1):
			continue
		if(pattern_indents.back() == -1):
			pattern_indents[pattern_indents.size() - 1] = indent
		if(indent == pattern_indents.back()):
			var pattern = stripped.left(colon).strip_edges()
			if(pattern != "_"):
				result += 1
	return result


func _complexity(body_lines: Array) -> int:
	var text = "\n".join(body_lines)
	var result = 1
	for keyword in ["if", "elif", "for", "while", "and", "or", "when"]:
		result += _word_count(text, keyword)
	result += text.count("&&")
	result += text.count("||")
	result += _match_arm_count(body_lines)
	return result


func _top_level_colon(text: String) -> int:
	var parentheses = 0
	var brackets = 0
	var braces = 0
	for index in range(text.length()):
		var character = text[index]
		if(character == "("):
			parentheses += 1
		elif(character == ")"):
			parentheses = max(parentheses - 1, 0)
		elif(character == "["):
			brackets += 1
		elif(character == "]"):
			brackets = max(brackets - 1, 0)
		elif(character == "{"):
			braces += 1
		elif(character == "}"):
			braces = max(braces - 1, 0)
		elif(character == ":" and parentheses == 0 and brackets == 0 and braces == 0):
			return index
	return -1


func _inline_body(stripped: String) -> String:
	var colon = _top_level_colon(stripped)
	if(colon == -1):
		return ""
	return stripped.substr(colon + 1).strip_edges()


func _callable_header_end(sanitized: Array, start_index: int) -> int:
	var parentheses = 0
	var brackets = 0
	var braces = 0
	for line_index in range(start_index, sanitized.size()):
		var line = str(sanitized[line_index])
		for character_index in range(line.length()):
			var character = line[character_index]
			if(character == "("):
				parentheses += 1
			elif(character == ")"):
				parentheses = max(parentheses - 1, 0)
			elif(character == "["):
				brackets += 1
			elif(character == "]"):
				brackets = max(brackets - 1, 0)
			elif(character == "{"):
				braces += 1
			elif(character == "}"):
				braces = max(braces - 1, 0)
			elif(character == ":" and parentheses == 0 and brackets == 0 and braces == 0):
				return line_index
		if(parentheses == 0 and brackets == 0 and braces == 0):
			return -1
	return -1


func _is_control_header(stripped: String) -> bool:
	for keyword in ["if", "elif", "else", "for", "while", "match"]:
		if(stripped == keyword or stripped.begins_with(keyword + "(") or stripped.begins_with(keyword + " ") or stripped.begins_with(keyword + ":")):
			return true
	return false


func _line_is_in_ranges(line_index: int, ranges: Array) -> bool:
	for range_entry in ranges:
		if(line_index >= range_entry.start and line_index <= range_entry.end):
			return true
	return false


func _lambda_ranges(lines: Array, sanitized: Array, start_index: int, end_index: int) -> Array:
	var result = []
	var index = start_index
	while(index <= end_index):
		var stripped = str(sanitized[index]).strip_edges()
		if(stripped.find("func(") == -1 and stripped.find("func (") == -1):
			index += 1
			continue
		var lambda_indent = _leading_indent(lines[index])
		var lambda_end = index
		var cursor = index + 1
		while(cursor <= end_index):
			var cursor_stripped = str(sanitized[cursor]).strip_edges()
			if(cursor_stripped != "" and _leading_indent(lines[cursor]) <= lambda_indent):
				break
			lambda_end = cursor
			cursor += 1
		result.append({"start": index + 1, "end": lambda_end})
		index = max(cursor, index + 1)
	return result


func _delimiter_delta(text: String) -> int:
	var result = 0
	for character in text:
		if(character == "(" or character == "[" or character == "{"):
			result += 1
		elif(character == ")" or character == "]" or character == "}"):
			result -= 1
	return result


func _statement_spans(sanitized: Array, start_index: int, end_index: int, excluded_ranges: Array) -> Array:
	var result = []
	var index = start_index
	while(index <= end_index):
		if(_line_is_in_ranges(index, excluded_ranges) or str(sanitized[index]).strip_edges() == ""):
			index += 1
			continue

		var statement_start = index
		var statement_end = index
		var depth = 0
		var continued = true
		while(statement_end <= end_index and continued):
			var statement_line = str(sanitized[statement_end])
			depth += _delimiter_delta(statement_line)
			continued = depth > 0 or statement_line.rstrip(" \t").ends_with("\\")
			if(continued):
				statement_end += 1
		if(statement_end > end_index):
			statement_end = end_index
		result.append({"start": statement_start, "end": statement_end})
		index = statement_end + 1
	return result


func _executable_info(lines: Array, sanitized: Array, header_end_index: int, end_index: int, function_indent: int, excluded_ranges := []) -> Dictionary:
	var executable = []
	var inline_injections = []
	var callable_inline_body = _inline_body(str(sanitized[header_end_index]).strip_edges())
	if(callable_inline_body != ""):
		executable.append(header_end_index + 1)
		inline_injections.append(header_end_index + 1)

	var match_indents = []
	var pattern_indents = []
	var spans = _statement_spans(sanitized, header_end_index + 1, end_index, excluded_ranges)
	for span in spans:
		var first = str(sanitized[span.start]).strip_edges()
		var last = str(sanitized[span.end]).strip_edges()
		var indent = _leading_indent(lines[span.start])
		if(first == "" or indent <= function_indent):
			continue

		while(!match_indents.is_empty() and indent <= match_indents.back()):
			match_indents.pop_back()
			pattern_indents.pop_back()

		var is_match_header = first.begins_with("match(") or first.begins_with("match ")
		if(is_match_header):
			match_indents.append(indent)
			pattern_indents.append(-1)
			continue

		var has_suite_colon = _top_level_colon(last) != -1
		var is_match_arm = false
		if(!match_indents.is_empty() and indent > match_indents.back() and has_suite_colon):
			if(pattern_indents.back() == -1):
				pattern_indents[pattern_indents.size() - 1] = indent
			is_match_arm = indent == pattern_indents.back()

		var inline_body = _inline_body(last)
		if(is_match_arm or _is_control_header(first)):
			if(inline_body != ""):
				executable.append(span.end + 1)
				inline_injections.append(span.end + 1)
			continue

		if(first.begins_with("@") or last.ends_with(":")):
			continue
		executable.append(span.start + 1)

	return {
		"lines": executable,
		"inline_injection_lines": inline_injections,
	}


func _without_lambda_expression(text: String) -> String:
	var lambda_position = -1
	for marker in ["func(", "func ("]:
		var marker_position = text.find(marker)
		if(marker_position != -1 and (lambda_position == -1 or marker_position < lambda_position)):
			lambda_position = marker_position
	return text if lambda_position == -1 else text.left(lambda_position)


func _body_without_ranges(sanitized: Array, header_end_index: int, end_index: int, excluded_ranges: Array) -> Array:
	var result = []
	var inline_body = _inline_body(str(sanitized[header_end_index]).strip_edges())
	if(inline_body != ""):
		result.append(_without_lambda_expression(inline_body))
	for index in range(header_end_index + 1, end_index + 1):
		if(!_line_is_in_ranges(index, excluded_ranges)):
			result.append(_without_lambda_expression(str(sanitized[index])))
	return result


func _trim_callable_end(sanitized: Array, header_end_index: int, end_index: int) -> int:
	while(end_index > header_end_index and str(sanitized[end_index]).strip_edges() == ""):
		end_index -= 1
	return end_index


func _base_class_name(path: String, sanitized: Array) -> String:
	for line in sanitized:
		var stripped = str(line).strip_edges()
		if(stripped.begins_with("class_name ")):
			return stripped.trim_prefix("class_name ").get_slice(" ", 0).strip_edges()
	return path.get_file().get_basename()


func _qualified_class_name(path: String, lines: Array, sanitized: Array, line_index: int) -> String:
	var names = []
	var indents = []
	for index in range(line_index + 1):
		var stripped = str(sanitized[index]).strip_edges()
		if(stripped == ""):
			continue
		var indent = _leading_indent(lines[index])
		while(!indents.is_empty() and indent <= indents.back()):
			indents.pop_back()
			names.pop_back()
		if(!stripped.begins_with("class ")):
			continue
		var declaration = stripped.trim_prefix("class ")
		var name_end = declaration.length()
		for separator in [" ", ":"]:
			var separator_position = declaration.find(separator)
			if(separator_position != -1):
				name_end = min(name_end, separator_position)
		var nested_name = declaration.left(name_end).strip_edges()
		if(nested_name != ""):
			names.append(nested_name)
			indents.append(indent)

	var qualified = _base_class_name(path, sanitized)
	if(!names.is_empty()):
		qualified += "." + ".".join(names)
	return qualified


func _property_name(stripped: String) -> String:
	if(!stripped.begins_with("var ") or !stripped.ends_with(":")):
		return ""
	var declaration = stripped.trim_prefix("var ").trim_suffix(":").strip_edges()
	var end = declaration.length()
	for separator in [":", "=", " "]:
		var position = declaration.find(separator)
		if(position != -1):
			end = min(end, position)
	return declaration.left(end).strip_edges()


func _append_accessor_methods(path: String, lines: Array, sanitized: Array, result: Array):
	var index = 0
	while(index < lines.size()):
		var property_name = _property_name(str(sanitized[index]).strip_edges())
		if(property_name == ""):
			index += 1
			continue
		var property_indent = _leading_indent(lines[index])
		var cursor = index + 1
		while(cursor < lines.size()):
			var stripped = str(sanitized[cursor]).strip_edges()
			var indent = _leading_indent(lines[cursor])
			if(stripped != "" and indent <= property_indent):
				break
			var accessor_kind = ""
			if(stripped == "get:" or stripped.begins_with("get(")):
				accessor_kind = "getter"
			elif(stripped.begins_with("set(") or stripped == "set:"):
				accessor_kind = "setter"
			if(accessor_kind == ""):
				cursor += 1
				continue

			var header_end_index = _callable_header_end(sanitized, cursor)
			if(header_end_index == -1):
				cursor += 1
				continue
			var end_index = header_end_index
			var accessor_cursor = header_end_index + 1
			while(accessor_cursor < lines.size()):
				var accessor_stripped = str(sanitized[accessor_cursor]).strip_edges()
				if(accessor_stripped != "" and _leading_indent(lines[accessor_cursor]) <= indent):
					break
				end_index = accessor_cursor
				accessor_cursor += 1
			end_index = _trim_callable_end(sanitized, header_end_index, end_index)

			var excluded_ranges = _lambda_ranges(lines, sanitized, header_end_index, end_index)
			_excluded_lambdas += excluded_ranges.size()
			var body = _body_without_ranges(sanitized, header_end_index, end_index, excluded_ranges)
			var executable = _executable_info(lines, sanitized, header_end_index, end_index, indent, excluded_ranges)
			result.append({
				"path": path,
				"class_name": _qualified_class_name(path, lines, sanitized, cursor),
				"method_name": property_name + (".get" if accessor_kind == "getter" else ".set"),
				"kind": accessor_kind,
				"start_line": cursor + 1,
				"end_line": end_index + 1,
				"complexity": _complexity(body),
				"executable_lines": executable.lines,
				"inline_injection_lines": executable.inline_injection_lines,
			})
			cursor = max(accessor_cursor, cursor + 1)
		index = max(cursor, index + 1)


func _analyze_source(path: String, source: String) -> Array:
	var lines = Array(source.split("\n", true))
	var sanitized = _sanitize_source(source)
	var result = []
	_append_accessor_methods(path, lines, sanitized, result)
	var index = 0

	while(index < lines.size()):
		var stripped = str(sanitized[index]).strip_edges()
		var method_name = _function_name(stripped)
		if(method_name == ""):
			index += 1
			continue

		var function_indent = _leading_indent(lines[index])
		var header_end_index = _callable_header_end(sanitized, index)
		if(header_end_index == -1):
			index += 1
			continue
		var end_index = header_end_index
		var cursor = header_end_index + 1
		while(cursor < lines.size()):
			var cursor_stripped = str(sanitized[cursor]).strip_edges()
			if(cursor_stripped != "" and _leading_indent(lines[cursor]) <= function_indent):
				break
			end_index = cursor
			cursor += 1
		end_index = _trim_callable_end(sanitized, header_end_index, end_index)

		var excluded_ranges = _lambda_ranges(lines, sanitized, header_end_index, end_index)
		_excluded_lambdas += excluded_ranges.size()
		var body = _body_without_ranges(sanitized, header_end_index, end_index, excluded_ranges)
		var executable = _executable_info(lines, sanitized, header_end_index, end_index, function_indent, excluded_ranges)
		result.append({
			"path": path,
			"class_name": _qualified_class_name(path, lines, sanitized, index),
			"method_name": method_name,
			"kind": "static_method" if stripped.begins_with("static func ") else "method",
			"start_line": index + 1,
			"end_line": end_index + 1,
			"complexity": _complexity(body),
			"executable_lines": executable.lines,
			"inline_injection_lines": executable.inline_injection_lines,
		})
		index = max(cursor, index + 1)

	return result


func _instrument_source(path: String, source: String, source_methods: Array, script_id: int):
	var executable_lookup = {}
	var inline_injection_lookup = {}
	for source_method in source_methods:
		source_method.script_id = script_id
		for line in source_method.executable_lines:
			executable_lookup[line] = true
		for line in source_method.inline_injection_lines:
			inline_injection_lookup[line] = true

	var lines = Array(source.split("\n", true))
	var sanitized = _sanitize_source(source)
	for index in range(lines.size()):
		var line_number = index + 1
		if(!executable_lookup.has(line_number)):
			continue
		var original = str(lines[index])
		if(inline_injection_lookup.has(line_number)):
			var colon = _top_level_colon(str(sanitized[index]))
			if(colon != -1):
				lines[index] = original.substr(0, colon + 1) + " " + PROBE_EXPRESSION % [script_id, line_number] + original.substr(colon + 1)
				continue
		var body = original.lstrip(" \t")
		var leading = original.left(original.length() - body.length())
		lines[index] = leading + PROBE_EXPRESSION % [script_id, line_number] + body

	var script = load(path)
	if(!(script is GDScript)):
		_add_diagnostic("error", "NOT_GDSCRIPT", "Resource is not a GDScript.", path)
		return

	var instrumented_source = "\n".join(lines)
	script.source_code = instrumented_source
	var reload_result = script.reload(true)
	if(reload_result != OK):
		script.source_code = source
		script.reload(true)
		_add_diagnostic("error", "INSTRUMENTATION_FAILED", "Instrumented GDScript could not be reloaded.", path)
		return

	_scripts[script_id] = script
	_original_sources[script_id] = source


func _restore_instrumented_sources():
	for script_id in _scripts:
		var script = _scripts[script_id]
		if(!is_instance_valid(script) or !_original_sources.has(script_id)):
			continue
		script.source_code = _original_sources[script_id]
		var reload_result = script.reload(true)
		if(reload_result != OK):
			_add_diagnostic(
				"error",
				"SOURCE_RESTORE_FAILED",
				"Instrumented GDScript could not be restored in memory.",
				script.resource_path)
	_scripts.clear()
	_original_sources.clear()


func _sort_methods(left: Dictionary, right: Dictionary) -> bool:
	if(left.crap != right.crap):
		return left.crap > right.crap
	if(left.path != right.path):
		return left.path < right.path
	return left.start_line < right.start_line


func _mark_json_export_failed(path: String, error: int):
	_add_diagnostic(
		"error",
		"JSON_EXPORT_FAILED",
		str("Could not write standalone CRAP report (error ", error, ")."),
		path)
	_report.status = "incomplete"
	_report.diagnostics = _diagnostics.duplicate(true)


func _write_standalone_report():
	var path = str(_config.get("json_file", ""))
	if(path == ""):
		return

	var file = FileAccess.open(path, FileAccess.WRITE)
	if(file == null):
		_mark_json_export_failed(path, FileAccess.get_open_error())
		return

	file.store_string(JSON.stringify(_report, " "))
	var result = file.get_error()
	file = null
	if(result != OK):
		_mark_json_export_failed(path, result)


func prepare(options: Dictionary):
	if(_prepared and !_finished):
		CrapProbe.stop()
		_restore_instrumented_sources()
	_config = _normalize_config(options)
	_diagnostics.clear()
	_files.clear()
	_methods.clear()
	_scripts.clear()
	_original_sources.clear()
	_excluded_lambdas = 0
	_prepared = true
	_begun = false
	_finished = false
	_restart_required = false
	_report = {"status": "disabled"}

	if(_config.dirs.is_empty()):
		return
	CrapProbe.reset()

	var found = []
	for configured_dir in _config.dirs:
		_collect_gd_files(str(configured_dir).simplify_path(), found)
	found.sort()
	var source_by_path = {}
	for path in found:
		if(path in _files):
			continue
		_files.append(path)
		var source = _read_source(path)
		source_by_path[path] = source

	if(_files.is_empty()):
		_add_diagnostic("error", "NO_SOURCE_FILES", "No GDScript source files were found in the CRAP directories.")

	var signature = _configuration_signature(source_by_path)
	if(_last_signature != "" and signature != _last_signature):
		_restart_required = true
		_add_diagnostic(
			"error",
			"RESTART_REQUIRED",
			"CRAP configuration or analyzed source changed in this process; start a fresh run.")
		return
	_last_signature = signature

	var script_id = 0
	for path in _files:
		var source = str(source_by_path[path])
		if(source != ""):
			var source_methods = _analyze_source(path, source)
			_methods.append_array(source_methods)
			_instrument_source(path, source, source_methods, script_id)
			script_id += 1


func begin():
	if(!_prepared or _config.dirs.is_empty() or _finished or _restart_required):
		return
	CrapProbe.start()
	_begun = true


func finish() -> Dictionary:
	if(_finished):
		return _report
	_finished = true

	if(!_prepared or _config.get("dirs", []).is_empty()):
		_report = {"status": "disabled"}
		return _report

	var hits = CrapProbe.stop()
	_restore_instrumented_sources()

	var methods = []
	var total_lines = 0
	var covered_lines = 0
	var violations = 0
	var maximum = 0.0
	for source_method in _methods:
		var executable_count = source_method.executable_lines.size()
		var script_hits = hits.get(source_method.script_id, {})
		var method_covered_lines = []
		var method_uncovered_lines = []
		for line in source_method.executable_lines:
			if(script_hits.has(line)):
				method_covered_lines.append(line)
			else:
				method_uncovered_lines.append(line)
		var covered_count = method_covered_lines.size()
		var method_coverage = float(covered_count) / float(executable_count) if executable_count > 0 else 1.0
		var complexity = int(source_method.complexity)
		var score = pow(complexity, 2) * pow(1.0 - method_coverage, 3) + complexity
		var violates = score >= _config.threshold
		if(violates):
			violations += 1
		maximum = max(maximum, score)
		total_lines += executable_count
		covered_lines += covered_count

		var method = source_method.duplicate(true)
		method.erase("executable_lines")
		method.erase("script_id")
		method.erase("inline_injection_lines")
		method.executable_line_count = executable_count
		method.covered_line_count = covered_count
		method.uncovered_lines = method_uncovered_lines
		method.coverage_percent = method_coverage * 100.0
		method.crap = score
		method.violates_threshold = violates
		methods.append(method)

	methods.sort_custom(_sort_methods)
	var has_error = _diagnostics.any(func(item): return item.severity == "error")
	_report = {
		"schema_version": SCHEMA_VERSION,
		"status": "incomplete" if has_error else "complete",
		"metric": {
			"formula": "CC^2 * (1 - coverage)^3 + CC",
			"coverage": "instrumentable_executable_line",
			"threshold": _config.threshold,
			"fail_on_threshold": _config.fail_on_threshold,
		},
		"summary": {
			"files": _files.size(),
			"methods": methods.size(),
			"executable_lines": total_lines,
			"covered_lines": covered_lines,
			"coverage_percent": (float(covered_lines) / float(total_lines)) * 100.0 if total_lines > 0 else 100.0,
			"violations": violations,
			"max_crap": maximum,
			"excluded_lambdas": _excluded_lambdas,
		},
		"methods": methods,
		"diagnostics": _diagnostics.duplicate(true),
	}
	_write_standalone_report()
	return _report


func get_report() -> Dictionary:
	return finish() if !_finished else _report


func should_fail() -> bool:
	var report = get_report()
	if(report.status == "incomplete"):
		return true
	return _config.get("fail_on_threshold", false) and report.summary.violations > 0
