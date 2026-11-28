#!/usr/bin/env python3
"""시연용 샘플 데이터 넣기 (DB·통합 담당). server/ 폴더에서 실행한다.

    python seed.py                 # 기본 DB(data/lost_signal.db)에 데모 기록 추가
    python seed.py --reset         # DB 파일을 지우고 새로 만든 뒤 추가
    LOST_SIGNAL_DB=/tmp/demo.db python seed.py --reset

데모 플레이어 이름은 모두 '데모_'로 시작한다.
"""
import argparse
import random

from app import db

PLAYERS = ["데모_하늘", "데모_바다", "데모_별", "데모_달", "데모_숲", "데모_구름", "데모_바람", "데모_노을"]
MODELS = ["qwen2.5:3b", "qwen2.5:7b", "gemma3:4b"]
# 실제 탈출 경로: 창고 → 복도 → 영안실(카드키) → 복도 → 로비(비상구). (방, 진행 비율)
PATH = [("창고", 0.0), ("복도", 0.15), ("영안실", 0.35), ("복도", 0.6), ("로비", 0.8)]


def seed_run(rng: random.Random, player: str) -> None:
    mode = "offline" if rng.random() < 0.25 else "llm"
    win = rng.random() < 0.6
    play = rng.uniform(80, 420)
    wait = 0.0 if mode == "offline" else play * rng.uniform(0.1, 0.6)
    total = play + wait
    end_battery = round(rng.uniform(5, 55), 1) if win else 0.0

    def battery_at(frac: float) -> float:
        return round(100 - (100 - end_battery) * frac, 1)

    run_id = db.create_run(player, rng.choice(MODELS), "demo")
    db._backdate(run_id, total + 5)
    stop = len(PATH) if win else rng.randint(1, len(PATH))   # 패배면 중간 방에서 신호 두절
    for room, frac in PATH[:stop]:
        db.add_event(run_id, "room_enter", round(total * frac, 1), room, battery_at(frac))
        if room == "영안실":
            db.add_event(run_id, "keycard", round(total * (frac + 0.05), 1), room, battery_at(frac + 0.05))
    if win:
        db.add_event(run_id, "exit_open", round(total * 0.95, 1), "로비", battery_at(0.95))
    else:
        last_room = PATH[stop - 1][0]
        db.add_event(run_id, "battery_low", round(total * 0.9, 1), last_room, 15.0)
    db.finish_run(run_id, "win" if win else "dead", round(total, 2), round(wait, 2),
                  end_battery, rng.randint(8, 45), mode)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reset", action="store_true", help="DB 파일을 지우고 새로 만든다")
    ap.add_argument("--seed", type=int, default=42, help="난수 시드 (같은 값이면 같은 데이터)")
    args = ap.parse_args()

    path = db.db_path()
    if args.reset:
        for suffix in ("", "-wal", "-shm"):
            p = path.with_name(path.name + suffix)
            if p.exists():
                p.unlink()
        print(f"DB 초기화: {path}")
    db.init_db()

    rng = random.Random(args.seed)
    count = 0
    for player in PLAYERS:
        for _ in range(rng.randint(1, 3)):
            seed_run(rng, player)
            count += 1
    print(f"데모 기록 {count}판 추가 → {path}\n")

    for mode in db.MODES:
        print(f"[{mode}] TOP 5")
        for r in db.get_leaderboard(mode, 5):
            print(f"  {r['rank']:>2}위  {r['name']:<8}  {r['play_sec']:7.1f}초  "
                  f"배터리 {r['battery']:4.1f}%  명령 {r['orders']}회  ({r['model']})")
    s = db.get_stats()
    print(f"\n전체 {s['finished']}판, 클리어율 {s['clear_rate']}, 신호 두절 위치: {s['death_rooms']}")


if __name__ == "__main__":
    main()
