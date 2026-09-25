#!/usr/bin/env python3
# Unit tests for bin/codex-role-proxy.py _rewrite — the Codex<->vLLM/Qwen3.8 request transforms.
# Run: python3 tests/test_proxy.py
import importlib.util, json, os, sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROXY = os.path.join(_HERE, "..", "bin", "codex-role-proxy.py")
spec = importlib.util.spec_from_file_location("proxy", _PROXY)
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)  # importing is safe; the server only starts under __main__


def rw(d):
    return json.loads(proxy._rewrite(json.dumps(d).encode()))


fails = 0
def check(name, cond, got=None):
    global fails
    if cond:
        print(f"  PASS  {name}")
    else:
        fails += 1
        print(f"  FAIL  {name}  got={got!r}")


# 1) Responses API: developer->system + input_text flatten + fold system into `instructions`
d = rw({"instructions": "BASE", "input": [
    {"role": "developer", "content": [{"type": "input_text", "text": "DEV"}]},
    {"role": "user", "content": [{"type": "input_text", "text": "hi"}]},
]})
check("developer/system folded into instructions", d["instructions"] == "BASE\n\nDEV", d.get("instructions"))
check("no system left in input", all(it.get("role") != "system" for it in d["input"]), d["input"])
check("input_text flattened to string", d["input"][0]["content"] == "hi", d["input"])
check("only the user item remains", [it["role"] for it in d["input"]] == ["user"], d["input"])

# 2) Responses API: strip `reasoning` items (vLLM rejects them)
d = rw({"input": [
    {"role": "user", "content": "hi"},
    {"type": "reasoning", "content": "THINK"},
    {"role": "user", "content": "more"},
]})
check("reasoning items stripped", all(it.get("type") != "reasoning" for it in d["input"]), d["input"])
check("users preserved", [it["role"] for it in d["input"]] == ["user", "user"], d["input"])

# 3) Chat Completions (no `instructions`): hoist+merge system to a single leading message
d = rw({"messages": [
    {"role": "user", "content": "hi"},
    {"role": "developer", "content": "SYS"},
]})
check("system hoisted to front", d["messages"][0]["role"] == "system", d["messages"])
check("system content preserved", d["messages"][0]["content"] == "SYS", d["messages"])
check("user still present", d["messages"][-1]["role"] == "user", d["messages"])

# 4) No-op on a plain leading-user body
d = rw({"input": [{"role": "user", "content": "hi"}]})
check("plain user body untouched", d["input"] == [{"role": "user", "content": "hi"}], d["input"])

print(f"\n{'ALL PROXY TESTS PASS' if fails == 0 else str(fails) + ' FAILURES'}")
sys.exit(1 if fails else 0)
