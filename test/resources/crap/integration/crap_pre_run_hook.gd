extends GutHookScript


func run():
	var Subject = load("res://test/resources/crap/lifecycle/lifecycle_subject.gd")
	Subject.new().from_pre_run()
