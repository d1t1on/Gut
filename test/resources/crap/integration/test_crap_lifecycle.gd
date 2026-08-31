extends GutTest


func test_exercises_code_during_the_test_window():
	var Subject = load("res://test/resources/crap/lifecycle/lifecycle_subject.gd")
	assert_eq(Subject.new().from_test(), 2)
