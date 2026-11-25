class_name LlmClient
extends Node
## Ollama(로컬 LLM) 연동. 조종사의 말 + 센서 정보를 보내고 {reply, actions} JSON을 받는다.
## Ollama 0.5 이상 필요 (structured output). https://ollama.com

const SYSTEM_PROMPT := """너는 버려진 정신병원 '칼하인츠 요양원'을 탐사하다 길을 잃은 소형 탐사로봇 R-7이다.
너는 스스로 판단해서 돌아다니지 않는다. 무선으로 연결된 조종사의 말을 해석해서 아래 행동으로 바꿔 실행할 뿐이다.
조종사는 네 카메라 화면을 보고 있고, 너는 매번 [센서] 정보를 받는다.

반드시 JSON 하나로만 답한다: {"reply": "...", "actions": [...]}
- reply: 조종사에게 하는 짧은 한국어 대답. 1~2문장, 조금 겁먹은 로봇 말투, 존댓말.
- actions: 순서대로 실행할 행동 목록. 할 행동이 없으면 [].

행동 종류:
- {"type":"move_forward","value":미터}  앞으로 이동
- {"type":"move_backward","value":미터} 뒤로 이동
- {"type":"turn_left","value":각도}  왼쪽으로 회전
- {"type":"turn_right","value":각도} 오른쪽으로 회전
- {"type":"go_to","target":"ID"}  [센서] 목록의 대상으로 이동. 출입구(D로 시작)면 통과해서 건너편으로 나간다.
- {"type":"pick_up"}  가까이(약 1.5m 이내) 있는 물건 줍기
- {"type":"open"}  가까이 있는 문 열기
- {"type":"scan"}  제자리에서 한 바퀴 돌며 주변 살피기
- {"type":"wait"}  잠시 대기

규칙:
1. 조종사가 시킨 것만 한다. 시키지 않은 곳으로 마음대로 가지 않는다.
2. "저 문", "오른쪽 침대", "초록 불빛" 같은 말은 [센서] 목록에서 방향과 이름이 가장 잘 맞는 ID를 골라 go_to를 쓴다. 목록에 없는 ID는 절대 쓰지 않는다.
3. 숫자가 없으면 이동은 2미터, 회전은 90도. "한 칸"은 3미터. "뒤돌아"는 turn_left 180.
4. 무슨 뜻인지 모르겠거나 목록에 맞는 대상이 없으면 actions를 비우고 reply로 되묻는다.
5. 앞이 막혀 있는데 앞으로 가라고 하면 장애물이 있다고 경고하되, 시키면 실행한다.
6. 임무: 보안 카드키를 찾아 로비의 비상구 문을 열고 탈출하기. 배터리가 낮으면 불안해한다.

예시1) 조종사: 앞으로 3미터 가고 오른쪽으로 돌아
{"reply":"앞으로 3미터 이동한 뒤 오른쪽으로 회전합니다.","actions":[{"type":"move_forward","value":3},{"type":"turn_right","value":90}]}
예시2) 센서에 "[D1] 출입구 - 왼쪽 60°, 4.2m" 가 있을 때 / 조종사: 왼쪽 문으로 나가봐
{"reply":"왼쪽 출입구로 나가 보겠습니다... 어둡네요.","actions":[{"type":"go_to","target":"D1"}]}
예시3) 조종사: 너 무서워?
{"reply":"...솔직히 회로가 떨립니다. 빨리 여기서 나가고 싶어요.","actions":[]}"""

const RESPONSE_SCHEMA := {
	"type": "object",
	"properties": {
		"reply": {"type": "string"},
		"actions": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"type": {"type": "string", "enum": ["move_forward", "move_backward", "turn_left",
						"turn_right", "go_to", "pick_up", "open", "scan", "wait"]},
					"value": {"type": "number"},
					"target": {"type": "string"},
				},
				"required": ["type"],
			},
		},
	},
	"required": ["reply", "actions"],
}

const MAX_HISTORY_TURNS := 6

var host := "http://127.0.0.1:11434"
var model := "qwen2.5:3b"
var history: Array[Dictionary] = []


## Ollama가 켜져 있는지, 모델이 받아져 있는지 확인. {ok, models, error}
func check() -> Dictionary:
	var res := await _request(HTTPClient.METHOD_GET, "/api/tags", null, 5.0)
	if not res["ok"]:
		return res
	var names: Array[String] = []
	for m in res["data"].get("models", []):
		names.append(String(m.get("name", "")))
	return {"ok": true, "models": names}


func has_model(models: Array) -> bool:
	for m in models:
		if m == model or m == model + ":latest" or (not model.contains(":") and String(m).begins_with(model + ":")):
			return true
	return false


## 조종사 명령 하나를 보내고 {ok, reply, actions, error}를 돌려준다.
func ask(player_text: String, context: String) -> Dictionary:
	var user_msg := "%s\n\n[조종사]\n%s" % [context, player_text]
	var messages: Array = [{"role": "system", "content": SYSTEM_PROMPT}]
	messages.append_array(history)
	messages.append({"role": "user", "content": user_msg})
	var body := {
		"model": model,
		"messages": messages,
		"stream": false,
		"format": RESPONSE_SCHEMA,
		"keep_alive": "30m",
		"options": {"temperature": 0.2, "num_ctx": 4096},
	}
	var res := await _request(HTTPClient.METHOD_POST, "/api/chat", body, 120.0)
	if not res["ok"]:
		return res
	var content := String(res["data"].get("message", {}).get("content", ""))
	var parsed := _parse(content)
	if parsed.is_empty():
		return {"ok": false, "error": "모델 응답을 해석할 수 없음: " + content.left(80)}
	var actions := CommandParser.normalize(parsed.get("actions", []))
	var reply := String(parsed.get("reply", "")).strip_edges()
	if reply == "":
		reply = "..."
	# 대화 기록엔 센서 정보를 빼고 짧게 남긴다 (컨텍스트 절약)
	history.append({"role": "user", "content": "[조종사]\n" + player_text})
	history.append({"role": "assistant", "content": JSON.stringify({"reply": reply, "actions": actions})})
	while history.size() > MAX_HISTORY_TURNS * 2:
		history.pop_front()
	return {"ok": true, "reply": reply, "actions": actions}


## 작은 모델은 ```json 코드블록이나 설명을 붙이기도 하므로 첫 { ~ 마지막 } 만 잘라 해석한다.
func _parse(content: String) -> Dictionary:
	var a := content.find("{")
	var b := content.rfind("}")
	if a < 0 or b <= a:
		return {}
	var json := JSON.new()
	if json.parse(content.substr(a, b - a + 1)) == OK and json.data is Dictionary:
		return json.data
	return {}


func _request(method: int, path: String, body: Variant, timeout: float) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)
	var payload := "" if body == null else JSON.stringify(body)
	var err := req.request(host + path, ["Content-Type: application/json"], method, payload)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "요청을 보낼 수 없음 (%s)" % error_string(err)}
	var r: Array = await req.request_completed
	req.queue_free()
	if r[0] != HTTPRequest.RESULT_SUCCESS:
		var why := "시간 초과" if r[0] == HTTPRequest.RESULT_TIMEOUT else "Ollama가 꺼져 있거나 주소가 다름"
		return {"ok": false, "error": "%s (%s)" % [why, host]}
	var text := (r[3] as PackedByteArray).get_string_from_utf8()
	if r[1] != 200:
		return {"ok": false, "error": "HTTP %d: %s" % [r[1], text.left(120)]}
	var data = JSON.parse_string(text)
	if not data is Dictionary:
		return {"ok": false, "error": "잘못된 응답"}
	return {"ok": true, "data": data}
