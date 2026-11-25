class_name CommandParser
extends RefCounted
## 1) LLM이 돌려준 행동 목록을 게임이 이해하는 형태로 정리(normalize)
## 2) LLM을 못 쓸 때 쓰는 간단한 한국어 규칙 기반 해석기(parse_offline)

const ACTION_TYPES := ["move_forward", "move_backward", "turn_left", "turn_right",
	"go_to", "pick_up", "open", "scan", "wait"]

const ALIASES := {
	"forward": "move_forward", "move": "move_forward", "go": "move_forward", "앞으로": "move_forward",
	"backward": "move_backward", "back": "move_backward", "뒤로": "move_backward",
	"left": "turn_left", "왼쪽": "turn_left", "right": "turn_right", "오른쪽": "turn_right",
	"goto": "go_to", "go_to_target": "go_to", "approach": "go_to", "move_to": "go_to",
	"pickup": "pick_up", "pick": "pick_up", "grab": "pick_up", "take": "pick_up",
	"open_door": "open", "use": "open", "look_around": "scan",
}


## LLM 출력 정리: 모르는 행동은 버리고, 값 범위를 제한한다.
static func normalize(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not raw is Array:
		return out
	for item in raw:
		if not item is Dictionary:
			continue
		var t := String(item.get("type", item.get("action", ""))).strip_edges().to_lower()
		t = ALIASES.get(t, t)
		if t not in ACTION_TYPES:
			continue
		var v := 0.0
		var raw_v = item.get("value", item.get("distance", item.get("degrees", 0)))
		if raw_v is float or raw_v is int:
			v = float(raw_v)
		elif raw_v is String and (raw_v as String).is_valid_float():
			v = (raw_v as String).to_float()
		if t == "move_forward" and v < 0:
			t = "move_backward"
		v = absf(v)
		if t.begins_with("move"):
			v = clampf(v if v > 0 else 2.0, 0.2, 12.0)
		elif t.begins_with("turn"):
			v = clampf(v if v > 0 else 90.0, 1.0, 360.0)
		var a := {"type": t, "value": v}
		if t == "go_to":
			var target := String(item.get("target", item.get("id", ""))).replace("[", "").replace("]", "")
			if target == "":
				continue
			a["target"] = target.strip_edges().to_upper()
		out.append(a)
		if out.size() >= 8:
			break
	return out


static func _has(text: String, words: Array) -> bool:
	for w in words:
		if text.contains(w):
			return true
	return false


static func _number(text: String) -> float:
	var re := RegEx.create_from_string("(\\d+(?:\\.\\d+)?)\\s*(칸|미터|m|도|°)?")
	var m := re.search(text)
	if m == null:
		return 0.0
	var n := m.get_string(1).to_float()
	if m.get_string(2) == "칸":
		n *= 3.0
	return n


## 방향 단어에 맞는 대상을 고른다 (왼/오른/앞 + 가장 가까운 것)
static func _pick_target(visible: Array, kinds: Array, text: String) -> String:
	var best := ""
	var best_score := INF
	for o in visible:
		if o["kind"] not in kinds:
			continue
		var ang: float = o["right_deg"]
		var score: float = o["dist"]
		if text.contains("왼") and ang > 0:
			score += 100
		elif text.contains("오른") and ang < 0:
			score += 100
		elif (text.contains("앞") or text.contains("정면")) and absf(ang) > 45:
			score += 50
		if score < best_score:
			best_score = score
			best = o["id"]
	return best


## 규칙 기반 해석기. visible = Robot.visible_objects()
static func parse_offline(text: String, visible: Array) -> Dictionary:
	var clauses := RegEx.create_from_string("그리고|그 ?다음|다음에|한 ?뒤에?|한 ?후에?|하고 나서|,|\\.|하고\\s").sub(text, "|", true).split("|", false)
	var actions: Array[Dictionary] = []
	var id_re := RegEx.create_from_string("(?i)\\b(D\\d+|P\\d+|K|EXIT)\\b")
	for raw_clause in clauses:
		var c := String(raw_clause).strip_edges()
		if c == "":
			continue
		var n := _number(c)
		var idm := id_re.search(c)
		if idm:
			actions.append({"type": "go_to", "target": idm.get_string(1).to_upper()})
		elif _has(c, ["주워", "줍", "집어", "챙겨", "가져"]):
			var key_seen := visible.any(func(o): return o["id"] == "K")
			if key_seen and not _has(c, ["여기", "바로"]):
				actions.append({"type": "go_to", "target": "K"})
			actions.append({"type": "pick_up"})
		elif _has(c, ["열어", "열기", "열자", "열어줘", "카드 대", "카드키 대"]):
			if visible.any(func(o): return o["id"] == "EXIT" and o["dist"] > 2.0):
				actions.append({"type": "go_to", "target": "EXIT"})
			actions.append({"type": "open"})
		elif _has(c, ["둘러", "스캔", "주변", "살펴", "한 바퀴"]):
			actions.append({"type": "scan"})
		elif _has(c, ["멈춰", "정지", "기다", "대기"]):
			actions.append({"type": "wait"})
		elif _has(c, ["뒤돌", "돌아서", "유턴", "반대로", "뒤로 돌"]):
			actions.append({"type": "turn_left", "value": 180.0})
		elif _has(c, ["카드", "키"]) and visible.any(func(o): return o["id"] == "K"):
			actions.append({"type": "go_to", "target": "K"})
		elif _has(c, ["비상구", "출구", "탈출", "철문", "나가"]) and visible.any(func(o): return o["id"] == "EXIT"):
			actions.append({"type": "go_to", "target": "EXIT"})
		elif _has(c, ["문", "출입구", "통로"]):
			var t := _pick_target(visible, ["door"], c)
			if t != "":
				actions.append({"type": "go_to", "target": t})
		elif _has(c, ["왼", "오른"]):
			var turn_t := "turn_left" if c.contains("왼") else "turn_right"
			var moving := _has(c, ["가", "이동", "전진", "미터", "칸"])
			var deg := n if (n > 0 and _has(c, ["도", "°"])) else 90.0
			actions.append({"type": turn_t, "value": deg})
			if moving and n > 0 and not _has(c, ["도", "°"]):
				actions.append({"type": "move_forward", "value": n})
		elif _has(c, ["뒤로", "후진", "물러", "빠꾸"]):
			actions.append({"type": "move_backward", "value": n if n > 0 else 1.0})
		elif _has(c, ["앞", "전진", "직진", "가", "이동", "go"]):
			actions.append({"type": "move_forward", "value": n if n > 0 else 2.0})
	var norm := normalize(actions)
	var reply := "(오프라인 해석) "
	reply += "명령을 이해하지 못했습니다. '앞으로 3미터', '왼쪽으로 돌아', '문으로 가' 처럼 말해 주세요." if norm.is_empty() else "알겠습니다, 실행합니다."
	return {"ok": true, "reply": reply, "actions": norm}
