#!/usr/bin/env python3
"""llm-eval.py — Quality eval for local_LLM (the missing half of benchmark.sh).

benchmark.sh measures SPEED (tok/s, VRAM). This measures QUALITY: run a set of
prompts against the local server and verify responses with deterministic checks
(string, regex, JSON, and executed Python). No judge model required.

Usage:
  python3 scripts/llm-eval.py [eval_set] [output_file] [--limit N] [--tag TAG]

Config (same convention as benchmark.sh — no config file):
  SERVER_URL   default http://localhost:8080
  MODEL_NAME   default local-model
  MAX_TOKENS   default 2048
  TEMPERATURE  default 0.0

Exit code: 0 if all cases pass, 1 otherwise.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EVAL_SET = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else os.path.join(SCRIPT_DIR, "../evals/eval-set.json")

OUTPUT_FILE = os.path.join(SCRIPT_DIR, "../evals/results/eval_results.json")
args = [a for a in sys.argv[1:] if not a.startswith("-")]
if len(args) > 1:
    OUTPUT_FILE = args[1]

LIMIT = None
TAG = None
for i, a in enumerate(sys.argv):
    if a == "--limit" and i + 1 < len(sys.argv):
        LIMIT = int(sys.argv[i + 1])
    if a == "--tag" and i + 1 < len(sys.argv):
        TAG = sys.argv[i + 1]

SERVER_URL = os.environ.get("SERVER_URL", "http://localhost:8080").rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "local-model")
# Default 2048, not 512: thinking models (e.g. Qwen3.6) burn hundreds of tokens
# on reasoning_content before emitting any content. 512 leaves content empty
# with finish_reason="length", which fails every case for the wrong reason.
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "2048"))
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0.0"))


def chat(prompt):
    payload = json.dumps({
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
    }).encode()
    req = urllib.request.Request(
        f"{SERVER_URL}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    choice = data["choices"][0]
    return choice["message"]["content"] or "", choice.get("finish_reason"), data.get("usage", {})


def extract_python(response):
    m = re.search(r"```(?:python)?\s*\n(.*?)```", response, re.DOTALL)
    return m.group(1) if m else response


def run_check(check, response):
    ctype = check["type"]
    value = check.get("value", "")
    if check.get("ignore_case"):
        haystack, needle = response.lower(), str(value).lower()
    else:
        haystack, needle = response, str(value)

    if ctype == "contains":
        return needle in haystack
    if ctype == "not_contains":
        return needle not in haystack
    if ctype == "exact":
        return response.strip() == str(value)
    if ctype == "regex":
        return re.search(value, response, re.MULTILINE) is not None
    if ctype == "min_length":
        return len(response.strip()) >= int(value)
    if ctype == "json_valid":
        try:
            json.loads(re.sub(r"^```(?:json)?\s*|```$", "", response.strip(), flags=re.MULTILINE))
            return True
        except json.JSONDecodeError:
            return False
    if ctype == "json_keys":
        try:
            obj = json.loads(re.sub(r"^```(?:json)?\s*|```$", "", response.strip(), flags=re.MULTILINE))
            return all(k in obj for k in value)
        except json.JSONDecodeError:
            return False
    if ctype == "py_exec":
        namespace = {}
        exec(extract_python(response), namespace)  # noqa: S102 - local eval of own models only
        return bool(eval(check["expect"], namespace))  # noqa: S307
    raise ValueError(f"unknown check type: {ctype}")


def docker_config():
    try:
        out = subprocess.run(
            ["docker", "inspect", "llm-server",
             "--format", "{{.Config.Image}}"],
            capture_output=True, text=True, timeout=10)
        return {"image": out.stdout.strip()} if out.returncode == 0 else {}
    except (OSError, subprocess.TimeoutExpired):
        return {}


def main():
    with open(EVAL_SET) as f:
        spec = json.load(f)
    cases = [c for c in spec["cases"] if TAG is None or c.get("tag") == TAG]
    if LIMIT:
        cases = cases[:LIMIT]

    print(f"=== LLM Quality Eval — {MODEL_NAME} @ {SERVER_URL} ===")
    print(f"Cases: {len(cases)} from {os.path.basename(EVAL_SET)} (v{spec.get('version')})")
    print(f"Temperature: {TEMPERATURE}, max_tokens: {MAX_TOKENS}")
    print("")

    try:
        urllib.request.urlopen(f"{SERVER_URL}/health", timeout=5)
    except OSError:
        print(f"Error: server not running at {SERVER_URL}", file=sys.stderr)
        sys.exit(2)

    results = []
    for c in cases:
        t0 = time.time()
        try:
            response, finish_reason, usage = chat(c["prompt"])
            latency = time.time() - t0
            check_results = [
                {"type": chk["type"], "pass": run_check(chk, response)}
                for chk in c["checks"]
            ]
            passed = all(r["pass"] for r in check_results)
            if finish_reason == "length":
                check_results.append({"type": "truncated", "pass": False})
                passed = False
        except Exception as e:  # noqa: BLE001 - record and continue, one bad case shouldn't kill the run
            response, latency, usage, finish_reason = f"<error: {e}>", time.time() - t0, {}, None
            check_results, passed = [], False

        results.append({
            "id": c["id"], "tag": c.get("tag"), "pass": passed,
            "checks": check_results, "finish_reason": finish_reason,
            "completion_tokens": usage.get("completion_tokens"),
            "latency_s": round(latency, 2),
        })
        mark = "PASS" if passed else "FAIL"
        detail = "" if passed else " " + json.dumps(check_results)
        print(f"  [{mark}] {c['id']} ({usage.get('completion_tokens', '?')} tok, {latency:.1f}s){detail}")

    n_pass = sum(1 for r in results if r["pass"])
    by_tag = {}
    for r in results:
        t = by_tag.setdefault(r["tag"] or "untagged", [0, 0])
        t[1] += 1
        t[0] += 1 if r["pass"] else 0

    print("")
    print(f"=== {n_pass}/{len(results)} passed ({100*n_pass/len(results):.0f}%) ===")
    for tag, (p, n) in sorted(by_tag.items()):
        print(f"  {tag}: {p}/{n}")

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    report = {
        "test": "local-llm-quality-eval",
        "eval_set_version": spec.get("version"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "hostname": os.uname().nodename,
        "model": MODEL_NAME,
        "server_url": SERVER_URL,
        "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS,
        "docker_config": docker_config(),
        "summary": {"passed": n_pass, "total": len(results),
                    "pass_rate": round(n_pass / len(results), 4),
                    "by_tag": {t: {"passed": p, "total": n} for t, (p, n) in by_tag.items()}},
        "cases": results,
    }
    with open(OUTPUT_FILE, "w") as f:
        json.dump(report, f, indent=2)
    print(f"Results saved to {OUTPUT_FILE}")

    sys.exit(0 if n_pass == len(results) else 1)


if __name__ == "__main__":
    main()
