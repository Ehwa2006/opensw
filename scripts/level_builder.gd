class_name LevelBuilder
extends Node3D
## ASCII 지도로 버려진 정신병원 맵을 만든다.
## 바닥/벽/천장 메시, 충돌체, 프롭(Abandoned Asylum 에셋), 조명, 카드키, 비상구 문을 생성한다.

const CELL := 3.0
const WALL_H := 3.2

## 지도 기호
##  #  벽            .  바닥          S  로봇 시작 위치(남쪽을 봄)
##  D  출입구         E  비상구(잠긴 문, 카드키 필요)
##  나머지 글자는 PROPS 참고 (k = 카드키가 놓인 탁자)
const MAP: Array[String] = [
	"#################",
	"#S..x#.b.b.#M..M#",
	"#....#.....#.m.f#",
	"#x...#.b.b.#..k.#",
	"##D#####D###D####",
	"#...............#",
	"###D#####D###D###",
	"#.....#.....#...#",
	"#.s.c.#.t.o.#.w.E",
	"#..r..#..u..#h..#",
	"#################",
]

const ROOMS: Array[Dictionary] = [
	{"name": "창고", "rect": Rect2i(1, 1, 4, 3), "floor": "floor_room", "wall": "wall", "light": ""},
	{"name": "병실", "rect": Rect2i(6, 1, 5, 3), "floor": "floor_room", "wall": "wall", "light": "flicker"},
	{"name": "영안실", "rect": Rect2i(12, 1, 4, 3), "floor": "floor_medical", "wall": "wall_medical", "light": "cold"},
	{"name": "복도", "rect": Rect2i(1, 5, 15, 1), "floor": "floor_corridor", "wall": "wall", "light": "corridor"},
	{"name": "수술실", "rect": Rect2i(1, 7, 5, 3), "floor": "floor_medical", "wall": "wall_medical", "light": ""},
	{"name": "원장실", "rect": Rect2i(7, 7, 5, 3), "floor": "floor_room", "wall": "wall", "light": "warm"},
	{"name": "로비", "rect": Rect2i(13, 7, 3, 3), "floor": "floor_corridor", "wall": "wall", "light": "flicker"},
]

## model: assets/models/<model>.fbx, h: 목표 높이(m), wall: 가장 가까운 벽에 붙여 배치
const PROPS := {
	"x": {"model": "Box_V1", "name": "나무 상자", "h": 0.6},
	"b": {"model": "Bed", "name": "환자 침대", "h": 0.9},
	"m": {"model": "MorgueWheelBed", "name": "시신 운반 침대", "h": 0.9},
	"M": {"model": "MorgueBox", "name": "시신 냉동 보관함", "h": 2.3, "wall": true},
	"f": {"model": "MorgueTable", "name": "부검대", "h": 0.9},
	"s": {"model": "SurgeryTable", "name": "수술 도구대", "h": 1.0},
	"c": {"model": "SurgeryChair", "name": "수술 의자", "h": 1.2},
	"r": {"model": "MedRack", "name": "약품 선반", "h": 1.9, "wall": true},
	"t": {"model": "TableOffice", "name": "원장 책상", "h": 0.8},
	"o": {"model": "ChairOffice", "name": "사무용 의자", "h": 1.1},
	"u": {"model": "Cupboard", "name": "찬장", "h": 2.1, "wall": true},
	"w": {"model": "WheelChair", "name": "휠체어", "h": 1.0},
	"h": {"model": "Bench", "name": "대기용 벤치", "h": 0.75, "wall": true},
	"k": {"model": "TableSmall", "name": "작은 탁자", "h": 0.55},
}

const DIRS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

## 센서가 감지할 수 있는 대상 목록.
## { id, name, kind("door"/"prop"/"key"/"exit"), pos(Vector3), radius, body, axis(출입구) }
var objects: Array[Dictionary] = []
var start_position := Vector3.ZERO
var start_yaw := 0.0
var exit_open := false
var exit_win_x := 0.0
var flicker_lights: Array[OmniLight3D] = []

var _mat_data := {}
var _materials := {}
var _surface_tools := {}
var _exit_pivot: Node3D
var _exit_shape: CollisionShape3D
var _keycard: Node3D
var _key_light: OmniLight3D
var _time := 0.0
var _rng := RandomNumberGenerator.new()


func build() -> void:
	_rng.seed = 7
	_mat_data = JSON.parse_string(FileAccess.get_file_as_string("res://assets/materials.json"))
	_build_environment()
	_build_cells()
	_build_wall_mesh()
	_build_wall_collision()


func _process(delta: float) -> void:
	_time += delta
	for l in flicker_lights:
		var base: float = l.get_meta("base_energy")
		var n := sin(_time * 23.0 + l.get_instance_id()) * sin(_time * 7.3) + _rng.randf() * 0.3
		l.light_energy = base * (0.15 if n > 0.75 else 1.0)
	if _key_light and _keycard and _keycard.visible:
		_key_light.light_energy = 0.6 + 0.5 * sin(_time * 4.0)


# ---------------------------------------------------------------- 좌표 유틸

func cell(c: int, r: int) -> String:
	if r < 0 or r >= MAP.size() or c < 0 or c >= MAP[r].length():
		return "#"
	return MAP[r][c]


func is_wall(c: int, r: int) -> bool:
	return cell(c, r) == "#"


func cell_center(c: int, r: int) -> Vector3:
	return Vector3(c * CELL, 0.0, r * CELL)


func room_at_cell(c: int, r: int) -> Dictionary:
	for room in ROOMS:
		if (room["rect"] as Rect2i).has_point(Vector2i(c, r)):
			return room
	return {}


func room_name_at(pos: Vector3) -> String:
	var c := roundi(pos.x / CELL)
	var r := roundi(pos.z / CELL)
	match cell(c, r):
		"D": return "출입구"
		"E": return "비상구 밖"
	var room := room_at_cell(c, r)
	return room.get("name", "알 수 없는 곳")


func find_object(id: String) -> Dictionary:
	for o in objects:
		if String(o["id"]).to_upper() == id.strip_edges().to_upper() and not o.get("taken", false):
			return o
	return {}


# ---------------------------------------------------------------- 머티리얼

func get_material(key: String) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.resource_name = key
	mat.roughness = 0.85
	var d: Dictionary = _mat_data.get(key, {})
	if d.has("color"):
		var c: Array = d["color"]
		mat.albedo_color = Color(c[0], c[1], c[2])
	if d.has("albedo"):
		mat.albedo_texture = load(d["albedo"])
	if d.has("normal"):
		mat.normal_enabled = true
		mat.normal_texture = load(d["normal"])
		mat.normal_scale = 0.8
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_materials[key] = mat
	return mat


func _apply_prop_materials(node: Node) -> void:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(s)
			var key := src.resource_name if src else ""
			if _mat_data.has(key):
				m.set_surface_override_material(s, get_material(key))


# ---------------------------------------------------------------- 환경

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.55)
	env.ambient_light_energy = 0.14
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.1
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.ssao_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.06, 0.06)
	env.fog_density = 0.035
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.7, 0.75, 0.7)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


# ---------------------------------------------------------------- 셀 단위 생성

func _build_cells() -> void:
	var door_n := 0
	var prop_n := 0
	for r in MAP.size():
		for c in MAP[r].length():
			var ch := cell(c, r)
			if ch == "#":
				continue
			var center := cell_center(c, r)
			var room := room_at_cell(c, r)
			var floor_key: String = room.get("floor", "floor_corridor")
			var wall_key: String = room.get("wall", "wall")
			_add_floor_and_ceiling(center, floor_key)
			for d in DIRS:
				if is_wall(c + d.x, r + d.y):
					_add_wall_face(center, d, wall_key)
			match ch:
				"S":
					start_position = center
					start_yaw = PI  # 남쪽(+Z)을 바라봄
				"D":
					door_n += 1
					var axis := Vector3(0, 0, 1) if is_wall(c - 1, r) else Vector3(1, 0, 0)
					objects.append({"id": "D%d" % door_n, "name": "출입구", "kind": "door",
						"pos": center + Vector3(0, 1.2, 0), "radius": 0.0, "axis": axis})
				"E":
					_build_exit(c, r)
				_:
					if PROPS.has(ch):
						prop_n += 1
						var def: Dictionary = PROPS[ch]
						var body := _spawn_prop(def, c, r)
						var radius: float = body.get_meta("radius")
						objects.append({"id": "P%d" % prop_n, "name": def["name"], "kind": "prop",
							"pos": body.global_position + Vector3(0, minf(def["h"] * 0.5, 0.5), 0),
							"radius": radius, "body": body})
						if ch == "k":
							_build_keycard(body)
	for room in ROOMS:
		_build_room_light(room)


func _add_floor_and_ceiling(center: Vector3, floor_key: String) -> void:
	var h := CELL * 0.5
	var a := center + Vector3(-h, 0, -h)
	var b := center + Vector3(h, 0, -h)
	var c := center + Vector3(h, 0, h)
	var d := center + Vector3(-h, 0, h)
	var uv := func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) / CELL
	_quad(floor_key, [a, b, c, d], [uv.call(a), uv.call(b), uv.call(c), uv.call(d)], Vector3.UP)
	var up := Vector3(0, WALL_H, 0)
	_quad("ceiling", [a + up, d + up, c + up, b + up],
		[uv.call(a), uv.call(d), uv.call(c), uv.call(b)], Vector3.DOWN)


func _add_wall_face(center: Vector3, d: Vector2i, wall_key: String) -> void:
	var n := Vector3(d.x, 0, d.y)
	var side := Vector3(-d.y, 0, d.x)  # 벽면을 따라가는 방향
	var base := center + n * (CELL * 0.5)
	var h := CELL * 0.5
	var p0 := base - side * h
	var p1 := base + side * h
	var up := Vector3(0, WALL_H, 0)
	var u0 := (p0.x + p0.z) / CELL
	var u1 := (p1.x + p1.z) / CELL
	var v := WALL_H / CELL
	_quad(wall_key, [p0, p1, p1 + up, p0 + up],
		[Vector2(u0, v), Vector2(u1, v), Vector2(u1, 0), Vector2(u0, 0)], -n)


func _quad(key: String, pts: Array, uvs: Array, normal: Vector3) -> void:
	if not _surface_tools.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surface_tools[key] = st
	var st: SurfaceTool = _surface_tools[key]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(normal)
		st.set_uv(uvs[i])
		st.add_vertex(pts[i])


func _build_wall_mesh() -> void:
	for key in _surface_tools:
		var st: SurfaceTool = _surface_tools[key]
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.name = "Level_" + key
		mi.mesh = st.commit()
		var mat := get_material(key).duplicate() as StandardMaterial3D
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		add_child(mi)


func _build_wall_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "Walls"
	body.set_meta("label", "벽")
	add_child(body)
	for r in range(-1, MAP.size() + 1):
		for c in range(-1, MAP[0].length() + 1):
			if not is_wall(c, r):
				continue
			var touches_floor := false
			for d in DIRS:
				if not is_wall(c + d.x, r + d.y):
					touches_floor = true
			if not touches_floor:
				continue
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(CELL, WALL_H, CELL)
			shape.shape = box
			shape.position = cell_center(c, r) + Vector3(0, WALL_H * 0.5, 0)
			body.add_child(shape)


# ---------------------------------------------------------------- 프롭

func _scene_aabb(node: Node, xf: Transform3D, acc: Array) -> void:
	var t := xf
	if node is Node3D:
		t = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var b: AABB = t * (node as MeshInstance3D).mesh.get_aabb()
		acc[0] = b if acc[0] == null else (acc[0] as AABB).merge(b)
	for ch in node.get_children():
		_scene_aabb(ch, t, acc)


## FBX 모델을 불러와 목표 높이로 크기를 맞추고, 상자 충돌체를 붙인다.
func make_model(model: String, target_h: float) -> StaticBody3D:
	var ps: PackedScene = load("res://assets/models/%s.fbx" % model)
	var inst: Node3D = ps.instantiate()
	_apply_prop_materials(inst)
	var acc := [null]
	_scene_aabb(inst, Transform3D.IDENTITY, acc)
	var aabb: AABB = acc[0]
	var s := target_h / maxf(aabb.size.y, 0.0001)
	inst.scale = Vector3.ONE * s
	inst.position = -Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z) * s
	var body := StaticBody3D.new()
	body.add_child(inst)
	var size := aabb.size * s
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = Vector3(0, size.y * 0.5, 0)
	body.add_child(shape)
	body.set_meta("size", size)
	body.set_meta("radius", maxf(size.x, size.z) * 0.5)
	return body


func _spawn_prop(def: Dictionary, c: int, r: int) -> StaticBody3D:
	var body := make_model(def["model"], def["h"])
	body.name = "Prop_%s_%d_%d" % [def["model"], c, r]
	body.set_meta("label", def["name"])
	add_child(body)
	var pos := cell_center(c, r)
	var yaw := _rng.randf_range(-0.25, 0.25)
	if def.get("wall", false):
		var size: Vector3 = body.get_meta("size")
		for d in DIRS:
			if is_wall(c + d.x, r + d.y):
				pos += Vector3(d.x, 0, d.y) * (CELL * 0.5 - size.z * 0.5 - 0.05)
				# 모델 앞면(+Z)이 벽 반대쪽을 보도록
				yaw = atan2(d.x, d.y)
				break
	body.position = pos
	body.rotation.y = yaw
	return body


func _build_keycard(table: StaticBody3D) -> void:
	var size: Vector3 = table.get_meta("size")
	_keycard = Node3D.new()
	_keycard.name = "Keycard"
	table.add_child(_keycard)
	_keycard.position = Vector3(0, size.y + 0.01, 0)
	var card := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.26, 0.015, 0.17)
	card.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.9, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 1.0, 0.45)
	mat.emission_energy_multiplier = 1.2
	card.material_override = mat
	card.rotation.y = 0.4
	_keycard.add_child(card)
	_key_light = OmniLight3D.new()
	_key_light.light_color = Color(0.3, 1.0, 0.5)
	_key_light.omni_range = 2.5
	_key_light.position = Vector3(0, 0.3, 0)
	_keycard.add_child(_key_light)
	objects.append({"id": "K", "name": "보안 카드키(초록 불빛)", "kind": "key",
		"pos": table.global_position + Vector3(0, size.y, 0), "radius": table.get_meta("radius"), "body": table})


func take_keycard() -> void:
	if _keycard:
		_keycard.visible = false
	var o := find_object("K")
	if not o.is_empty():
		o["taken"] = true


# ---------------------------------------------------------------- 조명

func _build_room_light(room: Dictionary) -> void:
	var kind: String = room["light"]
	if kind == "":
		return
	var rect: Rect2i = room["rect"]
	var spots: Array[Vector3] = []
	if kind == "corridor":
		for c in [3, 8, 13]:
			spots.append(cell_center(c, rect.position.y))
	else:
		var mid := Vector2(rect.position) + Vector2(rect.size - Vector2i.ONE) * 0.5
		spots.append(Vector3(mid.x * CELL, 0, mid.y * CELL))
	var i := 0
	for p in spots:
		var lamp := make_model("SingleLight", 0.45)
		add_child(lamp)
		lamp.position = p + Vector3(0, WALL_H - 0.45, 0)
		var l := OmniLight3D.new()
		l.position = p + Vector3(0, WALL_H - 0.6, 0)
		l.omni_range = 7.0
		l.shadow_enabled = true
		match kind:
			"cold": l.light_color = Color(0.6, 0.9, 0.85); l.light_energy = 0.7
			"warm": l.light_color = Color(1.0, 0.75, 0.45); l.light_energy = 0.8
			_: l.light_color = Color(1.0, 0.88, 0.7); l.light_energy = 0.9
		l.set_meta("base_energy", l.light_energy)
		add_child(l)
		if kind == "flicker" or kind == "cold" or (kind == "corridor" and i == 1):
			flicker_lights.append(l)
		i += 1


# ---------------------------------------------------------------- 비상구

func _build_exit(c: int, r: int) -> void:
	# E 칸의 서쪽(안쪽) 면에 잠긴 문을 세운다. 문을 통과해 E 칸으로 들어가면 탈출.
	var center := cell_center(c, r)
	var face_x := center.x - CELL * 0.5
	exit_win_x = face_x + 0.6
	var door := make_model("MainDoor", 2.7)
	var size: Vector3 = door.get_meta("size")
	door.set_meta("label", "비상구 문")
	# 경첩 쪽을 축으로 열리도록 피벗 노드를 둔다
	_exit_pivot = Node3D.new()
	add_child(_exit_pivot)
	_exit_pivot.position = Vector3(face_x, 0, center.z - size.x * 0.5)
	_exit_pivot.add_child(door)
	door.rotation.y = PI * 0.5
	door.position = Vector3(0, 0, size.x * 0.5)
	_exit_shape = door.get_child(1) as CollisionShape3D
	# 문 양옆 틈을 메우는 기둥
	var gap := (CELL - size.x) * 0.5
	for sgn in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, WALL_H, gap)
		pillar.mesh = bm
		pillar.material_override = get_material("wall")
		pillar.position = Vector3(face_x, WALL_H * 0.5, center.z + sgn * (CELL * 0.5 - gap * 0.5))
		add_child(pillar)
	# 비상구 표지와 바깥의 달빛
	var sign := Label3D.new()
	sign.text = "비상구  EXIT"
	sign.font = load("res://assets/fonts/Galmuri11.ttf")
	sign.font_size = 64
	sign.pixel_size = 0.004
	sign.modulate = Color(0.3, 1.0, 0.45)
	sign.outline_size = 0
	sign.position = Vector3(face_x - 0.05, 2.95, center.z)
	sign.rotation.y = -PI * 0.5
	add_child(sign)
	var sl := OmniLight3D.new()
	sl.light_color = Color(0.3, 1.0, 0.45)
	sl.light_energy = 0.6
	sl.omni_range = 3.5
	sl.position = Vector3(face_x - 0.5, 2.7, center.z)
	add_child(sl)
	var moon := OmniLight3D.new()
	moon.light_color = Color(0.55, 0.65, 1.0)
	moon.light_energy = 1.5
	moon.omni_range = 5.0
	moon.position = center + Vector3(0.5, 2.0, 0)
	add_child(moon)
	objects.append({"id": "EXIT", "name": "비상구 문(잠김)", "kind": "exit",
		"pos": Vector3(face_x, 1.2, center.z), "radius": 0.3, "body": door})


## 카드키가 있으면 문을 연다. 결과 메시지를 돌려준다.
func open_exit(has_key: bool) -> String:
	if exit_open:
		return "문은 이미 열려 있습니다."
	if not has_key:
		return "⚠ 잠겨 있습니다. 문 옆에 카드키 판독기가 깜빡입니다."
	exit_open = true
	_exit_shape.disabled = true
	var o := find_object("EXIT")
	o["name"] = "비상구(열림)"
	var tw := create_tween()
	tw.tween_property(_exit_pivot, "rotation:y", deg_to_rad(-105), 1.6).set_trans(Tween.TRANS_SINE)
	return "삑— 카드키 인식. 비상구 문이 열렸습니다!"
