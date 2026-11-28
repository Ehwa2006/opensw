"""DB 계층 테스트. server/ 폴더에서 `python -m pytest` 로 실행한다."""
import threading

import pytest

from app import db


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    db.configure(tmp_path / "test.db")
    db.init_db()
    monkeypatch.setattr(db, "MIN_WIN_SEC", 20.0)
    yield


def play(player, *, result="win", play_sec=100.0, llm_wait=0.0, battery=50.0, orders=10,
         mode="llm", model="qwen2.5:3b"):
    """한 판을 시작부터 끝까지 기록한다. 서버 시계 검증을 통과하도록 시작 시각을 과거로 옮긴다."""
    run_id = db.create_run(player, model)
    db._backdate(run_id, play_sec + llm_wait + 1)
    rank = db.finish_run(run_id, result, play_sec + llm_wait, llm_wait, battery, orders, mode)
    return run_id, rank


def names(mode="llm", limit=10):
    return [r["name"] for r in db.get_leaderboard(mode, limit)]


# ---------------------------------------------------------------- 초기화 / 플레이어

def test_init_db_is_idempotent():
    play("A")
    db.init_db()
    assert names() == ["A"]


def test_same_name_reuses_player_case_insensitive():
    r1 = db.create_run("Kim")
    r2 = db.create_run(" kim ")
    assert r2 > r1
    assert db.get_run(r1)["player"] == db.get_run(r2)["player"] == "Kim"


@pytest.mark.parametrize("bad", ["", "   ", "x" * 17, "a\nb", None, 3])
def test_invalid_player_name(bad):
    with pytest.raises(ValueError):
        db.create_run(bad)


def test_get_run_unknown_is_none():
    assert db.get_run(12345) is None


# ---------------------------------------------------------------- 이벤트

def test_add_event_returns_news_and_tracks_last_room():
    rid = db.create_run("A")
    news = db.add_event(rid, "room_enter", 12.5, "복도", 93.0)
    assert news == {"run_id": rid, "name": "A", "type": "room_enter", "room": "복도",
                    "battery": 93.0, "t_sec": 12.5, "rank": None}
    db.add_event(rid, "keycard", 40.0)            # 방 이름 없는 이벤트는 last_room에 영향 없음
    assert db.get_run(rid)["last_room"] == "복도"
    db.add_event(rid, "room_enter", 50.0, "영안실")
    assert db.get_run(rid)["last_room"] == "영안실"


def test_add_event_accepts_godot_float_ids():
    rid = db.create_run("A")
    assert db.add_event(float(rid), "keycard", 1.0)["run_id"] == rid


def test_add_event_errors():
    rid = db.create_run("A")
    with pytest.raises(db.NotFound):
        db.add_event(rid + 100, "keycard", 1.0)
    with pytest.raises(ValueError):
        db.add_event(rid, "teleport", 1.0)
    with pytest.raises(ValueError):
        db.add_event(rid, "battery_low", 1.0, "복도", 120.0)
    db._backdate(rid, 60)
    db.finish_run(rid, "dead", 50.0, 0.0, 0.0, 5, "llm")
    with pytest.raises(db.Conflict):
        db.add_event(rid, "keycard", 1.0)


# ---------------------------------------------------------------- 종료

def test_finish_win_returns_rank_and_dead_returns_none():
    _, rank = play("A", play_sec=100)
    assert rank == 1
    _, rank = play("B", result="dead", battery=0)
    assert rank is None
    assert names() == ["A"]


def test_finish_twice_conflicts_and_unknown_not_found():
    rid, _ = play("A")
    with pytest.raises(db.Conflict):
        db.finish_run(rid, "win", 100.0, 0.0, 50.0, 10, "llm")
    with pytest.raises(db.NotFound):
        db.finish_run(rid + 100, "win", 100.0, 0.0, 50.0, 10, "llm")


def test_finish_rejects_time_longer_than_server_clock():
    rid = db.create_run("A")
    db._backdate(rid, 30)
    with pytest.raises(ValueError, match="경과 시간"):
        db.finish_run(rid, "win", 300.0, 0.0, 50.0, 10, "llm")
    # 같은 run이라도 정상 값이면 통과 (거부된 시도는 기록을 바꾸지 않는다)
    assert db.finish_run(rid, "win", 30.0, 0.0, 50.0, 10, "llm") == 1


def test_finish_rejects_impossibly_fast_win_but_allows_fast_death(monkeypatch):
    rid = db.create_run("A")
    db._backdate(rid, 60)
    with pytest.raises(ValueError, match="20초"):
        db.finish_run(rid, "win", 50.0, 45.0, 50.0, 3, "llm")   # 플레이 시간 5초
    assert db.finish_run(rid, "dead", 5.0, 0.0, 0.0, 1, "llm") is None
    monkeypatch.setattr(db, "MIN_WIN_SEC", 0.0)
    rid = db.create_run("B")
    assert db.finish_run(rid, "win", 0.5, 0.0, 99.0, 1, "llm") == 1


@pytest.mark.parametrize("kwargs", [
    {"result": "draw"}, {"mode": "cheat"}, {"battery": -1}, {"battery": 101},
    {"orders": -1}, {"orders": 2.5}, {"time_sec": float("nan")}, {"llm_wait_sec": 200.0},
    {"time_sec": True},
])
def test_finish_validation(kwargs):
    rid = db.create_run("A")
    db._backdate(rid, 200)
    args = {"result": "win", "time_sec": 100.0, "llm_wait_sec": 0.0, "battery": 50.0,
            "orders": 10, "mode": "llm"} | kwargs
    with pytest.raises(ValueError):
        db.finish_run(rid, **args)
    assert db.get_run(rid)["status"] == "playing"


def test_concurrent_finish_only_one_wins():
    rid = db.create_run("A")
    db._backdate(rid, 200)
    outcomes = []

    def finish():
        try:
            db.finish_run(rid, "win", 100.0, 0.0, 50.0, 10, "llm")
            outcomes.append("ok")
        except db.Conflict:
            outcomes.append("conflict")

    threads = [threading.Thread(target=finish) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(outcomes) == ["conflict"] * 7 + ["ok"]


# ---------------------------------------------------------------- 랭킹

def test_ranking_order_play_time_then_battery_then_orders():
    play("느림", play_sec=200, battery=90)
    play("배터리적음", play_sec=100, battery=20)
    play("배터리많음", play_sec=100, battery=60, orders=30)
    play("명령적음", play_sec=100, battery=60, orders=5)
    rows = db.get_leaderboard("llm")
    assert [r["name"] for r in rows] == ["명령적음", "배터리많음", "배터리적음", "느림"]
    assert [r["rank"] for r in rows] == [1, 2, 3, 4]


def test_llm_wait_time_is_excluded():
    play("큰모델", play_sec=90, llm_wait=300)     # 총 390초지만 플레이는 90초
    play("작은모델", play_sec=100, llm_wait=10)
    rows = db.get_leaderboard("llm")
    assert [r["name"] for r in rows] == ["큰모델", "작은모델"]
    assert rows[0]["play_sec"] == 90.0


def test_ties_share_rank_and_earlier_achiever_listed_first():
    play("먼저", play_sec=100, battery=50, orders=10)
    play("나중", play_sec=100, battery=50, orders=10)
    play("셋째", play_sec=150)
    rows = db.get_leaderboard("llm")
    assert [(r["rank"], r["name"]) for r in rows] == [(1, "먼저"), (1, "나중"), (3, "셋째")]


def test_only_personal_best_counts():
    play("A", play_sec=150)
    _, rank = play("A", play_sec=300)          # 더 느린 기록 → 순위는 개인 최고 기준
    assert rank == 1
    play("B", play_sec=120)
    rows = db.get_leaderboard("llm")
    assert [(r["name"], r["play_sec"]) for r in rows] == [("B", 120.0), ("A", 150.0)]


def test_modes_are_ranked_separately():
    play("온라인", play_sec=200, mode="llm")
    play("오프라인", play_sec=50, mode="offline")
    assert names("llm") == ["온라인"]
    assert names("offline") == ["오프라인"]
    _, rank = play("온라인", play_sec=40, mode="offline")
    assert rank == 1 and names("offline") == ["온라인", "오프라인"]


def test_leaderboard_limit_and_validation():
    for i in range(5):
        play(f"P{i}", play_sec=100 + i)
    assert names(limit=3) == ["P0", "P1", "P2"]
    with pytest.raises(ValueError):
        db.get_leaderboard("llm", 0)
    with pytest.raises(ValueError):
        db.get_leaderboard("hard")


def test_get_player_rank():
    play("A", play_sec=100)
    play("B", play_sec=50)
    assert db.get_player_rank("a")["rank"] == 2
    assert db.get_player_rank("없는사람") is None


# ---------------------------------------------------------------- 정리 / 통계

def test_abandon_stale_runs():
    old = db.create_run("A")
    db._backdate(old, 4 * 3600)
    new = db.create_run("A")
    assert db.abandon_stale_runs(180) == 1
    assert db.get_run(old)["status"] == "abandoned"
    assert db.get_run(new)["status"] == "playing"


def test_stats_clear_rate_and_death_rooms():
    play("A", play_sec=100)
    play("B", play_sec=200)
    for room in ["영안실", "영안실", "복도"]:
        rid = db.create_run("C")
        db.add_event(rid, "room_enter", 10.0, "복도")
        if room != "복도":
            db.add_event(rid, "room_enter", 30.0, room)
        db.add_event(rid, "battery_low", 40.0, "", 15.0)
        db._backdate(rid, 200)
        db.finish_run(rid, "dead", 150.0, 0.0, 0.0, 20, "llm")
    rid = db.create_run("D")                    # 이벤트 없이 사망
    db._backdate(rid, 60)
    db.finish_run(rid, "dead", 50.0, 0.0, 0.0, 3, "offline")

    s = db.get_stats("llm")
    assert (s["finished"], s["wins"], s["deaths"]) == (5, 2, 3)
    assert s["clear_rate"] == 0.4
    assert s["avg_win_play_sec"] == 150.0
    assert s["death_rooms"] == [{"room": "영안실", "deaths": 2}, {"room": "복도", "deaths": 1}]
    assert db.get_stats("offline")["death_rooms"] == [{"room": "알 수 없음", "deaths": 1}]
    assert db.get_stats()["finished"] == 6


def test_stats_empty():
    assert db.get_stats() == {"mode": None, "finished": 0, "wins": 0, "deaths": 0,
                              "clear_rate": None, "avg_win_play_sec": None, "death_rooms": []}
