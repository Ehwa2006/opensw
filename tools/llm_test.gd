extends SceneTree
## 가짜 Ollama 서버(tools/mock_ollama.py)로 LLM 연동 경로를 검사한다.
## godot --headless -s res://tools/llm_test.gd -- --autotest http://127.0.0.1:11500


func _init() -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.llm.host = OS.get_cmdline_user_args()[-1]
	var chk: Dictionary = await game.llm.check()
	print("check: ", chk)
	game.offline = false
	var yaw0: float = game.robot.rotation_degrees.y
	await game.submit_order("왼쪽으로 돌고 2미터 가")
	print("results: ", game.last_results)
	print("history: ", game.llm.history.size())
	var ok: bool = chk["ok"] and game.last_results.size() == 2 \
		and game.last_results[0].contains("왼쪽") and game.last_results[1].contains("2.0m") \
		and absf(wrapf(game.robot.rotation_degrees.y - yaw0, -180, 180) - 90.0) < 1.0
	print("LLM_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
