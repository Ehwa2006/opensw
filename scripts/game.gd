extends Node3D
## 게임 전체 흐름: 맵/로봇/LLM 생성, 텍스트 입력 → LLM → 행동 실행, 배터리, 승리/패배, 화면 UI.
## 화면에는 로봇 카메라 영상과 텍스트 입력창 두 가지만 띄운다.

const BATTERY_PER_METER := 0.55
const BATTERY_PER_SCAN := 1.0
const SETTINGS_PATH := "user://settings.cfg"

var level: LevelBuilder
var robot: Robot
var llm: LlmClient

var battery := 100.0
var busy := false
var offline := false
var state := "play"           # play / win / dead
var elapsed := 0.0
var glitch := 0.0
var last_results := PackedStringArray()
var _warned := {}

var _log: RichTextLabel
var _input: LineEdit
var _status: Label
var _osd_left: Label
var _osd_right: Label
var _overlay: Label
var _fx: ShaderMaterial
var _music: AudioStreamPlayer


func _ready() -> void:
	level = LevelBuilder.new()
	level.name = "Level"
	add_child(level)
	level.build()

	robot = Robot.new()
	robot.name = "R7"
	robot.level = level
	add_child(robot)
	robot.global_position = level.start_position
	robot.rotation.y = level.start_yaw
	robot.moved.connect(_on_robot_moved)

	llm = LlmClient.new()
	llm.name = "LLM"
	add_child(llm)
	_load_settings()

	_build_ui()
	_play_music("res://assets/audio/ambience_unsettling.ogg", -10.0)
	_intro()
	if not "--autotest" in OS.get_cmdline_user_args():
		_check_llm()


func _process(delta: float) -> void:
	if state == "play":
		elapsed += delta
	var base := 0.0
	if battery < 20.0:
		base = 0.12
	if state == "dead":
		base = 1.0
	glitch = move_toward(glitch, base, delta * 0.8)
	_fx.set_shader_parameter("glitch", glitch)
	_update_osd()


func _physics_process(_delta: float) -> void:
	if state == "play" and level.exit_open and robot.global_position.x > level.exit_win_x:
		_win()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("stop_robot") and busy:
		robot.abort()
		_say("[color=#ffb070]■ 정지 명령[/color]")


# ---------------------------------------------------------------- 명령 처리

func _on_submit(text: String) -> void:
	text = text.strip_edges()
	_input.clear()
	if text == "":
		return
	if text.begins_with("/"):
		_command(text)
		return
	if busy or state != "play":
		return
	await submit_order(text)


## 조종사 명령 하나를 처리한다 (테스트에서도 호출)
func submit_order(text: String) -> void:
	busy = true
	_input.editable = false
	_say("[color=#8fd8ff]▶ 조종사:[/color] " + text.replace("[", "[lb]"))
	var result: Dictionary
	if offline:
		result = CommandParser.parse_offline(text, robot.visible_objects())
	else:
		_set_status("R-7 응답 수신 중...")
		var ctx := robot.sense_text(battery)
		if not last_results.is_empty():
			ctx += "\n[직전 행동 결과]\n" + "\n".join(last_results)
		result = await llm.ask(text, ctx)
		if not result["ok"]:
			_say("[color=#ff9060]⚠ LLM 오류: %s → 오프라인 해석기로 처리[/color]" % result["error"])
			result = CommandParser.parse_offline(text, robot.visible_objects())
	_say("[color=#b8ffb0]R-7:[/color] " + String(result["reply"]).replace("[", "[lb]"))
	await _execute(result["actions"])
	busy = false
	_input.editable = true
	_input.grab_focus()
	_set_status("대기 중  |  Esc 정지  /help 도움말")


func _execute(actions: Array) -> void:
	last_results.clear()
	robot.clear_abort()
	for a in actions:
		if state != "play" or robot.is_aborted() or battery <= 0.0:
			break
		_set_status("실행 중: " + String(a["type"]))
		if a["type"] == "scan":
			_drain(BATTERY_PER_SCAN)
		var res := await robot.run_action(a)
		last_results.append(res)
		var color := "#ffb070" if res.begins_with("⚠") else "#9aa89a"
		_say("   [color=%s]· %s[/color]" % [color, res.replace("[", "[lb]")])
		if res.begins_with("⚠"):
			glitch = 0.55
	robot.clear_abort()


func _command(text: String) -> void:
	var parts := text.split(" ", false, 1)
	var cmd := parts[0].to_lower()
	var arg := parts[1].strip_edges() if parts.size() > 1 else ""
	match cmd:
		"/help":
			_say("[color=#cccccc]명령어: /model 이름  /host 주소  /online  /offline  /status  /sensor  /restart\n" +
				"Esc: 로봇 즉시 정지. 그 외의 말은 전부 R-7에게 전달됩니다.[/color]")
		"/model":
			if arg != "":
				llm.model = arg
				_save_settings()
			_say("모델: " + llm.model)
			_check_llm()
		"/host":
			if arg != "":
				llm.host = arg.trim_suffix("/")
				_save_settings()
			_say("Ollama 주소: " + llm.host)
			_check_llm()
		"/online", "/status":
			_check_llm()
		"/offline":
			offline = true
			_say("오프라인 해석기 모드 (간단한 명령만 이해합니다)")
		"/sensor":
			_say("[color=#9aa89a]" + robot.sense_text(battery).replace("[", "[lb]") + "[/color]")
		"/restart":
			get_tree().reload_current_scene()
		_:
			_say("알 수 없는 명령어입니다. /help")


func _check_llm() -> void:
	_set_status("Ollama 연결 확인 중...")
	var res := await llm.check()
	if not res["ok"]:
		offline = true
		_say("[color=#ff9060]⚠ Ollama에 연결할 수 없습니다 (%s).\n   오프라인 해석기로 진행합니다. Ollama를 켠 뒤 /online 을 입력하세요.[/color]" % llm.host)
	elif not llm.has_model(res["models"]):
		offline = true
		_say("[color=#ff9060]⚠ 모델 '%s'이(가) 없습니다. 터미널에서 [b]ollama pull %s[/b] 실행 후 /online\n   (설치된 모델: %s)[/color]" % [llm.model, llm.model, ", ".join(res["models"])])
	else:
		offline = false
		_say("[color=#7dffa0]● LLM 연결됨: %s[/color]" % llm.model)
	_set_status("대기 중  |  Esc 정지  /help 도움말")


# ---------------------------------------------------------------- 배터리 / 승패

func _on_robot_moved(meters: float) -> void:
	_drain(meters * BATTERY_PER_METER)


func _drain(amount: float) -> void:
	if state != "play":
		return
	battery = maxf(battery - amount, 0.0)
	for th in [30, 15]:
		if battery <= th and not _warned.has(th):
			_warned[th] = true
			_say("[color=#ff6050]⚠ 배터리 %d%% — 신호가 불안정합니다[/color]" % th)
			glitch = 0.7
	if battery <= 0.0:
		_lose()


func _lose() -> void:
	state = "dead"
	robot.abort()
	_say("[color=#ff4040]■ 배터리 방전. R-7과의 신호가 끊겼습니다.[/color]")
	_show_overlay("NO SIGNAL\n\n배터리 방전 — R-7 신호 두절\n/restart 로 다시 시작", Color(1, 0.3, 0.3))


func _win() -> void:
	state = "win"
	robot.abort()
	var t := "%02d:%02d" % [int(elapsed) / 60, int(elapsed) % 60]
	_say("[color=#7dffa0]★ R-7이 요양원 밖으로 탈출했습니다! (시간 %s, 남은 배터리 %d%%)[/color]" % [t, roundi(battery)])
	_show_overlay("SIGNAL RESTORED\n\nR-7 탈출 성공\n시간 %s  ·  배터리 %d%%\n\n/restart 로 다시 하기" % [t, roundi(battery)], Color(0.5, 1, 0.6))
	_play_music("res://assets/audio/escape_ending.ogg", -6.0)


# ---------------------------------------------------------------- UI

func _intro() -> void:
	_say("[color=#7dffa0]■ 원격 조종 채널 연결 — 탐사로봇 R-7[/color]")
	_say("R-7이 버려진 [b]칼하인츠 요양원[/b]을 탐사하다 길을 잃었습니다. 화면은 R-7의 카메라 영상입니다.")
	_say("R-7에게 [b]말로[/b] 지시해서 [color=#7dffa0]보안 카드키[/color]를 찾고, 로비의 [b]비상구 문[/b]을 열어 탈출시키세요. 배터리는 이동할수록 닳습니다.")
	_say("[color=#9aa89a]예) 앞으로 3미터 가 · 오른쪽으로 돌아 · 왼쪽에 있는 문으로 나가봐 · 주변 둘러봐 · 카드 주워 · 문 열어[/color]")


func _say(bbcode: String) -> void:
	_log.append_text(bbcode + "\n")


func _set_status(t: String) -> void:
	_status.text = t


func _update_osd() -> void:
	var rec := "●" if int(elapsed * 2.0) % 2 == 0 else "  "
	_osd_left.text = "%s REC   CAM-01  R-7\nT+%02d:%02d:%02d\nLOC: %s" % [rec, int(elapsed) / 3600,
		(int(elapsed) / 60) % 60, int(elapsed) % 60, level.room_name_at(robot.global_position)]
	var key := "\n[카드키 보유]" if robot.has_keycard else ""
	_osd_right.text = "BAT %3d%%%s" % [roundi(battery), key]
	_osd_right.modulate = Color(1, 0.35, 0.3) if battery < 20 else (Color(1, 0.85, 0.4) if battery < 45 else Color(0.75, 1, 0.8))


func _show_overlay(text: String, color: Color) -> void:
	_overlay.text = text
	_overlay.modulate = color
	_overlay.visible = true


func _build_ui() -> void:
	# 1) 로봇 카메라 효과 (화면 전체)
	var fx_layer := CanvasLayer.new()
	fx_layer.layer = 1
	add_child(fx_layer)
	var fx := ColorRect.new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx = ShaderMaterial.new()
	_fx.shader = load("res://shaders/robot_cam.gdshader")
	fx.material = _fx
	fx_layer.add_child(fx)

	# 2) 카메라 OSD + 텍스트 입력창
	var ui := CanvasLayer.new()
	ui.layer = 2
	add_child(ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	_osd_left = _make_label(root, 18, Color(0.75, 1, 0.8))
	_osd_left.position = Vector2(28, 20)
	_osd_right = _make_label(root, 22, Color(0.75, 1, 0.8))
	_osd_right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_osd_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_osd_right.position = Vector2(-228, 20)
	_osd_right.size = Vector2(200, 60)

	var cross := _make_label(root, 20, Color(0.75, 1, 0.8, 0.5))
	cross.text = "+"
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross.position = Vector2(-20, -14)
	cross.size = Vector2(40, 28)

	_overlay = _make_label(root, 34, Color.WHITE)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.offset_bottom = -200
	_overlay.visible = false

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_top = -232
	panel.offset_left = 16
	panel.offset_right = -16
	panel.offset_bottom = -14
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.03, 0.02, 0.72)
	sb.border_color = Color(0.3, 0.9, 0.5, 0.5)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 16)
	_log.add_theme_font_size_override("bold_font_size", 16)
	_log.add_theme_color_override("default_color", Color(0.85, 0.92, 0.86))
	vb.add_child(_log)

	var hb := HBoxContainer.new()
	vb.add_child(hb)
	var prompt := _make_label(hb, 18, Color(0.5, 1, 0.65))
	prompt.text = "R-7 >"
	_input = LineEdit.new()
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.placeholder_text = "로봇에게 지시하기... (Enter)"
	_input.add_theme_font_size_override("font_size", 18)
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0.1, 0.05, 0.8)
	isb.set_content_margin_all(6)
	_input.add_theme_stylebox_override("normal", isb)
	_input.add_theme_stylebox_override("focus", isb)
	_input.text_submitted.connect(_on_submit)
	hb.add_child(_input)
	_status = _make_label(hb, 14, Color(0.6, 0.75, 0.62))
	_status.text = "대기 중"
	_input.call_deferred("grab_focus")


func _make_label(parent: Control, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _play_music(path: String, db: float) -> void:
	if _music == null:
		_music = AudioStreamPlayer.new()
		add_child(_music)
	var s: AudioStreamOggVorbis = load(path)
	s.loop = true
	_music.stream = s
	_music.volume_db = db
	_music.play()


# ---------------------------------------------------------------- 설정 저장

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		llm.host = cfg.get_value("llm", "host", llm.host)
		llm.model = cfg.get_value("llm", "model", llm.model)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("llm", "host", llm.host)
	cfg.set_value("llm", "model", llm.model)
	cfg.save(SETTINGS_PATH)
