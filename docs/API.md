# LOST SIGNAL 랭킹 서버 — 통합 계약서

게임(Godot) · 서버(FastAPI + Socket.IO) · DB가 주고받는 모든 데이터의 약속이다.
**이 문서와 `server/app/contract.py`가 기준**이며, 둘은 항상 같은 PR에서 함께 고친다.

| 담당 | 맡는 것 | 주로 만지는 파일 |
|---|---|---|
| Godot·LLM | 게임 로직, 서버 호출 클라이언트, 게임 이벤트 연결, 랭킹 UI | `scripts/*.gd`, `scripts/net/` |
| 서버 | REST 라우트, Socket.IO 처리·브로드캐스트 | `server/app/main.py` 등 |
| DB·통합 | 스키마, DB 함수, 이 계약서, 가짜 서버, 통합 점검 | `server/schema.sql`, `server/app/db.py`, `server/app/contract.py`, `tools/mock_server.py`, `tools/integration_check.py` |

규칙: **서버는 SQL을 직접 쓰지 않고 `app.db`의 함수만 호출한다.**

---

## 1. 공통 규칙

- 모든 본문은 UTF-8 JSON. 시간은 **초(float)**, 배터리는 **% (0~100)**.
- 정수 필드(`run_id`, `orders`)에 `3.0` 같은 float가 와도 받아 준다.
  Godot의 `JSON.parse_string`은 숫자를 전부 float로 돌려주기 때문이다. 그래도 보낼 때는 `int()`로 바꾸는 걸 권장.
- REST 오류 응답은 FastAPI 기본 형식 `{"detail": ...}` (422는 `detail`이 배열일 수 있음).

| 상태 | 뜻 |
|---|---|
| 404 | 없는 run |
| 409 | 이미 끝난 run (종료를 두 번 보냄 → 클라이언트는 "이미 기록됨"으로 처리) |
| 422 | 값이 잘못됨 (범위, 모르는 값, 서버 시계보다 긴 시간, 너무 빠른 클리어) |

## 2. 한 판의 흐름

```
게임 시작 ──POST /api/runs──────────────► run_id       (게임 elapsed = 0 과 동시에)
진행 중   ──socket run:event ×N──────────► ack {ok}     → 다른 접속자에게 run:news
게임 종료 ──POST /api/runs/{id}/finish───► {rank}       → 모두에게 run:news(win/dead)
                                                        → 승리면 모두에게 leaderboard:update
랭킹 화면 ──GET /api/leaderboard─────────► {mode, rows}
```

## 3. REST

### `POST /api/runs` — 판 시작
```json
{"player": "하늘", "model": "qwen2.5:3b", "version": "0.1"}
```
- `player` 1~16자 (앞뒤 공백 제거, 대소문자 무시로 같은 사람), `model` ≤64자(기본 `""`), `version` ≤16자(기본 `"dev"`)
- 응답 `200 {"run_id": 17}`
- 서버가 시작 시각을 기록한다. **게임 시계(elapsed)가 0일 때 바로 보내야 한다** — 나중에 보내면 종료 시 시간 검증에 걸릴 수 있다.

### `POST /api/runs/{run_id}/finish` — 판 종료
```json
{"result": "win", "time_sec": 312.4, "llm_wait_sec": 95.1, "battery": 41.5, "orders": 18, "mode": "llm"}
```
| 필드 | 설명 |
|---|---|
| `result` | `"win"` / `"dead"` |
| `time_sec` | 게임의 `elapsed` 그대로 (0~86400) |
| `llm_wait_sec` | 그중 LLM 응답을 기다린 시간 합계 (기본 0, `time_sec` 이하) |
| `battery` | 남은 배터리 0~100 |
| `orders` | 조종사가 보낸 명령 수 (`/` 명령 제외) |
| `mode` | 한 판에서 **한 턴이라도** 오프라인 해석기로 처리했으면 `"offline"`, 아니면 `"llm"` |

- 응답 `200 {"rank": 3}` — 승리면 그 플레이어의 해당 모드 순위(개인 최고 기록 기준), 패배면 `null`
- 서버 검증 (422): `time_sec`가 서버가 잰 경과 시간 + 5초보다 길면 거부 / 승리인데 플레이 시간(`time_sec - llm_wait_sec`)이 최소 클리어 시간(기본 20초)보다 짧으면 거부

### `GET /api/leaderboard?mode=llm&limit=10`
- `mode` = `llm`(기본) / `offline`, `limit` 1~100 (기본 10)
```json
{"mode": "llm", "rows": [
  {"rank": 1, "run_id": 42, "name": "하늘", "play_sec": 157.5, "battery": 9.0,
   "orders": 14, "model": "qwen2.5:3b", "ended_at": "2026-11-28 06:32:42.669"}
]}
```

### `GET /api/stats?mode=llm` (선택)
```json
{"mode": "llm", "finished": 12, "wins": 7, "deaths": 5, "clear_rate": 0.583,
 "avg_win_play_sec": 231.2, "death_rooms": [{"room": "영안실", "deaths": 3}]}
```
`mode`를 빼면 전체. `death_rooms`는 패배한 판의 마지막 방 기준.

## 4. 랭킹 규칙

1. 모드(`llm` / `offline`)별로 따로 매긴다. 오프라인 해석기는 `D1` 같은 ID를 직접 입력할 수 있어 훨씬 쉽기 때문.
2. 플레이어마다 **최고 기록 1개**만 랭킹에 오른다.
3. 정렬: **플레이 시간**(`time_sec - llm_wait_sec`, LLM 대기 시간 제외 → PC 성능·모델 크기 영향 제거) 짧은 순 → **남은 배터리** 많은 순 → **명령 수** 적은 순
4. 세 값이 모두 같으면 같은 순위(1, 1, 3…), 표시는 먼저 달성한 사람이 위.

구현: `server/schema.sql`의 `v_leaderboard` 뷰 (`ROW_NUMBER`로 개인 최고 기록, `RANK`로 순위).

## 5. Socket.IO

- 주소: 서버와 같은 호스트·포트, 기본 네임스페이스 `/` (예: `http://127.0.0.1:8000`)
- 서버는 python-socketio (Engine.IO v4 / Socket.IO v5 프로토콜)

| 방향 | 이벤트 | 내용 |
|---|---|---|
| 게임 → 서버 | `run:event` | `{"run_id", "type", "t_sec", "room", "battery"}` |
| 서버 → 다른 접속자 | `run:news` | `{"run_id", "name", "type", "room", "battery", "t_sec", "rank"}` |
| 서버 → 전체 | `leaderboard:update` | `GET /api/leaderboard` 응답과 같은 `{"mode", "rows"}` (TOP 10) |

`run:event`
- `type`: `room_enter`(방 진입) / `keycard`(카드키 획득) / `exit_open`(비상구 열림) / `battery_low`(배터리 30%·15% 경고)
- `t_sec`: 그 순간의 게임 `elapsed`, `room`: 방 이름(≤64자, 없으면 `""`), `battery`: 0~100 또는 `null`
- ack(선택): `{"ok": true}` 또는 `{"ok": false, "code": 404|409|422, "error": "..."}`

`run:news`
- 이벤트를 보낸 본인에게는 오지 않는다 (가짜 서버는 혼자 시험할 수 있게 본인에게도 보냄).
- 판 종료 때는 서버가 `type: "win"|"dead"`로 **모두에게** 보낸다. 이때 `room`은 마지막으로 기록된 방, `t_sec`는 `time_sec`, `rank`는 승리 순위.
  REST로 끝냈기 때문에 본인에게도 가므로, 게임은 `run_id`가 자기 것이면 무시한다.

## 6. Godot 연결 가이드 (Godot 담당용)

### 이벤트를 보낼 위치 (현재 코드 기준)

| 보낼 것 | 위치 |
|---|---|
| `POST /api/runs` | `scripts/game.gd` `_ready()` — 직후 `room_enter`("창고", t_sec 0)도 한 번 |
| `room_enter` | `scripts/robot.gd` `_pass_door()` 출입구 통과 직후 (`level.room_name_at(global_position)`) |
| `keycard` | `scripts/robot.gd` `_pick_up()`의 `has_keycard = true` |
| `exit_open` | `scripts/level_builder.gd` `open_exit()`의 `exit_open = true` |
| `battery_low` | `scripts/game.gd` `_drain()`의 30%·15% 경고 |
| `finish` | `scripts/game.gd` `_win()` / `_lose()` |
| `orders`, `llm_wait_sec`, `mode` 집계 | `scripts/game.gd` `submit_order()` (`llm.ask` 앞뒤 시간 차 누적, 오프라인 처리 여부) |

- `robot.gd`·`level_builder.gd`에서 서버를 직접 부르지 말고 **시그널만** 내보낸 뒤 `game.gd`에서 모아서 보낸다 (지금의 `moved` 시그널 방식).
- `--autotest` 실행에서는 실제 서버로 보내지 않는다 (테스트 서버 주소를 인자로 받는 건 OK).
- REST는 `LlmClient._request`(`scripts/llm_client.gd`)와 같은 방식으로 `HTTPRequest` 사용. 응답이 Dictionary여야 하므로 모든 응답은 객체로 감쌌다.
- 서버가 꺼져 있으면: `POST /api/runs` 실패 → 이번 판은 기록 없이 진행(안내만). 종료 전송 실패 → 나중에 재전송 가능(409면 이미 기록된 것).
- 랭킹 이름을 로그에 출력할 때는 `.replace("[", "[lb]")`로 BBCode 이스케이프.

### Godot에서 Socket.IO 쓰기

Godot에는 Socket.IO 클라이언트가 없다. 내장 `WebSocketPeer`로 아래 문자열만 주고받으면 된다.
**이 프레임 순서는 `tools/integration_check.py` 7번 단계에서 실제 서버로 검증했다.**

| 순서 | 받음 / 보냄 | 프레임 |
|---|---|---|
| 1 | 접속 | `ws://호스트:포트/socket.io/?EIO=4&transport=websocket` |
| 2 | 받음 | `0{"sid":...,"pingInterval":25000,...}` → `40` 보냄 |
| 3 | 받음 | `40{"sid":...}` → 이제 이벤트 전송 가능 |
| 4 | 보냄 | `42["run:event",{...}]` (ack가 필요하면 `421[...]` → `431[{"ok":true}]`로 답이 옴) |
| 5 | 받음 | `42["run:news",{...}]`, `42["leaderboard:update",{...}]` |
| 항상 | 받음 | `2` → 바로 `3` 보냄 (안 보내면 약 45초 뒤 끊김) |

아래는 예시 코드다. **Godot 4.4에서 직접 실행해 보지는 못했으니** 처음 붙일 때 가짜 서버로 확인할 것.

```gdscript
class_name SocketClient
extends Node
## Socket.IO 최소 클라이언트 (WebSocketPeer 위에 Engine.IO v4 프레임만 처리)

signal event_received(event: String, data: Variant)

var _ws := WebSocketPeer.new()
var _joined := false              # "40" 응답을 받은 뒤에만 이벤트 전송
var _pending: Array[String] = []


func open(http_host: String) -> void:   # 예: "http://127.0.0.1:8000"
	_ws.connect_to_url(http_host.replace("http", "ws") + "/socket.io/?EIO=4&transport=websocket")


func emit_event(event: String, data: Dictionary) -> void:
	var frame := "42" + JSON.stringify([event, data])
	if _joined:
		_ws.send_text(frame)
	else:
		_pending.append(frame)


func _process(_delta: float) -> void:
	_ws.poll()
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	while _ws.get_available_packet_count() > 0:
		var msg := _ws.get_packet().get_string_from_utf8()
		if msg.begins_with("40"):           # 네임스페이스 접속 완료
			_joined = true
			for f in _pending:
				_ws.send_text(f)
			_pending.clear()
		elif msg.begins_with("0"):          # Engine.IO 열림 → 네임스페이스 접속 요청
			_ws.send_text("40")
		elif msg == "2":                    # ping → pong
			_ws.send_text("3")
		elif msg.begins_with("42"):         # 이벤트
			var arr = JSON.parse_string(msg.substr(2))
			if arr is Array and arr.size() >= 2:
				event_received.emit(arr[0], arr[1])
```

## 7. 서버 연결 예시 (서버 담당용)

DB 함수는 동기 함수다. 라우트에서 `sio.emit`(async)을 해야 하므로 **라우트는 async로 두고 DB 호출은 모두 `asyncio.to_thread`** 로 감싼다.
아래 코드는 `tools/integration_check.py`를 19/19로 통과한 구성이다.

```python
import asyncio
from contextlib import asynccontextmanager

import socketio
from fastapi import FastAPI, HTTPException
from pydantic import ValidationError

from app import contract as c
from app import db

sio = socketio.AsyncServer(async_mode="asgi", cors_allowed_origins="*")


@asynccontextmanager
async def lifespan(_app):
    await asyncio.to_thread(db.init_db)
    await asyncio.to_thread(db.abandon_stale_runs)
    yield

api = FastAPI(lifespan=lifespan)


def status_of(e: Exception) -> int:
    return 404 if isinstance(e, db.NotFound) else 409 if isinstance(e, db.Conflict) else 422


@api.post("/api/runs/{run_id}/finish", response_model=c.RunFinished)
async def finish_run(run_id: int, body: c.RunFinish):
    try:
        rank = await asyncio.to_thread(db.finish_run, run_id, **body.model_dump())
    except (db.NotFound, db.Conflict, ValueError) as e:
        raise HTTPException(status_of(e), str(e))
    run = await asyncio.to_thread(db.get_run, run_id)
    await sio.emit(c.EV_RUN_NEWS, {"run_id": run_id, "name": run["player"], "type": body.result,
                                   "room": run["last_room"], "battery": body.battery,
                                   "t_sec": body.time_sec, "rank": rank})
    if body.result == "win":
        rows = await asyncio.to_thread(db.get_leaderboard, body.mode, 10)
        await sio.emit(c.EV_LEADERBOARD_UPDATE, {"mode": body.mode, "rows": rows})
    return {"rank": rank}


@sio.on(c.EV_RUN_EVENT)
async def run_event(sid, data):
    try:
        ev = c.RunEvent.model_validate(data)
        news = await asyncio.to_thread(db.add_event, **ev.model_dump())   # run:news 내용을 돌려줌
    except ValidationError as e:
        return c.ack_error(422, e.errors()[0]["msg"])
    except (db.NotFound, db.Conflict, ValueError) as e:
        return c.ack_error(status_of(e), str(e))
    await sio.emit(c.EV_RUN_NEWS, news, skip_sid=sid)
    return c.ack_ok()

# POST /api/runs → db.create_run(body.player, body.model, body.version)
# GET /api/leaderboard → db.get_leaderboard(mode, limit), GET /api/stats → db.get_stats(mode)

asgi_app = socketio.ASGIApp(sio, other_asgi_app=api)   # 실행: uvicorn app.main:asgi_app
```

### `app.db` 함수 목록

| 함수 | 돌려주는 값 | 예외 |
|---|---|---|
| `init_db()` | — | |
| `create_run(player, model="", version="dev")` | `run_id` | ValueError |
| `get_run(run_id)` | dict (`player`, `status`, `last_room` …) 또는 None | ValueError |
| `add_event(run_id, type, t_sec, room="", battery=None)` | `run:news` 내용 dict | NotFound, Conflict, ValueError |
| `finish_run(run_id, result, time_sec, llm_wait_sec, battery, orders, mode)` | 순위 또는 None | NotFound, Conflict, ValueError |
| `get_leaderboard(mode="llm", limit=10)` | 행 dict 리스트 | ValueError |
| `get_player_rank(player, mode="llm")` | 행 dict 또는 None | ValueError |
| `get_stats(mode=None)` | 통계 dict | ValueError |
| `abandon_stale_runs(max_age_minutes=180)` | 정리한 개수 | |

## 8. 계약을 바꿀 때

1. 이 문서와 `server/app/contract.py`를 같은 PR에서 고친다 (필요하면 `db.py`·`schema.sql`도).
2. `tools/mock_server.py`와 `tools/integration_check.py`를 맞춰 고친다.
3. 가짜 서버와 실제 서버 양쪽에서 `integration_check.py`가 PASS인지 확인하고 두 팀원에게 알린다.
