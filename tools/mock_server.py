#!/usr/bin/env python3
"""개발용 가짜 랭킹 서버 (FastAPI + Socket.IO, DB 없이 메모리에만 저장). DB·통합 담당.

Godot 담당이 실제 서버가 완성되기 전에 클라이언트를 만들고 시험할 때 쓴다.
요청·응답 형식은 server/app/contract.py(= docs/API.md)를 그대로 쓰므로 실제 서버와 같다.

    pip install -r server/requirements.txt
    python3 tools/mock_server.py --port 8000 --chatter 15

실제 서버와 다른 점
- run:news를 보낸 사람에게도 돌려준다 (혼자 시험할 때 받는 쪽 UI도 확인할 수 있도록)
- 서버 시계·최소 클리어 시간 검증을 하지 않는다
- --chatter N: N초마다 가짜 '다른 조종사' 소식을 보낸다 (0이면 끔)
- 재시작하면 기록이 모두 사라진다
"""
import argparse
import asyncio
import random
import sys
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import socketio
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
from app import contract as c  # noqa: E402

RUNS: dict[int, dict] = {}
_next_id = 1


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def _key(r: dict) -> tuple:
    return (round(r["time_sec"] - r["llm_wait_sec"], 2), -r["battery"], r["orders"])


def _leaderboard(mode: str, limit: int = 10) -> list[dict]:
    best: dict[str, dict] = {}
    for r in RUNS.values():
        if r["status"] == "win" and r["mode"] == mode:
            k = r["player"].lower()
            if k not in best or _key(r) < _key(best[k]):
                best[k] = r
    ordered = sorted(best.values(), key=lambda r: (_key(r), r["ended_at"], r["id"]))
    rows = []
    for r in ordered:
        rank = 1 + sum(1 for o in ordered if _key(o) < _key(r))
        rows.append({"rank": rank, "run_id": r["id"], "name": r["player"],
                     "play_sec": _key(r)[0], "battery": r["battery"], "orders": r["orders"],
                     "model": r["model"], "ended_at": r["ended_at"]})
    return rows[:limit]


def build_app(chatter: float) -> socketio.ASGIApp:
    sio = socketio.AsyncServer(async_mode="asgi", cors_allowed_origins="*")

    async def fake_operators() -> None:
        names = ["조종사-K", "야간근무자", "R-9 담당"]
        rooms = ["복도", "병실", "영안실", "수술실", "원장실", "로비"]
        while True:
            await asyncio.sleep(chatter)
            news = {"run_id": 0, "name": random.choice(names), "room": random.choice(rooms),
                    "type": random.choice(["room_enter", "keycard", "battery_low"]),
                    "battery": round(random.uniform(10, 90), 1), "t_sec": 0.0, "rank": None}
            await sio.emit(c.EV_RUN_NEWS, news)

    @asynccontextmanager
    async def lifespan(_app):
        task = asyncio.create_task(fake_operators()) if chatter > 0 else None
        yield
        if task:
            task.cancel()

    api = FastAPI(title="LOST SIGNAL mock server", lifespan=lifespan)

    @api.post("/api/runs", response_model=c.RunCreated)
    async def create_run(body: c.RunCreate):
        global _next_id
        rid, _next_id = _next_id, _next_id + 1
        RUNS[rid] = {"id": rid, "player": body.player, "model": body.model, "status": "playing",
                     "last_room": ""}
        print(f"[mock] run {rid} 시작: {body.player} ({body.model})")
        return {"run_id": rid}

    @api.post("/api/runs/{run_id}/finish", response_model=c.RunFinished)
    async def finish_run(run_id: int, body: c.RunFinish):
        run = RUNS.get(run_id)
        if run is None:
            raise HTTPException(404, f"run {run_id}이(가) 없습니다")
        if run["status"] != "playing":
            raise HTTPException(409, f"run {run_id}은(는) 이미 끝났습니다 ({run['status']})")
        if body.llm_wait_sec > body.time_sec:
            raise HTTPException(422, "llm_wait_sec가 time_sec보다 클 수 없습니다")
        run.update(body.model_dump(), status=body.result, ended_at=_now())
        rank = None
        if body.result == "win":
            rank = next((r["rank"] for r in _leaderboard(body.mode, 10**6)
                         if r["name"].lower() == run["player"].lower()), None)
        print(f"[mock] run {run_id} 종료: {body.result} rank={rank}")
        await sio.emit(c.EV_RUN_NEWS, {"run_id": run_id, "name": run["player"], "type": body.result,
                                       "room": run["last_room"], "battery": body.battery,
                                       "t_sec": body.time_sec, "rank": rank})
        if body.result == "win":
            await sio.emit(c.EV_LEADERBOARD_UPDATE,
                           {"mode": body.mode, "rows": _leaderboard(body.mode)})
        return {"rank": rank}

    @api.get("/api/leaderboard", response_model=c.Leaderboard)
    async def leaderboard(mode: c.Mode = "llm", limit: int = 10):
        if not 1 <= limit <= 100:
            raise HTTPException(422, "limit: 1 ~ 100")
        return {"mode": mode, "rows": _leaderboard(mode, limit)}

    @sio.event
    async def connect(sid, environ, auth=None):
        print(f"[mock] socket 연결: {sid}")

    @sio.on(c.EV_RUN_EVENT)
    async def run_event(sid, data):
        try:
            ev = c.RunEvent.model_validate(data)
        except ValidationError as e:
            return c.ack_error(422, str(e.errors()[0].get("msg", "잘못된 데이터")))
        run = RUNS.get(ev.run_id)
        if run is None:
            return c.ack_error(404, f"run {ev.run_id}이(가) 없습니다")
        if run["status"] != "playing":
            return c.ack_error(409, f"run {ev.run_id}은(는) 이미 끝났습니다")
        if ev.room:
            run["last_room"] = ev.room
        print(f"[mock] 이벤트: run {ev.run_id} {ev.type} {ev.room} {ev.battery}")
        news = {"run_id": ev.run_id, "name": run["player"], "type": ev.type, "room": ev.room,
                "battery": ev.battery, "t_sec": ev.t_sec, "rank": None}
        await sio.emit(c.EV_RUN_NEWS, news)  # 실제 서버는 skip_sid=sid (보낸 사람 제외)
        return c.ack_ok()

    return socketio.ASGIApp(sio, other_asgi_app=api)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--chatter", type=float, default=0.0, help="가짜 소식 간격(초), 0이면 끔")
    args = ap.parse_args()
    uvicorn.run(build_app(args.chatter), host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
