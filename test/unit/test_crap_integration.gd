extends GutInternalTester

const TEST_SCRIPT = "res://test/resources/crap/integration/test_uses_crap_subject.gd"
const POST_HOOK = "res://test/resources/crap/integration/read_crap_report_hook.gd"
const LIFECYCLE_TEST_SCRIPT = "res://test/resources/crap/integration/test_crap_lifecycle.gd"
const PRE_HOOK = "res://test/resources/crap/integration/crap_pre_run_hook.gd"
const LIFECYCLE_POST_HOOK = "res://test/resources/crap/integration/crap_post_run_hook.gd"

var GutCli = load("res://addons/gut/cli/gut_cli.gd")
var GutConfig = load("res://addons/gut/gut_config.gd")
var GutRunner = load("res://addons/gut/gui/GutRunner.tscn")
var ResultExporter = load("res://addons/gut/result_exporter.gd")


func _find_method(report: Dictionary, method_name: String) -> Dictionary:
	for method in report.methods:
		if(method.method_name == method_name):
			return method
	return {}


func _run_with_crap(post_hook := ""):
	var nested_gut = add_child_autoqfree(new_gut(verbose))
	var config = GutConfig.new()
	config.options.tests = [TEST_SCRIPT]
	config.options.crap_dirs = ["res://test/resources/crap/basic"]
	config.options.crap_threshold = 30.0
	config.options.crap_fail_on_threshold = false
	config.options.post_run_script = post_hook
	config.apply_options(nested_gut)

	nested_gut.test_scripts()
	assert_true(await wait_for_signal(nested_gut.end_run, 2.0))
	return nested_gut


func test_config_defaults_keep_crap_analysis_disabled_and_advisory():
	var options = GutConfig.new().default_options
	assert_eq(options.crap_dirs, [])
	assert_eq(options.crap_excludes, [])
	assert_eq(options.crap_threshold, 30.0)
	assert_false(options.crap_fail_on_threshold)
	assert_eq(options.crap_json_file, "")


func test_configured_run_collects_coverage_and_embeds_it_in_result_json():
	var nested_gut = await _run_with_crap()
	var report = nested_gut.get_crap_report()
	var exported = ResultExporter.new().get_results_dictionary(nested_gut)

	assert_eq(report.status, "complete")
	assert_eq(report.methods[0].covered_line_count, 4)
	assert_has(exported, "crap_analysis")
	assert_eq(exported.crap_analysis.schema_version, 1)


func test_report_is_finalized_before_the_post_run_hook():
	var nested_gut = await _run_with_crap(POST_HOOK)
	assert_eq(nested_gut.get_meta("post_hook_crap_status"), "complete")


func test_collection_starts_before_pre_run_and_stops_before_post_run():
	var nested_gut = add_child_autoqfree(new_gut(verbose))
	var config = GutConfig.new()
	config.options.tests = [LIFECYCLE_TEST_SCRIPT]
	config.options.crap_dirs = ["res://test/resources/crap/lifecycle"]
	config.options.pre_run_script = PRE_HOOK
	config.options.post_run_script = LIFECYCLE_POST_HOOK
	config.apply_options(nested_gut)

	nested_gut.test_scripts()
	assert_true(await wait_for_signal(nested_gut.end_run, 2.0))
	var report = nested_gut.get_crap_report()
	assert_eq(_find_method(report, "from_pre_run").covered_line_count, 1)
	assert_eq(_find_method(report, "from_test").covered_line_count, 1)
	assert_eq(_find_method(report, "from_post_run").covered_line_count, 0)
	assert_eq(nested_gut.get_meta("post_hook_crap_status"), "complete")


func test_disabled_analysis_does_not_change_the_existing_result_schema():
	var nested_gut = add_child_autoqfree(new_gut(verbose))
	var exported = ResultExporter.new().get_results_dictionary(nested_gut)
	assert_does_not_have(exported, "crap_analysis")


func test_crap_exit_failure_changes_only_a_zero_exit_code():
	var runner = add_child_autofree(GutRunner.instantiate())
	assert_eq(runner.resolve_exit_code(0, 0, null, true), 1)
	assert_eq(runner.resolve_exit_code(0, 0, 0, true), 1)
	assert_eq(runner.resolve_exit_code(7, 0, null, true), 7)
	assert_eq(runner.resolve_exit_code(0, 0, 9, true), 9)
	assert_eq(runner.resolve_exit_code(0, 1, null, false), 1)


func test_cli_crap_options_map_to_config_keys():
	var config = GutConfig.new()
	var cli = autofree(GutCli.new())
	var parsed = cli.setup_options(config.default_options, [])
	parsed.parse([
		"-gcrap_dir=res://src,res://lib",
		"-gcrap_exclude=res://src/generated/*",
		"-gcrap_threshold=12.5",
		"-gcrap_fail_on_threshold",
		"-gcrap_json_file=user://crap.json",
	])
	var extracted = config.default_options.duplicate(true)
	cli.extract_command_line_options(parsed, extracted)

	assert_eq(extracted.crap_dirs, ["res://src", "res://lib"])
	assert_eq(extracted.crap_excludes, ["res://src/generated/*"])
	assert_eq(extracted.crap_threshold, 12.5)
	assert_true(extracted.crap_fail_on_threshold)
	assert_eq(extracted.crap_json_file, "user://crap.json")
