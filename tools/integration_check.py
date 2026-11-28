#!/usr/bin/env python3
"""통합 점검: 서버가 docs/API.md 계약대로 동작하는지 처음부터 끝까지 확인한다. DB·통합 담당.

가짜 서버(tools/mock_server.py)와 실제 서버 둘 다에 쓸 수 있다.

    pip install -r server/requirements.txt
    python3 tools/integration_check.py --url http://127.0.0.1:8000

실제 서버를 점검할 때는 진짜 랭킹이 더러워지지 않게 테스트용 DB로 띄우고,
빠른 클리어도 받아 주도록 최소 클리어 시간을 0으로 둔다:

    LOST_SIGNAL_DB=/tmp/it.db LOST_SIGNAL_MIN_WIN_SEC=0 uvicorn app.main:asgi_app --port 8000

[7]번 단계는 Godot의 WebSocketPeer가 보낼 프레임(Engine.IO v4 / Socket.IO v5)을 그대로 흉내 낸다.
여기서 통과하면 Godot 쪽도 같은 문자열만 보내면 된다.
"""
import argparse
import json
import queue
import sys
import time
import urllib.error
import urllib.request
import uuid

import socketio
import websocket  # websocket-client (python-socketio[client]에 포함)

TIMEOUT = 5.0
results: list[tuple[bool, str]] = []


def check(ok: bool, label: str, detail: str = "") -> bool:
    results.append((ok, label))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  — {detail}" if detail and not ok else ""))
    return ok


def http(method: str, url: str, body: dict | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return res.status, json.loads(res.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except json.JSONDecodeError:
            return e.code, {}


def wait_for(q: queue.Queue, pred, timeout: float = TIMEOUT):
    end = time.monotonic() + timeout
    while (left := end - time.monotonic()) > 0:
        try:
            item = q.get(timeout=left)
        except queue.Empty:
            break
        if pred(item):
            return item
    return None


def raw_socketio_emit(ws_url: str, event: str, data: dict) -> tuple[bool, str]:
    """Godot WebSocketPeer와 같은 방식으로 접속해서 이벤트 하나를 ack와 함께 보낸다."""
    ws = websocket.create_connection(ws_url + "/socket.io/?EIO=4&transport=websocket", timeout=TIMEOUT)
    try:
        hello = ws.recv()
        if not hello.startswith("0"):
            return False, f"Engine.IO 열림 패킷(0...)이 아님: {hello[:40]}"
        ws.send("40")                                   # 기본 네임스페이스 접속
        while True:
            msg = ws.recv()
            if msg == "2":                              # 서버 ping → pong
                ws.send("3")
            elif msg.startswith("40"):
                break
            elif msg.startswith("44"):
                return False, f"네임스페이스 접속 거부: {msg}"
        ws.send("421" + json.dumps([event, data], ensure_ascii=False))   # ack id 1
        while True:
            msg = ws.recv()
            if msg == "2":
                ws.send("3")
            elif msg.startswith("431"):
                ack = json.loads(msg[3:])
                return (isinstance(ack, list) and ack and ack[0].get("ok") is True), f"ack={ack}"
    finally:
        ws.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8000")
    base = ap.parse_args().url.rstrip("/")
    ws_url = "ws" + base[len("http"):] if base.startswith("http") else base
    player = "IT-" + uuid.uuid4().hex[:6]
    print(f"통합 점검 대상: {base}  (테스트 플레이어 {player})\n")

    print("[1] 랭킹 조회")
    st, body = http("GET", f"{base}/api/leaderboard?mode=llm&limit=10")
    check(st == 200 and body.get("mode") == "llm" and isinstance(body.get("rows"), list),
          "GET /api/leaderboard → {mode, rows}", f"{st} {body}")
    st, _ = http("GET", f"{base}/api/leaderboard?mode=hard")
    check(st == 422, "모르는 mode → 422", f"{st}")

    print("[2] 판 시작")
    st, _ = http("POST", f"{base}/api/runs", {"player": ""})
    check(st == 422, "빈 이름 → 422", f"{st}")
    st, body = http("POST", f"{base}/api/runs", {"player": player, "model": "qwen2.5:3b", "version": "it"})
    if not check(st == 200 and isinstance(body.get("run_id"), int), "POST /api/runs → run_id", f"{st} {body}"):
        return summary()
    run_id = body["run_id"]
    started = time.monotonic()

    print("[3] Socket.IO 접속 (관찰자 + 게임)")
    news_q: queue.Queue = queue.Queue()
    board_q: queue.Queue = queue.Queue()
    observer = socketio.Client(reconnection=False)
    observer.on("run:news", news_q.put)
    observer.on("leaderboard:update", board_q.put)
    game = socketio.Client(reconnection=False)
    try:
        observer.connect(base, transports=["websocket"], wait_timeout=TIMEOUT)
        game.connect(base, transports=["websocket"], wait_timeout=TIMEOUT)
        check(True, "두 클라이언트 접속")
    except Exception as e:  # noqa: BLE001
        check(False, "두 클라이언트 접속", repr(e))
        return summary()

    try:
        print("[4] run:event 보내기 (ack)")
        ev = {"run_id": run_id, "type": "room_enter", "t_sec": 5.0, "room": "복도", "battery": 97.5}
        try:
            ack = game.call("run:event", ev, timeout=TIMEOUT)
            check(isinstance(ack, dict) and ack.get("ok") is True, "ack {ok: true}", f"{ack}")
        except socketio.exceptions.TimeoutError:
            check(False, "ack {ok: true}", "ack가 오지 않음 (핸들러가 값을 return 해야 함)")
        ack = game.call("run:event", {**ev, "run_id": 999999999}, timeout=TIMEOUT)
        check(isinstance(ack, dict) and ack.get("ok") is False and ack.get("code") == 404,
              "없는 run → ack {ok: false, code: 404}", f"{ack}")
        ack = game.call("run:event", {**ev, "type": "teleport"}, timeout=TIMEOUT)
        check(isinstance(ack, dict) and ack.get("ok") is False and ack.get("code") == 422,
              "모르는 type → ack {ok: false, code: 422}", f"{ack}")

        print("[5] 다른 클라이언트에 run:news 전달")
        news = wait_for(news_q, lambda n: n.get("run_id") == run_id and n.get("type") == "room_enter")
        check(news is not None and news.get("name") == player and news.get("room") == "복도",
              "run:news {run_id, name, type, room, battery, t_sec, rank}", f"{news}")

        print("[6] 판 종료 오류 처리")
        win = {"result": "win", "time_sec": 0.0, "llm_wait_sec": 0.0, "battery": 61.5,
               "orders": 12, "mode": "llm"}
        st, _ = http("POST", f"{base}/api/runs/999999999/finish", win)
        check(st == 404, "없는 run 종료 → 404", f"{st}")
        st, _ = http("POST", f"{base}/api/runs/{run_id}/finish", {**win, "mode": "cheat"})
        check(st == 422, "잘못된 mode → 422", f"{st}")

        print("[7] Godot 방식(WebSocketPeer 원시 프레임)으로 이벤트 보내기")
        raw_ev = {"run_id": float(run_id), "type": "keycard", "t_sec": 9.0, "room": "", "battery": 90.0}
        try:
            ok, detail = raw_socketio_emit(ws_url, "run:event", raw_ev)   # run_id를 float로 (Godot처럼)
        except Exception as e:  # noqa: BLE001
            ok, detail = False, repr(e)
        check(ok, "0 → 40 → 421[...] → 431[{ok:true}]", detail)
        news = wait_for(news_q, lambda n: n.get("run_id") == run_id and n.get("type") == "keycard")
        check(news is not None, "원시 프레임 이벤트도 run:news로 전달", f"{news}")

        print("[8] 승리 기록")
        win["time_sec"] = round(time.monotonic() - started, 2)
        st, body = http("POST", f"{base}/api/runs/{run_id}/finish", win)
        if not check(st == 200 and isinstance(body.get("rank"), int), "finish → {rank: 정수}", f"{st} {body}"):
            if st == 422:
                print("        실제 서버라면 LOST_SIGNAL_MIN_WIN_SEC=0 으로 띄웠는지 확인하세요.")
            return summary()
        rank = body["rank"]
        news = wait_for(news_q, lambda n: n.get("run_id") == run_id and n.get("type") == "win")
        check(news is not None and news.get("rank") == rank, "run:news type=win, rank 포함", f"{news}")
        board = wait_for(board_q, lambda b: any(r.get("name") == player for r in b.get("rows", [])))
        check(board is not None and board.get("mode") == "llm", "leaderboard:update에 새 기록 포함", f"{board}")
        st, _ = http("POST", f"{base}/api/runs/{run_id}/finish", win)
        check(st == 409, "같은 판 두 번 종료 → 409", f"{st}")
        ack = game.call("run:event", {**ev, "t_sec": 99.0}, timeout=TIMEOUT)
        check(isinstance(ack, dict) and ack.get("code") == 409, "끝난 판에 이벤트 → ack code 409", f"{ack}")

        print("[9] 랭킹 반영")
        st, body = http("GET", f"{base}/api/leaderboard?mode=llm&limit=100")
        row = next((r for r in body.get("rows", []) if r.get("name") == player), None)
        need = {"rank", "run_id", "name", "play_sec", "battery", "orders", "model", "ended_at"}
        check(row is not None and row["rank"] == rank and need <= row.keys(),
              "랭킹 행 필드와 순위 일치", f"{row}")
    finally:
        game.disconnect()
        observer.disconnect()
    return summary()


def summary() -> int:
    failed = [label for ok, label in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} 통과")
    print("INTEGRATION", "PASS" if not failed else "FAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
