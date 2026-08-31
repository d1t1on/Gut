extends GutTest


func test_exercises_the_instrumented_subject():
	var Subject = load("res://test/resources/crap/basic/risky_subject.gd")
	assert_eq(Subject.new().risky(1, true), 1)
