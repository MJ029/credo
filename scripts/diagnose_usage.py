#!/usr/bin/env python3
"""Explains differences between Credo and other usage counters.

For every log folder it reports token totals two ways:
  * per API call  - each response counted once (what Credo shows, matches billing)
  * per log line  - every line carrying a usage block counted (Claude Code writes one
                    line per content block, so a single response can appear 2-4 times)

Only counts, dates and model names are written — no prompts, code or project names.
Output: diagnose.txt next to this project.
"""
import collections
import json
import os
import sys
from datetime import datetime, timedelta, timezone

SKIP_DIRS = {
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "IndexedDB", "Local Storage", "Session Storage", "Service Worker", "blob_storage",
    "Crashpad", "Shared Dictionary", "WebStorage", "Network", "shared_proto_db",
    "VideoDecodeStats", "Partitions", "node_modules", "vm_bundles", "Claude Extensions",
    "Extensions", "logs", "sentry",
}
HOME = os.path.expanduser("~")


def roots():
    out = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        out += [os.path.join(os.path.expanduser(p.strip()), "projects") for p in env.split(",") if p.strip()]
    out += [os.path.join(HOME, ".claude/projects"), os.path.join(HOME, ".config/claude/projects"),
            os.path.join(HOME, "Library/Application Support/Claude")]
    seen, res = set(), []
    for r in out:
        r = os.path.normpath(r)
        if r not in seen:
            seen.add(r)
            res.append(r)
    return res


def pretty(model):
    m = (model or "unknown").lower().split("[")[0]
    if "claude" in m:
        m = m[m.index("claude"):]
    parts = [p for p in m.replace(".", "-").replace("@", "-").split("-")[1:]
             if not (len(p) >= 8 and p.isdigit())]
    fam = next((p for p in parts if p in ("opus", "sonnet", "haiku", "fable", "mythos")), None)
    if not fam:
        return model
    nums = [p for p in parts if p.isdigit()][:2]
    return fam.capitalize() + (" " + ".".join(nums) if nums else "")


class Group:
    def __init__(self):
        self.files = 0
        self.lines = 0
        self.calls = {}                      # key -> (model, tokens, out, day, session)
        self.raw = collections.Counter()     # model -> tokens summed per line
        self.raw_out = collections.Counter()
        self.entry = collections.Counter()
        self.unkeyed = 0


def tok(u, k):
    try:
        return int(u.get(k) or 0)
    except (TypeError, ValueError):
        return 0


WHEN = {}   # API call key -> (UTC datetime, tokens), across all folders


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def recent_activity():
    """Same rules as the app: Day = since local midnight; 5-hour window starts at the first
    response after the previous window ended, to the minute."""
    out = ["## Recent activity (worked out from the raw logs, independent of the app)"]
    calls = sorted(WHEN.values())
    if not calls:
        return out + ["   no timestamped responses found"]
    now = datetime.now(timezone.utc)
    local = lambda d: d.astimezone().strftime("%Y-%m-%d %H:%M")
    midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    today = sum(t for d, t in calls if d >= midnight)
    out.append(f"   now (local): {local(now)} | last logged response: {local(calls[-1][0])}")
    out.append(f"   tokens since local midnight: {fmt(today)}")
    start = end = None
    tokens = 0
    for d, t in calls:
        if end is None or d >= end:
            start = d.replace(second=0, microsecond=0)
            end = start + timedelta(hours=5)
            tokens = 0
        tokens += t
    state = "ACTIVE" if start <= now < end else "ended"
    out.append(f"   latest 5-hour window: {local(start)} to {local(end)} ({state}), {fmt(tokens)} tokens")
    out.append("   last 5 responses: " + ", ".join(f"{local(d)} ({fmt(t)})" for d, t in calls[-5:]))
    return out


def scan():
    groups = collections.OrderedDict()
    for root in roots():
        if not os.path.isdir(root):
            continue
        desktop = root.endswith("Application Support/Claude")
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for f in filenames:
                if not f.lower().endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, f)
                rel = os.path.relpath(path, root).split(os.sep)
                label = ("Desktop: " + rel[0]) if desktop and len(rel) > 1 else (
                    "Desktop: (top level)" if desktop else "CLI: " + root.replace(HOME, "~"))
                g = groups.setdefault(label, Group())
                g.files += 1
                try:
                    fh = open(path, "rb")
                except OSError:
                    continue
                with fh:
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
                        if msg.get("role", "assistant") != "assistant" or msg.get("model") == "<synthetic>":
                            continue
                        u = msg["usage"]
                        out = tok(u, "output_tokens")
                        total = tok(u, "input_tokens") + out + tok(u, "cache_read_input_tokens") + tok(u, "cache_creation_input_tokens")
                        if total == 0:
                            continue
                        model = pretty(msg.get("model"))
                        g.lines += 1
                        g.raw[model] += total
                        g.raw_out[model] += out
                        g.entry[str(obj.get("entrypoint"))] += 1
                        ts = str(obj.get("timestamp") or "")[:10]
                        mid, rid = msg.get("id"), obj.get("requestId") or obj.get("request_id")
                        if mid or rid:
                            key = f"msg:{mid}" if mid else f"req:{rid}"
                        else:
                            g.unkeyed += 1
                            key = f"{path}|{g.lines}"
                        prev = g.calls.get(key)
                        if prev is None or out > prev[2] or (out == prev[2] and total > prev[1]):
                            g.calls[key] = (model, total, out, ts, obj.get("sessionId") or path)
                            when = parse_ts(obj.get("timestamp"))
                            if when is not None:
                                WHEN[key] = (when, total)
    return groups


def fmt(n):
    for div, suf in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if n >= div:
            return f"{n / div:.2f}{suf}"
    return str(n)


def main():
    groups = scan()
    lines = [f"Credo diagnosis — {datetime.now():%Y-%m-%d %H:%M}", ""]
    grand_call = collections.Counter()
    grand_raw = collections.Counter()
    grand_out_call = collections.Counter()
    grand_out_raw = collections.Counter()
    all_calls = {}
    for label, g in groups.items():
        if not g.lines:
            lines.append(f"## {label}: {g.files} files, no usage lines")
            continue
        per_model = collections.Counter()
        per_model_out = collections.Counter()
        days, sessions = set(), set()
        for model, total, out, day, sess in g.calls.values():
            per_model[model] += total
            per_model_out[model] += out
            days.add(day)
            sessions.add(sess)
        all_calls.update({(label, k): v for k, v in g.calls.items()})
        call_total, raw_total = sum(per_model.values()), sum(g.raw.values())
        lines.append(f"## {label}")
        lines.append(f"   files {g.files} | usage lines {g.lines:,} | unique API calls {len(g.calls):,} "
                     f"| lines per call {g.lines / max(len(g.calls), 1):.2f} | calls without ids {g.unkeyed}")
        lines.append(f"   sessions {len(sessions)} | active days {len([d for d in days if d])} "
                     f"| {min(d for d in days if d) if any(days) else '?'} → {max(days) if days else '?'}")
        lines.append(f"   entrypoints: {dict(g.entry.most_common(5))}")
        lines.append(f"   TOTAL  per call {fmt(call_total):>9}  | per line {fmt(raw_total):>9}  | x{raw_total / max(call_total, 1):.2f}")
        for model, _ in per_model.most_common():
            lines.append(f"     {model:12} per call {fmt(per_model[model]):>9} (out {fmt(per_model_out[model])})"
                         f"  | per line {fmt(g.raw[model]):>9} (out {fmt(g.raw_out[model])})")
            grand_call[model] += per_model[model]
            grand_raw[model] += g.raw[model]
            grand_out_call[model] += per_model_out[model]
            grand_out_raw[model] += g.raw_out[model]
        lines.append("")

    # Calls present in more than one folder (would be double counted if folders are summed).
    by_key = collections.defaultdict(set)
    for (label, key), _ in all_calls.items():
        by_key[key].add(label)
    shared = sum(1 for v in by_key.values() if len(v) > 1)
    lines.append(f"## Cross-folder duplicates: {shared:,} API calls appear in more than one folder")
    lines.append("")
    lines.append("## ALL FOLDERS")
    lines.append(f"   per call {fmt(sum(grand_call.values()))} | per line {fmt(sum(grand_raw.values()))}")
    for model, _ in grand_call.most_common():
        lines.append(f"     {model:12} per call {fmt(grand_call[model]):>9} (out {fmt(grand_out_call[model])})"
                     f"  | per line {fmt(grand_raw[model]):>9} (out {fmt(grand_out_raw[model])})")

    lines.append("")
    lines += recent_activity()
    text = "\n".join(lines) + "\n"
    out_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "diagnose.txt")
    with open(out_path, "w") as fh:
        fh.write(text)
    print(text)
    print(f"Saved to {out_path}")


if __name__ == "__main__":
    sys.exit(main())
