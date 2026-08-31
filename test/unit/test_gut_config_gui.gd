extends GutTest

var GutConfigGui = load('res://addons/gut/gui/gut_config_gui.gd')
var GutConfig = load('res://addons/gut/gut_config.gd')

func _get_default_options():
	var ctrl = add_child_autofree(HBoxContainer.new())
	var gc = GutConfig.new()
	gc.options.double_strategy = GutUtils.get_enum_value(gc.options.double_strategy, GutUtils.DOUBLE_STRATEGY)
	var gcc = GutConfigGui.new(ctrl)
	gcc.set_options(gc.options)
	var opts = gcc.get_options(gc.options)
	return opts


func test_can_make_one():
	var ctrl = add_child_autofree(HBoxContainer.new())
	assert_not_null(autofree(GutConfigGui.new(ctrl)))

func test_free_makes_no_orphans():
	var ctrl = add_child_autofree(HBoxContainer.new())
	var gcc = GutConfigGui.new(ctrl)
	gcc = null
	await wait_physics_frames(1)
	assert_no_new_orphans()

func test_double_strategy_is_script_only():
	var opts = _get_default_options()
	assert_eq(opts.double_strategy, GutUtils.DOUBLE_STRATEGY.SCRIPT_ONLY)


func test_crap_options_round_trip_through_editor_controls():
	var ctrl = add_child_autofree(HBoxContainer.new())
	var config = GutConfig.new()
	config.options.crap_dirs = ["res://src", "res://lib"]
	config.options.crap_excludes = ["res://src/generated/*", "res://lib/vendor"]
	config.options.crap_threshold = 17.5
	config.options.crap_fail_on_threshold = true
	config.options.crap_json_file = "user://crap.json"
	config.options.double_strategy = GutUtils.get_enum_value(config.options.double_strategy, GutUtils.DOUBLE_STRATEGY)
	var gui = GutConfigGui.new(ctrl)
	gui.set_options(config.options)

	var options = gui.get_options(config.options)
	assert_eq(options.crap_dirs, ["res://src", "res://lib"])
	assert_eq(options.crap_excludes, ["res://src/generated/*", "res://lib/vendor"])
	assert_eq(options.crap_threshold, 17.5)
	assert_true(options.crap_fail_on_threshold)
	assert_eq(options.crap_json_file, "user://crap.json")
