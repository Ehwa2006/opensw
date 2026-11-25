#!/usr/bin/env python3
"""개발용 가짜 Ollama 서버. 실제 모델 없이 게임의 LLM 연동 경로를 테스트한다.

    python3 tools/mock_ollama.py 11500 /tmp/last_request.json
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11500
DUMP = sys.argv[2] if len(sys.argv) > 2 else None


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/tags":
            self._send({"models": [{"name": "qwen2.5:3b"}]})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if DUMP:
            with open(DUMP, "w") as f:
                json.dump(req, f, ensure_ascii=False, indent=1)
        # 작은 모델이 흔히 하는 실수(별칭, 문자열 숫자, 코드블록)를 일부러 섞는다
        content = "```json\n" + json.dumps({
            "reply": "알겠습니다... 왼쪽으로 돌아서 2미터 가겠습니다.",
            "actions": [{"type": "left", "value": 90}, {"type": "move_forward", "value": "2"},
                        {"type": "fly", "value": 3}],
        }, ensure_ascii=False) + "\n```"
        self._send({"message": {"role": "assistant", "content": content}, "done": True})

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
