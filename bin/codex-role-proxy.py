#!/usr/bin/env python3
# codex-role-proxy — rewrite the OpenAI 'developer' role -> 'system' on the way to vLLM.
#
# Why: Codex CLI sends its base instructions as a `developer`-role message (OpenAI Responses
# API). vLLM 0.30.0 rejects it at request-parsing time ("Unknown message role: developer") for
# EVERY model (HF chat templates and mistral_common both reject it). This sits between Codex and
# the SSM tunnel, flips developer->system in the request body, and streams the response through
# untouched — so any served model works with Codex until upstream vLLM adds developer-role support.
#
#   PROXY_UPSTREAM=http://localhost:8000  PROXY_PORT=8891  python3 codex-role-proxy.py
#
# Codex then points base_url at http://localhost:$PROXY_PORT/v1 instead of the tunnel directly.
import http.server, socketserver, urllib.request, urllib.error, json, os

UPSTREAM = os.environ.get("PROXY_UPSTREAM", "http://localhost:8000").rstrip("/")
PORT = int(os.environ.get("PROXY_PORT", "8891"))
_HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate"}


def _flatten(content):
    # vLLM 0.30.0's Responses API accepts plain-string content but rejects the OpenAI typed
    # content chunks ('input_text' -> "not a valid ChunkTypes"). Flatten text parts to a string.
    if isinstance(content, list):
        out = []
        for p in content:
            if isinstance(p, str):
                out.append(p)
            elif isinstance(p, dict):
                t = p.get("text", p.get("input_text"))
                if t is not None:
                    out.append(t)
        return "\n".join(out)
    return content


def _rewrite(body: bytes) -> bytes:
    try:
        d = json.loads(body)
    except Exception:
        return body
    changed = False

    def fix(items):
        nonlocal changed
        if not isinstance(items, list):
            return
        for it in items:
            if not isinstance(it, dict):
                continue
            if it.get("role") == "developer":       # vLLM rejects the 'developer' role
                it["role"] = "system"; changed = True
            if isinstance(it.get("content"), list):  # vLLM rejects 'input_text' content chunks
                it["content"] = _flatten(it["content"]); changed = True

    fix(d.get("input"))       # Responses API input items
    fix(d.get("messages"))    # Chat Completions messages
    return json.dumps(d).encode() if changed else body


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self, method):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else b""
        if method == "POST" and ("/responses" in self.path or "/chat/completions" in self.path):
            body = _rewrite(body)
        req = urllib.request.Request(UPSTREAM + self.path, data=body or None, method=method)
        for k, v in self.headers.items():
            if k.lower() not in _HOP and k.lower() != "host":
                req.add_header(k, v)
        if body:
            req.add_header("Content-Length", str(len(body)))
        try:
            resp = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            self.send_response(502); self.end_headers()
            self.wfile.write(str(e).encode())
            return
        self.send_response(getattr(resp, "status", 200))
        for k, v in resp.headers.items():
            if k.lower() not in _HOP:
                self.send_header(k, v)
        self.send_header("Connection", "close")   # close-delimited: robust for SSE streaming
        self.end_headers()
        try:
            while True:
                chunk = resp.read(1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception:
            pass

    def do_POST(self): self._proxy("POST")
    def do_GET(self): self._proxy("GET")
    def log_message(self, *a): pass


if __name__ == "__main__":
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H) as s:
        print(f"codex-role-proxy: 127.0.0.1:{PORT} -> {UPSTREAM} (developer->system)", flush=True)
        s.serve_forever()
