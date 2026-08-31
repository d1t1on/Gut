extends GutHookScript


func run():
	gut.set_meta("post_hook_crap_status", gut.get_crap_report().status)
