"""Loopback-only protocol test; responses are fixtures, not an actual model."""
import argparse
import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("Authorization") != "Bearer test-session-key":
            self.send_error(401)
            return
        if self.path == "/slow":
            time.sleep(3)
        if self.path == "/error":
            self.send_response(503)
            self.end_headers()
            return
        if self.path == "/malformed":
            data = b"this is not JSON"
        else:
            context = json.loads(payload["messages"][1]["content"])
            action = {"candidate_id": context["candidates"][0]["id"], "reason_summary": "测试协议响应"}
            data = json.dumps({"choices": [{"message": {"content": json.dumps(action, ensure_ascii=False)}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parents[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        command = [args.godot, "--headless", "--path", str(workspace), "--script", "tests/war_agent_http_validation.gd", "--", str(server.server_port)]
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=45)
        print(completed.stdout, end="")
        print(completed.stderr, end="")
        if completed.returncode or "WAR_AGENT_HTTP_OK" not in completed.stdout or "ERROR:" in completed.stderr:
            raise SystemExit(completed.returncode or 1)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
