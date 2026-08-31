extends GutTest

var CrapAnalyzer = load("res://addons/gut/crap/crap_analyzer.gd")
const CRAP_JSON_PATH = "user://gut-crap-analyzer-test.json"


func after_each():
	if(FileAccess.file_exists(CRAP_JSON_PATH)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CRAP_JSON_PATH))


func find_method(report: Dictionary, method_name: String) -> Dictionary:
	for method in report.methods:
		if(method.method_name == method_name):
			return method
	return {}


func test_uncovered_complex_method_has_standard_crap_score():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"excludes": [],
		"threshold": 30.0,
		"fail_on_threshold": false,
	})

	var report = analyzer.finish()
	var method = report.methods[0]

	assert_eq(report.status, "complete")
	assert_eq(report.summary.methods, 1)
	assert_eq(report.summary.violations, 1)
	assert_eq(method.method_name, "risky")
	assert_eq(method.complexity, 6)
	assert_eq(method.executable_line_count, 5)
	assert_eq(method.covered_line_count, 0)
	assert_eq(method.coverage_percent, 0.0)
	assert_eq(method.crap, 42.0)
	assert_true(method.violates_threshold)


func test_executed_lines_reduce_crap_without_changing_source_line_numbers():
	var source_path = "res://test/resources/crap/basic/risky_subject.gd"
	var source_before = FileAccess.get_file_as_string(source_path)
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"excludes": [],
		"threshold": 30.0,
		"fail_on_threshold": false,
	})
	analyzer.begin()

	var Subject = load(source_path)
	var subject = Subject.new()
	assert_eq(subject.risky(1, true), 1)

	var report = analyzer.finish()
	var method = report.methods[0]
	assert_eq(method.covered_line_count, 4)
	assert_eq(method.uncovered_lines, [9])
	assert_eq(method.coverage_percent, 80.0)
	assert_almost_eq(method.crap, 6.288, 0.0001)
	assert_false(method.violates_threshold)
	assert_eq(FileAccess.get_file_as_string(source_path), source_before)
	assert_eq(Subject.source_code, source_before)


func test_gdscript_callable_scope_and_decisions_are_reported_consistently():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/language"],
		"threshold": 30.0,
	})
	var report = analyzer.finish()

	assert_eq(report.status, "complete")
	assert_eq(report.summary.methods, 6)
	assert_eq(report.summary.excluded_lambdas, 1)
	assert_eq(find_method(report, "stored_value.get").kind, "getter")
	assert_eq(find_method(report, "stored_value.get").complexity, 1)
	assert_eq(find_method(report, "stored_value.set").kind, "setter")
	assert_eq(find_method(report, "stored_value.set").complexity, 2)
	assert_eq(find_method(report, "keywords_in_text").complexity, 1)
	assert_eq(find_method(report, "choose").complexity, 4)
	assert_eq(find_method(report, "owns_lambda").complexity, 1)
	assert_eq(find_method(report, "short_circuit").kind, "static_method")
	assert_eq(find_method(report, "short_circuit").complexity, 3)


func test_explicit_directories_are_recursive_deduplicated_and_excludable():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": [
			"res://test/resources/crap",
			"res://test/resources/crap/basic",
		],
		"excludes": [
			"res://test/resources/crap/integration/*",
			"res://test/resources/crap/language/*",
			"res://test/resources/crap/lifecycle/*",
			"res://test/resources/crap/shapes/*",
		],
	})
	var report = analyzer.finish()

	assert_eq(report.status, "complete")
	assert_eq(report.summary.files, 1)
	assert_eq(report.summary.methods, 1)
	assert_eq(report.methods[0].path, "res://test/resources/crap/basic/risky_subject.gd")


func test_multiline_signatures_inline_bodies_and_inner_classes_keep_their_shape():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({"dirs": ["res://test/resources/crap/shapes"]})
	analyzer.begin()

	var Subject = load("res://test/resources/crap/shapes/shapes_subject.gd")
	assert_eq(Subject.new().top_level(), 1)
	assert_eq(Subject.Inner.new().nested(7, true), 7)
	assert_eq(Subject.new().multiline_statement(true), 3)
	assert_eq(Subject.new().inline_match(0), 10)
	assert_eq(Subject.new().returns_lambda().call(true), 1)

	var report = analyzer.finish()
	var nested = find_method(report, "nested")
	var top_level = find_method(report, "top_level")
	var multiline = find_method(report, "multiline_statement")
	var inline_match = find_method(report, "inline_match")
	var returns_lambda = find_method(report, "returns_lambda")
	assert_eq(report.status, "complete")
	assert_eq(report.summary.methods, 5)
	assert_eq(nested.class_name, "shapes_subject.Inner")
	assert_eq(nested.start_line, 5)
	assert_eq(nested.end_line, 10)
	assert_eq(nested.complexity, 2)
	assert_eq(nested.executable_line_count, 2)
	assert_eq(nested.covered_line_count, 1)
	assert_eq(nested.uncovered_lines, [10])
	assert_eq(top_level.class_name, "shapes_subject")
	assert_eq(top_level.executable_line_count, 1)
	assert_eq(top_level.covered_line_count, 1)
	assert_eq(multiline.complexity, 3)
	assert_eq(multiline.executable_line_count, 3)
	assert_eq(multiline.covered_line_count, 2)
	assert_eq(multiline.uncovered_lines, [26])
	assert_eq(inline_match.complexity, 2)
	assert_eq(inline_match.executable_line_count, 2)
	assert_eq(inline_match.covered_line_count, 1)
	assert_eq(inline_match.uncovered_lines, [32])
	assert_eq(returns_lambda.complexity, 1)
	assert_eq(returns_lambda.executable_line_count, 1)
	assert_eq(returns_lambda.covered_line_count, 1)


func test_no_source_directories_disables_analysis_without_failing_the_run():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({"dirs": []})

	assert_eq(analyzer.get_report(), {"status": "disabled"})
	assert_false(analyzer.should_fail())


func test_analysis_errors_are_incomplete_and_always_fail():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/does-not-exist"],
		"fail_on_threshold": false,
	})

	var report = analyzer.finish()
	assert_eq(report.status, "incomplete")
	assert_eq(report.diagnostics[0].code, "DIRECTORY_NOT_FOUND")
	assert_true(analyzer.should_fail())


func test_threshold_is_advisory_unless_the_gate_is_enabled():
	var advisory = CrapAnalyzer.new()
	advisory.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"threshold": 30.0,
		"fail_on_threshold": false,
	})
	advisory.finish()
	assert_false(advisory.should_fail())

	var gated = CrapAnalyzer.new()
	gated.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"threshold": 30.0,
		"fail_on_threshold": true,
	})
	gated.finish()
	assert_true(gated.should_fail())


func test_optional_standalone_json_uses_the_versioned_report_schema():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"json_file": CRAP_JSON_PATH,
	})
	var report = analyzer.finish()

	assert_true(FileAccess.file_exists(CRAP_JSON_PATH))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CRAP_JSON_PATH))
	assert_eq(int(parsed.schema_version), 1)
	assert_eq(parsed.status, "complete")
	assert_eq(int(parsed.summary.methods), report.summary.methods)


func test_standalone_json_write_failure_marks_analysis_incomplete():
	var analyzer = CrapAnalyzer.new()
	var missing_parent = "user://gut-crap-missing-%s/report.json" % get_instance_id()
	analyzer.prepare({
		"dirs": ["res://test/resources/crap/basic"],
		"json_file": missing_parent,
	})
	var report = analyzer.finish()

	assert_eq(report.status, "incomplete")
	assert_eq(report.diagnostics[-1].code, "JSON_EXPORT_FAILED")
	assert_true(analyzer.should_fail())


func test_same_configuration_can_reset_an_analyzer_for_another_run():
	var analyzer = CrapAnalyzer.new()
	var options = {"dirs": ["res://test/resources/crap/basic"]}
	analyzer.prepare(options)
	analyzer.finish()

	analyzer.prepare(options)
	var report = analyzer.finish()
	assert_eq(report.status, "complete")
	assert_eq(report.summary.methods, 1)


func test_changed_configuration_in_one_process_requires_a_restart():
	var analyzer = CrapAnalyzer.new()
	analyzer.prepare({"dirs": ["res://test/resources/crap/basic"]})
	analyzer.finish()

	analyzer.prepare({"dirs": ["res://test/resources/crap/shapes"]})
	var report = analyzer.finish()
	assert_eq(report.status, "incomplete")
	assert_eq(report.diagnostics[-1].code, "RESTART_REQUIRED")
	assert_true(analyzer.should_fail())
