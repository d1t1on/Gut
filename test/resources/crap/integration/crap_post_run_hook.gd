extends GutHookScript


func run():
	var Subject = load("res://test/resources/crap/lifecycle/lifecycle_subject.gd")
	Subject.new().from_post_run()
	gut.set_meta("post_hook_crap_status", gut.get_crap_report().status)
