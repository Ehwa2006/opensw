extends SceneTree
## 개발용: 여러 위치에서 로봇 카메라 화면을 캡처한다.
## xvfb-run godot --rendering-method gl_compatibility -s res://tools/screenshot.gd -- --autotest <출력폴더>

const SHOTS := [
	["cupboard", Vector3(27, 0, 22.5), 180.0],
	["medrack", Vector3(9, 0, 24), 180.0],
	["morguebox", Vector3(39, 0, 7.5), 0.0],
	["keycard", Vector3(42, 0, 7.6), 180.0],
	["start", Vector3(3, 0, 3), 180.0],
	["storage_door", Vector3(4, 0, 4), 200.0],
	["corridor", Vector3(8, 0, 15), -90.0],
	["ward", Vector3(24, 0, 8), 160.0],
	["morgue", Vector3(37, 0, 8), -60.0],
	["surgery", Vector3(9, 0, 22), 120.0],
	["office", Vector3(25, 0, 21), 180.0],
	["lobby_exit", Vector3(41, 0, 23), -90.0],
]


func _init() -> void:
	var out := OS.get_cmdline_user_args()[-1]
	var game: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	for i in 10:
		await process_frame
	for s in SHOTS:
		game.robot.global_position = s[1]
		game.robot.rotation.y = deg_to_rad(s[2])
		for i in 20:
			await process_frame
		root.get_viewport().get_texture().get_image().save_jpg("%s/%s.jpg" % [out, s[0]], 0.85)
		print("saved ", s[0])
	quit()
