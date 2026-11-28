"""docs/API.md의 요청·응답 형식을 코드로 옮긴 것 (DB·통합 담당).

실제 서버(서버 담당)와 tools/mock_server.py가 같이 import해서, 두 서버가 똑같이 검증하게 한다.
계약을 바꿀 때는 docs/API.md와 이 파일을 같은 PR에서 함께 고친다.
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

# Socket.IO 이벤트 이름
EV_RUN_EVENT = "run:event"                 # 게임 → 서버
EV_RUN_NEWS = "run:news"                   # 서버 → 전체
EV_LEADERBOARD_UPDATE = "leaderboard:update"  # 서버 → 전체

Mode = Literal["llm", "offline"]
Result = Literal["win", "dead"]
EventType = Literal["room_enter", "keycard", "exit_open", "battery_low"]
NewsType = Literal["room_enter", "keycard", "exit_open", "battery_low", "win", "dead"]


class _In(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="ignore")


# ---------------------------------------------------------------- REST

class RunCreate(_In):
    """POST /api/runs"""
    player: str = Field(min_length=1, max_length=16)
    model: str = Field(default="", max_length=64)
    version: str = Field(default="dev", max_length=16)


class RunCreated(BaseModel):
    run_id: int


class RunFinish(_In):
    """POST /api/runs/{run_id}/finish"""
    result: Result
    time_sec: float = Field(ge=0, le=86400)
    llm_wait_sec: float = Field(default=0, ge=0, le=86400)
    battery: float = Field(ge=0, le=100)
    orders: int = Field(ge=0, le=100000)
    mode: Mode


class RunFinished(BaseModel):
    rank: Optional[int]


class LeaderboardRow(BaseModel):
    rank: int
    run_id: int
    name: str
    play_sec: float
    battery: float
    orders: int
    model: str
    ended_at: str


class Leaderboard(BaseModel):
    """GET /api/leaderboard 응답, leaderboard:update 내용"""
    mode: Mode
    rows: list[LeaderboardRow]


# ---------------------------------------------------------------- Socket.IO

class RunEvent(_In):
    """run:event (게임 → 서버)"""
    run_id: int
    type: EventType
    t_sec: float = Field(ge=0)
    room: str = Field(default="", max_length=64)
    battery: Optional[float] = Field(default=None, ge=0, le=100)


class RunNews(BaseModel):
    """run:news (서버 → 전체). rank는 type이 win일 때만 숫자"""
    run_id: int
    name: str
    type: NewsType
    room: str
    battery: Optional[float]
    t_sec: float
    rank: Optional[int] = None


def ack_ok() -> dict:
    return {"ok": True}


def ack_error(code: int, error: str) -> dict:
    """run:event ack 실패 응답. code는 HTTP 상태와 같은 뜻 (404, 409, 422)"""
    return {"ok": False, "code": code, "error": error}
