"""LOST SIGNAL 랭킹 DB 계층 (DB·통합 담당).

서버 담당은 SQL을 직접 쓰지 않고 이 모듈의 함수만 호출한다. 계약 문서: docs/API.md

사용 규칙
- 서버 시작 시 `init_db()`, 이어서 `abandon_stale_runs()`를 한 번 호출한다.
- 모든 함수는 동기 함수다. async 코드(FastAPI async 라우트, Socket.IO 핸들러)에서는
  `await asyncio.to_thread(db.함수, ...)`로 호출한다.
- 호출마다 연결을 새로 열고 닫으므로 여러 스레드에서 동시에 불러도 안전하다.
- 예외 → HTTP 상태: NotFound → 404, Conflict → 409, ValueError → 422

설정 (환경변수)
- LOST_SIGNAL_DB: DB 파일 경로 (기본 server/data/lost_signal.db)
- LOST_SIGNAL_MIN_WIN_SEC: 이보다 빠른 클리어는 거부 (기본 20초, 통합 점검 때는 0)
"""
from __future__ import annotations

import math
import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

SERVER_DIR = Path(__file__).resolve().parent.parent
SCHEMA_PATH = SERVER_DIR / "schema.sql"
SCHEMA_VERSION = 1

RESULTS = ("win", "dead")
MODES = ("llm", "offline")
EVENT_TYPES = ("room_enter", "keycard", "exit_open", "battery_low")
NAME_MAX = 16
TEXT_MAX = 64          # model, room
VERSION_MAX = 16
LEADERBOARD_MAX = 100

# 게임이 보고한 time_sec가 서버 시계로 잰 경과 시간보다 이만큼 넘게 길면 거부 (네트워크 지연 여유)
CLOCK_MARGIN_SEC = 5.0
# 맵을 실제로 돌아다니려면 최소 이만큼은 걸린다 (플레이 시간 기준). 조작된 기록 1차 차단용.
MIN_WIN_SEC = float(os.environ.get("LOST_SIGNAL_MIN_WIN_SEC", "20"))

_db_path = Path(os.environ.get("LOST_SIGNAL_DB", SERVER_DIR / "data" / "lost_signal.db"))

_NOW = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
_LAST_ROOM = """COALESCE((SELECT e.room FROM run_events e
                          WHERE e.run_id = r.id AND e.room <> ''
                          ORDER BY e.t_sec DESC, e.id DESC LIMIT 1), '')"""


class NotFound(Exception):
    """해당 run이 없음 → HTTP 404"""


class Conflict(Exception):
    """이미 끝난 run에 다시 기록하려 함 → HTTP 409"""


# ---------------------------------------------------------------- 연결

def configure(path: str | Path) -> None:
    """DB 파일 경로를 바꾼다 (테스트·시드용). 그 다음 init_db()를 호출할 것."""
    global _db_path
    _db_path = Path(path)


def db_path() -> Path:
    return _db_path


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    con = sqlite3.connect(_db_path, timeout=5.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    try:
        yield con
        con.commit()
    except BaseException:
        con.rollback()
        raise
    finally:
        con.close()


def init_db() -> None:
    """테이블·뷰를 만든다. 이미 있으면 그대로 둔다."""
    _db_path.parent.mkdir(parents=True, exist_ok=True)
    with _connect() as con:
        con.execute("PRAGMA journal_mode = WAL")  # 읽기(랭킹 조회)와 쓰기를 동시에
        con.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
        con.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")


# ---------------------------------------------------------------- 입력 검증

def _text(value: Any, field: str, max_len: int, *, required: bool = False) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        raise ValueError(f"{field}: 문자열이어야 합니다")
    v = value.strip()
    if required and not v:
        raise ValueError(f"{field}: 비어 있으면 안 됩니다")
    if len(v) > max_len:
        raise ValueError(f"{field}: 최대 {max_len}자입니다")
    if any(ord(ch) < 32 for ch in v):
        raise ValueError(f"{field}: 제어 문자는 쓸 수 없습니다")
    return v


def _number(value: Any, field: str, lo: float = 0.0, hi: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field}: 숫자여야 합니다")
    v = float(value)
    if math.isnan(v) or math.isinf(v):
        raise ValueError(f"{field}: 올바른 숫자가 아닙니다")
    if v < lo or (hi is not None and v > hi):
        raise ValueError(f"{field}: {lo} ~ {hi if hi is not None else '∞'} 범위여야 합니다")
    return v


def _int(value: Any, field: str, lo: int = 0, hi: int | None = None) -> int:
    # Godot의 JSON.parse_string은 숫자를 전부 float로 돌려주므로 3.0 같은 값도 허용한다
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{field}: 정수여야 합니다")
    if value < lo or (hi is not None and value > hi):
        raise ValueError(f"{field}: {lo} ~ {hi if hi is not None else '∞'} 범위여야 합니다")
    return value


def _choice(value: Any, field: str, options: tuple[str, ...]) -> str:
    if value not in options:
        raise ValueError(f"{field}: {', '.join(options)} 중 하나여야 합니다")
    return value


# ---------------------------------------------------------------- 한 판 기록

def create_run(player: str, model: str = "", version: str = "dev") -> int:
    """게임 시작 시 호출. 플레이어가 처음이면 만들고, 새 run_id를 돌려준다."""
    name = _text(player, "player", NAME_MAX, required=True)
    model = _text(model, "model", TEXT_MAX)
    version = _text(version, "version", VERSION_MAX) or "dev"
    with _connect() as con:
        con.execute("INSERT INTO players (name) VALUES (?) ON CONFLICT (name) DO NOTHING", (name,))
        pid = con.execute("SELECT id FROM players WHERE name = ?", (name,)).fetchone()["id"]
        cur = con.execute("INSERT INTO runs (player_id, model, version) VALUES (?, ?, ?)",
                          (pid, model, version))
        return int(cur.lastrowid)


def get_run(run_id: int) -> dict | None:
    """run 하나의 정보. last_room = 마지막으로 기록된 방 이름 (없으면 '')."""
    run_id = _int(run_id, "run_id", 1)
    with _connect() as con:
        row = con.execute(f"""
            SELECT r.id AS run_id, p.name AS player, r.status, r.mode, r.model, r.version,
                   r.started_at, r.ended_at, r.time_sec, r.llm_wait_sec, r.battery, r.orders,
                   {_LAST_ROOM} AS last_room
            FROM runs r JOIN players p ON p.id = r.player_id
            WHERE r.id = ?""", (run_id,)).fetchone()
    return dict(row) if row else None


def add_event(run_id: int, type: str, t_sec: float, room: str = "",
              battery: float | None = None) -> dict:
    """진행 이벤트를 저장하고, 그대로 브로드캐스트할 run:news 내용을 돌려준다."""
    run_id = _int(run_id, "run_id", 1)
    type = _choice(type, "type", EVENT_TYPES)
    t_sec = _number(t_sec, "t_sec", 0.0)
    room = _text(room, "room", TEXT_MAX)
    if battery is not None:
        battery = _number(battery, "battery", 0.0, 100.0)
    with _connect() as con:
        row = con.execute("""SELECT r.status, p.name FROM runs r JOIN players p ON p.id = r.player_id
                             WHERE r.id = ?""", (run_id,)).fetchone()
        if row is None:
            raise NotFound(f"run {run_id}이(가) 없습니다")
        if row["status"] != "playing":
            raise Conflict(f"run {run_id}은(는) 이미 끝났습니다 ({row['status']})")
        con.execute("INSERT INTO run_events (run_id, type, t_sec, room, battery) VALUES (?, ?, ?, ?, ?)",
                    (run_id, type, t_sec, room, battery))
    return {"run_id": run_id, "name": row["name"], "type": type, "room": room,
            "battery": battery, "t_sec": t_sec, "rank": None}


def finish_run(run_id: int, result: str, time_sec: float, llm_wait_sec: float,
               battery: float, orders: int, mode: str) -> int | None:
    """게임 종료 시 호출. 승리면 그 플레이어의 (해당 모드) 현재 순위를, 패배면 None을 돌려준다.

    순위는 플레이어의 최고 기록 기준이다. 이번 판이 개인 최고 기록보다 느리면 순위는 그대로다.
    """
    run_id = _int(run_id, "run_id", 1)
    result = _choice(result, "result", RESULTS)
    mode = _choice(mode, "mode", MODES)
    time_sec = _number(time_sec, "time_sec", 0.0, 86400.0)
    llm_wait_sec = _number(llm_wait_sec, "llm_wait_sec", 0.0, 86400.0)
    battery = _number(battery, "battery", 0.0, 100.0)
    orders = _int(orders, "orders", 0, 100000)
    if llm_wait_sec > time_sec:
        raise ValueError("llm_wait_sec가 time_sec보다 클 수 없습니다")

    with _connect() as con:
        row = con.execute("""SELECT status, player_id,
                                    (julianday('now') - julianday(started_at)) * 86400.0 AS elapsed
                             FROM runs WHERE id = ?""", (run_id,)).fetchone()
        if row is None:
            raise NotFound(f"run {run_id}이(가) 없습니다")
        if row["status"] != "playing":
            raise Conflict(f"run {run_id}은(는) 이미 끝났습니다 ({row['status']})")
        if time_sec > row["elapsed"] + CLOCK_MARGIN_SEC:
            raise ValueError(f"time_sec({time_sec:.1f}초)가 서버가 잰 경과 시간"
                             f"({row['elapsed']:.1f}초)보다 깁니다")
        if result == "win" and time_sec - llm_wait_sec < MIN_WIN_SEC:
            raise ValueError(f"플레이 시간이 {MIN_WIN_SEC:g}초보다 짧은 클리어는 인정되지 않습니다")
        cur = con.execute(f"""
            UPDATE runs SET status = ?, mode = ?, time_sec = ?, llm_wait_sec = ?,
                            battery = ?, orders = ?, ended_at = {_NOW}
            WHERE id = ? AND status = 'playing'""",
            (result, mode, time_sec, llm_wait_sec, battery, orders, run_id))
        if cur.rowcount == 0:  # 같은 run을 동시에 두 번 끝내려 한 경우
            raise Conflict(f"run {run_id}은(는) 이미 끝났습니다")
        if result != "win":
            return None
        r = con.execute("SELECT rank FROM v_leaderboard WHERE mode = ? AND player_id = ?",
                        (mode, row["player_id"])).fetchone()
        return int(r["rank"]) if r else None


def abandon_stale_runs(max_age_minutes: float = 180.0) -> int:
    """오래도록 끝나지 않은 run(창을 닫았거나 /restart)을 'abandoned'로 정리. 바뀐 개수를 돌려준다."""
    minutes = _number(max_age_minutes, "max_age_minutes", 0.0)
    with _connect() as con:
        cur = con.execute(f"""
            UPDATE runs SET status = 'abandoned', ended_at = {_NOW}
            WHERE status = 'playing' AND started_at < strftime('%Y-%m-%d %H:%M:%f', 'now', ?)""",
            (f"-{minutes} minutes",))
        return cur.rowcount


# ---------------------------------------------------------------- 랭킹 / 통계

_ROW_COLUMNS = "rank, run_id, name, play_sec, battery, orders, model, ended_at"


def get_leaderboard(mode: str = "llm", limit: int = 10) -> list[dict]:
    """모드별 TOP N. 플레이어마다 최고 기록 1개. 동점이면 먼저 달성한 사람이 위에 표시된다."""
    mode = _choice(mode, "mode", MODES)
    limit = _int(limit, "limit", 1, LEADERBOARD_MAX)
    with _connect() as con:
        rows = con.execute(f"""SELECT {_ROW_COLUMNS} FROM v_leaderboard WHERE mode = ?
                               ORDER BY rank, ended_at, run_id LIMIT ?""", (mode, limit)).fetchall()
    return [dict(r) for r in rows]


def get_player_rank(player: str, mode: str = "llm") -> dict | None:
    """한 플레이어의 랭킹 행 (승리 기록이 없으면 None)."""
    name = _text(player, "player", NAME_MAX, required=True)
    mode = _choice(mode, "mode", MODES)
    with _connect() as con:
        row = con.execute(f"SELECT {_ROW_COLUMNS} FROM v_leaderboard WHERE mode = ? AND name = ?",
                          (mode, name)).fetchone()
    return dict(row) if row else None


def get_stats(mode: str | None = None) -> dict:
    """끝난 판 통계: 클리어율, 평균 클리어 시간, 방별 신호 두절(패배) 횟수."""
    if mode is not None:
        mode = _choice(mode, "mode", MODES)
    with _connect() as con:
        s = con.execute("""
            SELECT COUNT(*) AS finished,
                   COALESCE(SUM(status = 'win'), 0) AS wins,
                   COALESCE(SUM(status = 'dead'), 0) AS deaths,
                   ROUND(AVG(CASE WHEN status = 'win' THEN time_sec - llm_wait_sec END), 2)
                       AS avg_win_play_sec
            FROM runs
            WHERE status IN ('win', 'dead') AND (:mode IS NULL OR mode = :mode)""",
            {"mode": mode}).fetchone()
        rooms = con.execute(f"""
            SELECT CASE WHEN last_room = '' THEN '알 수 없음' ELSE last_room END AS room,
                   COUNT(*) AS deaths
            FROM (SELECT {_LAST_ROOM} AS last_room FROM runs r
                  WHERE r.status = 'dead' AND (:mode IS NULL OR r.mode = :mode))
            GROUP BY room ORDER BY deaths DESC, room""", {"mode": mode}).fetchall()
    finished = s["finished"]
    return {
        "mode": mode,
        "finished": finished,
        "wins": s["wins"],
        "deaths": s["deaths"],
        "clear_rate": round(s["wins"] / finished, 3) if finished else None,
        "avg_win_play_sec": s["avg_win_play_sec"],
        "death_rooms": [dict(r) for r in rooms],
    }


# ---------------------------------------------------------------- 테스트·시드 전용

def _backdate(run_id: int, seconds: float) -> None:
    """run의 시작 시각을 과거로 옮긴다. 테스트와 seed.py에서만 쓴다 (서버에서 호출 금지)."""
    with _connect() as con:
        con.execute("""UPDATE runs SET started_at = strftime('%Y-%m-%d %H:%M:%f', started_at, ?)
                       WHERE id = ?""", (f"-{float(seconds)} seconds", run_id))
