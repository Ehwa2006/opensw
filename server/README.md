# server/ — 랭킹 서버와 DB

계약(요청·응답·이벤트 형식)은 [`docs/API.md`](../docs/API.md)를 기준으로 한다.

```
server/
  schema.sql          DB 스키마 (players, runs, run_events, v_leaderboard 뷰)     ← DB·통합
  app/db.py           DB 함수 — 서버는 SQL 대신 이것만 호출                          ← DB·통합
  app/contract.py     API 요청·응답 형식 (pydantic) — 서버·가짜 서버가 같이 사용     ← DB·통합
  app/main.py         FastAPI + Socket.IO 서버                                      ← 서버
  tests/              DB 테스트 (pytest)
  seed.py             시연용 샘플 데이터
../tools/mock_server.py        가짜 서버 (DB 없음, Godot 개발용)
../tools/integration_check.py  계약대로 동작하는지 처음부터 끝까지 점검
```

## 준비

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## 자주 쓰는 명령 (server/ 폴더에서)

```bash
python -m pytest                      # DB 테스트
python seed.py --reset                # 데모 데이터로 DB 새로 만들기 (data/lost_signal.db)
uvicorn app.main:asgi_app --port 8000 # 실제 서버 실행 (main.py 완성 후)
```

```bash
# Godot 개발용 가짜 서버 (저장소 루트에서). --chatter 15: 15초마다 가짜 '다른 조종사' 소식
python3 tools/mock_server.py --port 8000 --chatter 15

# 통합 점검: 가짜 서버나 실제 서버를 띄워 둔 상태에서
python3 tools/integration_check.py --url http://127.0.0.1:8000
```

실제 서버를 점검할 때는 테스트용 DB와 최소 클리어 시간 0으로 띄운다 (진짜 랭킹을 더럽히지 않도록):

```bash
LOST_SIGNAL_DB=/tmp/it.db LOST_SIGNAL_MIN_WIN_SEC=0 uvicorn app.main:asgi_app --port 8000
```

## 환경변수

| 이름 | 기본값 | 설명 |
|---|---|---|
| `LOST_SIGNAL_DB` | `server/data/lost_signal.db` | DB 파일 경로 |
| `LOST_SIGNAL_MIN_WIN_SEC` | `20` | 이보다 빠른 클리어(플레이 시간 기준)는 거부 |

## 수업 시연

노트북 한 대에서 `uvicorn app.main:asgi_app --host 0.0.0.0 --port 8000`으로 띄우면
같은 와이파이의 다른 PC는 `http://<그 노트북 IP>:8000`으로 접속할 수 있다.
