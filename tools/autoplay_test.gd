extends SceneTree
## 자동 플레이 테스트: 오프라인 해석기로 시작 → 카드키 → 비상구 탈출까지 실제 물리로 진행한다.
## godot --headless -s res://tools/autoplay_test.gd -- --autotest

const ORDERS := [
	"문 열어",                 # 열 문이 없음 (경고만)
	"D1",                     # 창고 → 복도
	"왼쪽으로 돌아",
	"앞으로 10미터",
	"앞으로 10미터",
	"D3",                     # 복도 → 영안실
	"카드 주워",
	"D3",                     # 영안실 → 복도
	"D6",                     # 복도 → 로비
	"문 열어",
	"비상구로 나가",
]


func _init() -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await physics_frame
	game.offline = true
	for order in ORDERS:
		print("\n>>> ", order)
		print(game.robot.sense_text(game.battery))
		await game.submit_order(order)
		print("결과: ", game.last_results)
		await physics_frame
		await physics_frame
	print("\n상태=%s  배터리=%.1f  카드키=%s  위치=%s" % [game.state, game.battery, game.robot.has_keycard, game.robot.global_position])
	print("AUTOPLAY ", "PASS" if game.state == "win" else "FAIL")
	quit(0 if game.state == "win" else 1)
