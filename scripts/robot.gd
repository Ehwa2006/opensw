class_name Robot
extends CharacterBody3D
## 탐사로봇 R-7. 행동(이동/회전/대상으로 이동/줍기/열기/스캔)을 실행하고 센서 정보를 만든다.

signal moved(meters: float)
signal motion_done

const MOVE_SPEED := 1.1          # m/s
const TURN_SPEED := 80.0         # deg/s
const RADIUS := 0.35
const CAM_HEIGHT := 0.7
const SENSE_RANGE := 11.0

var level: LevelBuilder
var has_keycard := false
var camera: Camera3D
var spotlight: SpotLight3D

var _mode := ""
var _remaining := 0.0
var _sign := 1.0
var _travelled := 0.0
var _blocked_by := ""
var _abort := false
var _bob := 0.0


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = 0.8
	shape.shape = cyl
	shape.position.y = 0.45
	add_child(shape)

	camera = Camera3D.new()
	camera.position = Vector3(0, CAM_HEIGHT, -0.15)
	camera.fov = 72
	camera.near = 0.05
	camera.current = true
	add_child(camera)

	spotlight = SpotLight3D.new()
	spotlight.position = Vector3(0.12, -0.08, 0)
	spotlight.rotation.x = deg_to_rad(-9.0)
	spotlight.spot_range = 14.0
	spotlight.spot_angle = 38.0
	spotlight.spot_attenuation = 0.8
	spotlight.light_energy = 4.0
	spotlight.light_color = Color(0.95, 0.97, 1.0)
	spotlight.shadow_enabled = true
	camera.add_child(spotlight)

	var fill := OmniLight3D.new()
	fill.position = Vector3(0, 0.6, -0.3)
	fill.omni_range = 4.5
	fill.light_energy = 0.45
	add_child(fill)


func _physics_process(delta: float) -> void:
	if _mode != "" and _abort:
		_finish()
		return
	match _mode:
		"move":
			var step := minf(MOVE_SPEED * delta, _remaining)
			var dir := -global_transform.basis.z * _sign
			var col := move_and_collide(dir * step)
			var done_len := step if col == null else col.get_travel().length()
			_travelled += done_len
			_remaining -= done_len
			moved.emit(done_len)
			_bob += delta * 9.0
			camera.position.y = CAM_HEIGHT + sin(_bob) * 0.012
			if col:
				var other := col.get_collider()
				_blocked_by = String(other.get_meta("label", "무언가")) if other else "무언가"
				_finish()
			elif _remaining <= 0.001:
				_finish()
		"turn":
			var step := minf(deg_to_rad(TURN_SPEED) * delta, _remaining)
			rotate_y(step * _sign)
			_remaining -= step
			if _remaining <= 0.0001:
				_finish()


func _finish() -> void:
	_mode = ""
	camera.position.y = CAM_HEIGHT
	motion_done.emit()


func abort() -> void:
	_abort = true


func clear_abort() -> void:
	_abort = false


func is_aborted() -> bool:
	return _abort


# ---------------------------------------------------------------- 기본 동작

## meters > 0 앞으로, < 0 뒤로. 결과: {travelled, blocked}
func do_move(meters: float) -> Dictionary:
	if absf(meters) < 0.01 or _abort:
		return {"travelled": 0.0, "blocked": ""}
	_mode = "move"
	_sign = signf(meters)
	_remaining = absf(meters)
	_travelled = 0.0
	_blocked_by = ""
	await motion_done
	return {"travelled": _travelled, "blocked": _blocked_by}


## deg > 0 이면 왼쪽, < 0 이면 오른쪽
func do_turn(deg: float) -> void:
	if absf(deg) < 0.5 or _abort:
		return
	_mode = "turn"
	_sign = signf(deg)
	_remaining = deg_to_rad(absf(deg))
	await motion_done


# ---------------------------------------------------------------- 행동 실행

## 정규화된 행동 하나를 실행하고 사람이 읽을 결과 문장을 돌려준다.
func run_action(a: Dictionary) -> String:
	var t: String = a.get("type", "")
	var v: float = a.get("value", 0.0)
	match t:
		"move_forward", "move_backward":
			var dist := v if v > 0 else 2.0
			var r := await do_move(dist if t == "move_forward" else -dist)
			var word := "앞으로" if t == "move_forward" else "뒤로"
			if r["blocked"] != "":
				return "⚠ %s 이동 중 %s에 막혀 %.1fm에서 멈춤" % [word, r["blocked"], r["travelled"]]
			if _abort:
				return "정지 (%s %.1fm 이동)" % [word, r["travelled"]]
			return "%s %.1fm 이동" % [word, r["travelled"]]
		"turn_left", "turn_right":
			var deg := v if v > 0 else 90.0
			await do_turn(deg if t == "turn_left" else -deg)
			return "%s으로 %d° 회전" % ["왼쪽" if t == "turn_left" else "오른쪽", roundi(deg)]
		"go_to":
			return await _go_to(String(a.get("target", "")))
		"pick_up":
			return _pick_up()
		"open":
			return _open()
		"scan":
			await do_turn(360.0)
			return "주변 스캔 완료 — 감지 대상 %d개" % visible_objects().size()
		"wait":
			await get_tree().create_timer(1.0).timeout
			return "대기"
	return "⚠ 알 수 없는 행동: %s" % t


func _go_to(id: String) -> String:
	var obj := level.find_object(id)
	if obj.is_empty() or not _can_see(obj):
		return "⚠ [%s] 대상이 센서에 잡히지 않습니다" % id
	var kind: String = obj["kind"]
	var target: Vector3 = obj["pos"]
	if kind == "door":
		return await _pass_door(obj)
	await do_turn(-relative_angle(target))
	var to := target - global_position
	to.y = 0
	var stop := 0.0
	match kind:
		"prop", "key": stop = float(obj["radius"]) + RADIUS + 0.35
		"exit": stop = -2.0 if level.exit_open else 1.0
	var r := await do_move(maxf(to.length() - stop, 0.0))
	if r["blocked"] != "":
		return "⚠ %s(으)로 가다가 %s에 막혀 %.1fm에서 멈춤" % [obj["name"], r["blocked"], r["travelled"]]
	return "[%s] %s 앞에 도착" % [obj["id"], obj["name"]]


## 출입구 통과: 로봇 쪽 바로 앞 칸 중앙으로 간 뒤, 출입구 축을 따라 곧게 지나간다.
func _pass_door(obj: Dictionary) -> String:
	var center: Vector3 = obj["pos"]
	center.y = 0
	var axis: Vector3 = obj["axis"]
	var side := axis if (global_position - center).dot(axis) > 0 else -axis
	var approach := center + side * LevelBuilder.CELL
	if _flat_dist(approach) > 0.3:
		await do_turn(-relative_angle(approach))
		var r := await do_move(_flat_dist(approach))
		if r["blocked"] != "":
			return "⚠ 출입구로 가다가 %s에 막혀 %.1fm에서 멈춤" % [r["blocked"], r["travelled"]]
	if _abort:
		return "정지"
	var fwd := -global_transform.basis.z
	await do_turn(rad_to_deg(fwd.signed_angle_to(-side, Vector3.UP)))
	var r2 := await do_move(LevelBuilder.CELL + 2.4)
	if r2["blocked"] != "":
		return "⚠ 출입구를 지나다 %s에 막힘" % r2["blocked"]
	return "[%s] 출입구 통과 → %s" % [obj["id"], level.room_name_at(global_position)]


func _pick_up() -> String:
	var key := level.find_object("K")
	if not key.is_empty() and _flat_dist(key["pos"]) < float(key["radius"]) + 1.3:
		has_keycard = true
		level.take_keycard()
		return "보안 카드키를 집었습니다!"
	return "⚠ 손이 닿는 곳에 주울 만한 물건이 없습니다"


func _open() -> String:
	var ex := level.find_object("EXIT")
	if not ex.is_empty() and _flat_dist(ex["pos"]) < 2.6:
		return level.open_exit(has_keycard)
	for o in level.objects:
		if o["kind"] == "door" and _flat_dist(o["pos"]) < 2.5:
			return "이 출입구는 문짝이 없어 이미 열려 있습니다"
	return "⚠ 가까이에 열 수 있는 문이 없습니다"


# ---------------------------------------------------------------- 센서

func _flat_dist(p: Vector3) -> float:
	return Vector2(p.x - global_position.x, p.z - global_position.z).length()


## 오른쪽이 +, 왼쪽이 - (도)
func relative_angle(p: Vector3) -> float:
	var fwd := -global_transform.basis.z
	fwd.y = 0
	var to := p - global_position
	to.y = 0
	return -rad_to_deg(fwd.signed_angle_to(to, Vector3.UP))


static func dir_text(right_deg: float) -> String:
	var a := absf(right_deg)
	if a < 10:
		return "정면"
	if a > 165:
		return "바로 뒤"
	return "%s %d°" % ["오른쪽" if right_deg > 0 else "왼쪽", roundi(a)]


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


func _can_see(obj: Dictionary) -> bool:
	if obj.get("taken", false):
		return false
	var target: Vector3 = obj["pos"]
	if _flat_dist(target) > SENSE_RANGE:
		return false
	var from := global_position + Vector3(0, 0.6, 0)
	var points: Array[Vector3] = [target]
	if obj["kind"] == "door":
		# 출입구는 양쪽 입구 면 중 하나만 보여도 감지
		var axis: Vector3 = obj["axis"]
		points.append(target + axis * 1.4)
		points.append(target - axis * 1.4)
	for p in points:
		var hit := _ray(from, p)
		if hit.is_empty():
			return true
		if obj.has("body") and hit["collider"] == obj["body"]:
			return true
		if from.distance_to(hit["position"]) > from.distance_to(p) - 0.4:
			return true
	return false


## 센서 범위 안에서 보이는 대상들 (가까운 순)
func visible_objects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for o in level.objects:
		if _can_see(o):
			out.append({"id": o["id"], "name": o["name"], "kind": o["kind"],
				"right_deg": relative_angle(o["pos"]), "dist": _flat_dist(o["pos"])})
	out.sort_custom(func(a, b): return a["dist"] < b["dist"])
	return out


func _probe(dir: Vector3) -> String:
	var from := global_position + Vector3(0, 0.4, 0)
	var hit := _ray(from, from + dir * 15.0)
	if hit.is_empty():
		return "15m 이상 트임"
	var who := String((hit["collider"] as Object).get_meta("label", "무언가"))
	return "%.1fm(%s)" % [from.distance_to(hit["position"]) - RADIUS, who]


## LLM에게 넘길 센서 요약
func sense_text(battery: float) -> String:
	var b := global_transform.basis
	var lines := PackedStringArray()
	lines.append("[센서]")
	lines.append("위치: %s | 배터리: %d%% | 카드키: %s" % [level.room_name_at(global_position),
		roundi(battery), "보유" if has_keycard else "없음"])
	lines.append("장애물 거리: 앞 %s, 왼쪽 %s, 오른쪽 %s, 뒤 %s" % [
		_probe(-b.z), _probe(-b.x), _probe(b.x), _probe(b.z)])
	var vis := visible_objects()
	if vis.is_empty():
		lines.append("감지된 대상: 없음")
	else:
		lines.append("감지된 대상 (ID, 이름, 방향, 거리):")
		for o in vis.slice(0, 9):
			lines.append("[%s] %s - %s, %.1fm" % [o["id"], o["name"], dir_text(o["right_deg"]), o["dist"]])
	return "\n".join(lines)
