-- LOST SIGNAL 랭킹 DB 스키마 (DB·통합 담당)
-- SQLite 3.25 이상 필요 (RANK/ROW_NUMBER 윈도 함수). 여러 번 실행해도 안전하다 (IF NOT EXISTS).
-- 계약 문서: docs/API.md

-- 플레이어: 로그인 없이 이름으로만 구분 (대소문자 무시)
CREATE TABLE IF NOT EXISTS players (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE COLLATE NOCASE
               CHECK (length(name) BETWEEN 1 AND 16),
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now'))
);

-- 한 판(run). 시작할 때 'playing'으로 만들고, 끝나면 win/dead로 바꾼다.
-- started_at/ended_at은 서버 시계 기준 (게임이 보낸 time_sec 검증에 사용).
CREATE TABLE IF NOT EXISTS runs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id    INTEGER NOT NULL REFERENCES players(id),
    status       TEXT    NOT NULL DEFAULT 'playing'
                 CHECK (status IN ('playing', 'win', 'dead', 'abandoned')),
    mode         TEXT    CHECK (mode IN ('llm', 'offline')),
    model        TEXT    NOT NULL DEFAULT '',
    version      TEXT    NOT NULL DEFAULT 'dev',
    started_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now')),
    ended_at     TEXT,
    time_sec     REAL    CHECK (time_sec >= 0),
    llm_wait_sec REAL    CHECK (llm_wait_sec >= 0),
    battery      REAL    CHECK (battery BETWEEN 0 AND 100),
    orders       INTEGER CHECK (orders >= 0),
    -- 끝난 판(win/dead)은 기록 값이 반드시 있어야 한다
    CHECK (status NOT IN ('win', 'dead') OR (mode IS NOT NULL AND time_sec IS NOT NULL
           AND llm_wait_sec IS NOT NULL AND battery IS NOT NULL AND orders IS NOT NULL
           AND ended_at IS NOT NULL)),
    CHECK (llm_wait_sec IS NULL OR time_sec IS NULL OR llm_wait_sec <= time_sec)
);
CREATE INDEX IF NOT EXISTS idx_runs_rank    ON runs (status, mode, player_id);
CREATE INDEX IF NOT EXISTS idx_runs_playing ON runs (status, started_at);

-- 진행 이벤트: 매 프레임이 아니라 의미 있는 순간만 저장
CREATE TABLE IF NOT EXISTS run_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     INTEGER NOT NULL REFERENCES runs(id),
    type       TEXT    NOT NULL
               CHECK (type IN ('room_enter', 'keycard', 'exit_open', 'battery_low')),
    t_sec      REAL    NOT NULL CHECK (t_sec >= 0),
    room       TEXT    NOT NULL DEFAULT '',
    battery    REAL    CHECK (battery BETWEEN 0 AND 100),
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_events_run ON run_events (run_id, t_sec);

-- 랭킹 뷰: 모드별로, 플레이어마다 최고 기록 1개만 남기고 순위를 매긴다.
-- 정렬 기준: 실제 플레이 시간(time_sec - llm_wait_sec) 짧은 순 → 남은 배터리 많은 순 → 명령 수 적은 순
-- 기준이 완전히 같으면 같은 순위 (RANK: 1, 1, 3 ...)
CREATE VIEW IF NOT EXISTS v_leaderboard AS
WITH wins AS (
    SELECT r.id AS run_id, r.player_id, p.name, r.mode, r.model,
           ROUND(r.time_sec - r.llm_wait_sec, 2) AS play_sec,
           r.time_sec, r.battery, r.orders, r.ended_at
    FROM runs r JOIN players p ON p.id = r.player_id
    WHERE r.status = 'win'
),
best AS (
    SELECT *, ROW_NUMBER() OVER (
               PARTITION BY player_id, mode
               ORDER BY play_sec, battery DESC, orders, run_id
           ) AS nth
    FROM wins
)
SELECT RANK() OVER (PARTITION BY mode ORDER BY play_sec, battery DESC, orders) AS rank,
       mode, run_id, player_id, name, play_sec, time_sec, battery, orders, model, ended_at
FROM best
WHERE nth = 1;
