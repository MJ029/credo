#!/usr/bin/env python3
"""Independent cross-check of Credo's numbers.

Reads the same Claude Code / Claude Desktop JSONL logs with the same rules
(dedupe by message id + request id, skip <synthetic> and session-result lines)
and prints token totals for Today / 7D / 30D / All.

    python3 scripts/verify_usage.py            # default folders
    python3 scripts/verify_usage.py ~/somewhere/projects   # extra folder(s)

Note: Credo's "All time" can be larger, because it also keeps history
for transcripts that Claude Code has since deleted.
"""
import json
import os
import sys
from datetime import datetime, timedelta

SKIP_DIRS = {
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "IndexedDB", "Local Storage", "Session Storage", "Service Worker", "blob_storage",
    "Crashpad", "Shared Dictionary", "WebStorage", "Network", "shared_proto_db",
    "VideoDecodeStats", "Partitions", "node_modules", "vm_bundles", "Claude Extensions",
    "Extensions", "logs", "sentry",
}


def roots(extra):
    home = os.path.expanduser("~")
    out = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        out += [(os.path.join(os.path.expanduser(p.strip()), "projects"), None) for p in env.split(",") if p.strip()]
    out += [
        (os.path.join(home, ".claude/projects"), None),
        (os.path.join(home, ".config/claude/projects"), None),
        (os.path.join(home, "Library/Application Support/Claude"), "desktop-agent"),
    ]
    out += [(os.path.expanduser(p), None) for p in extra]
    seen, uniq = set(), []
    for path, hint in out:
        real = os.path.normpath(path)
        if real not in seen:
            seen.add(real)
            uniq.append((real, hint))
    return uniq


def jsonl_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in filenames:
            if f.lower().endswith(".jsonl"):
                yield os.path.join(dirpath, f)


def parse_ts(v, fallback):
    if isinstance(v, str):
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone()
        except ValueError:
            return fallback
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v / 1000 if v > 1e12 else v).astimezone()
    return fallback


def classify(hint, entrypoint, path=""):
    e = (entrypoint or "").lower()
    if "local-agent" in e or "/local-agent-mode-sessions/" in path:
        return "desktop-agent"
    if "vscode" in e or "cursor" in e or "jetbrains" in e:
        return "vscode"
    if "desktop" in e:
        return "desktop-code"
    if e.startswith("sdk"):
        return "sdk"
    if e == "cli":
        return "cli"
    return hint or "cli"


def collect(extra):
    records = {}
    files = 0
    for root, hint in roots(extra):
        if not os.path.isdir(root):
            continue
        for path in jsonl_files(root):
            files += 1
            fallback = datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
            with open(path, "rb") as fh:
                for raw in fh:
                    if b'"usage"' not in raw:
                        continue
                    try:
                        obj = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(obj, dict) or obj.get("type") in ("result", "summary"):
                        continue
                    msg = obj.get("message")
                    if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                        continue
                    if msg.get("role", "assistant") != "assistant":
                        continue
                    model = msg.get("model") or "unknown"
                    if model == "<synthetic>":
                        continue
                    u = msg["usage"]
                    g = lambda d, k: int(d.get(k) or 0)
                    inp, out, read, create = g(u, "input_tokens"), g(u, "output_tokens"), g(u, "cache_read_input_tokens"), g(u, "cache_creation_input_tokens")
                    w5, w1 = create, 0
                    cc = u.get("cache_creation")
                    if isinstance(cc, dict) and g(cc, "ephemeral_5m_input_tokens") + g(cc, "ephemeral_1h_input_tokens") > 0:
                        w5, w1 = g(cc, "ephemeral_5m_input_tokens"), g(cc, "ephemeral_1h_input_tokens")
                    if inp + out + read + w5 + w1 == 0:
                        continue
                    ts = parse_ts(obj.get("timestamp"), fallback)
                    mid, rid = msg.get("id"), obj.get("requestId") or obj.get("request_id")
                    key = f"msg:{mid}" if mid else (f"req:{rid}" if rid else f"{path}|{ts.timestamp()}|{inp}|{out}|{read}|{create}")
                    rec = dict(ts=ts, source=classify(hint, obj.get("entrypoint"), path), model=model,
                               input=inp, output=out, cw=w5 + w1, cr=read)
                    old = records.get(key)
                    if old is None or rec["output"] > old["output"] or (
                            rec["output"] == old["output"] and sum_tokens(rec) > sum_tokens(old)):
                        records[key] = rec
    return list(records.values()), files


def sum_tokens(r):
    return r["input"] + r["output"] + r["cw"] + r["cr"]


def main():
    recs, files = collect(sys.argv[1:])
    now = datetime.now().astimezone()
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    ranges = [("Today", today), ("7D", today - timedelta(days=6)), ("30D", today - timedelta(days=29)), ("All", None)]
    print(f"{len(recs)} API calls from {files} log files")
    for name, start in ranges:
        sel = [r for r in recs if start is None or r["ts"] >= start]
        tot = lambda k: sum(r[k] for r in sel)
        by_src = {}
        for r in sel:
            by_src[r["source"]] = by_src.get(r["source"], 0) + sum_tokens(r)
        print(f"{name:>5}: total {tot('input') + tot('output') + tot('cw') + tot('cr'):>14,}  "
              f"in {tot('input'):,}  out {tot('output'):,}  cache-write {tot('cw'):,}  cache-read {tot('cr'):,}  "
              f"requests {len(sel):,}  by tool {by_src}")


if __name__ == "__main__":
    main()
