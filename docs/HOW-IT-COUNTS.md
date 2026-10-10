# How Credo counts

Credo reads the JSONL session logs that Claude Code and Claude Desktop write locally. This page
explains which lines count, how duplicates are removed, how tools are labelled and how costs are
estimated, so you can check any number Credo shows.

## Which lines count

A log line counts as one API response when all of these are true:

- It has a `message` object with a `usage` block and the message role is `assistant`.
- Its model is a real model, not `<synthetic>` (Claude Code's placeholder for messages it wrote itself).
- Its `type` isn't `result` or `summary`. Those are session totals and would double count.
- At least one token count is above zero.

From the `usage` block Credo reads:

| Field | Shown as |
|---|---|
| `input_tokens` | Input |
| `output_tokens` | Output |
| `cache_creation_input_tokens` (split into 5-minute and 1-hour writes when the log has `cache_creation`) | Cache write |
| `cache_read_input_tokens` | Cache read |

## De-duplication

The same response can appear in the logs several times:

1. **One line per content block.** Claude Code writes a separate line for each part of a response
   (thinking, text, each tool call), and every line repeats the full usage for that response.
2. **Streaming updates.** Early lines can carry a partial output count.
3. **Second copies.** Claude Desktop agent sessions keep two logs of each response, and resumed
   sessions copy earlier history.

Credo keys every response by its **message ID** (falling back to the request ID, then to a hash
of the line) and keeps the most complete copy, the one with the highest output count. That gives
one record per API response, which is how usage is billed.

### Why other counters show more

Claude Code's built-in Stats panel adds up every usage line. On real-world logs this comes out at
roughly 1.8 to 2.5 times the per-response total, depending on how many content blocks the
responses have. Credo's totals match the per-response figure.

Run the diagnostic script to see both numbers for your own logs:

```bash
python3 scripts/diagnose_usage.py      # or double-click "Diagnose Usage.command"
```

For each log folder it prints the total counted once per response and once per line, the number
of lines per response, and the model mix. It writes counts only, never prompts, code or project
names, to `diagnose.txt`.

`scripts/verify_usage.py` is an independent re-implementation of Credo's rules. Its Today, 7D and
30D totals should match the app.

## Tool labels

| Label | How it's recognised |
|---|---|
| Claude Code · Terminal | `entrypoint` is `cli` |
| Claude Code · VS Code | `entrypoint` contains `vscode`, `cursor` or `jetbrains` |
| Claude Desktop · Code tab | `entrypoint` contains `desktop` (Claude Code started from Claude Desktop) |
| Claude Desktop · Agent sessions | `entrypoint` is `local-agent`, or the file is under `local-agent-mode-sessions` |
| Agent SDK / other | `entrypoint` starts with `sdk` |

In the popover, **CLI** groups Terminal, VS Code and SDK; **Desktop** groups the Code tab and agent
sessions.

## Time windows

- **5 hr:** the current 5-hour window (described below); empty when no window is active.
- **Today / Day:** since local midnight.
- **7D / Week:** today and the previous 6 days.
- **30D:** today and the previous 29 days.
- **All:** everything in the logs plus Credo's own history.
- **5-hour window:** starts with the first response after the previous window ended (to the
  minute) and lasts exactly five hours, like Claude's (a window started at 8:40 PM resets at
  1:40 AM). From logs alone this is only right when that first message was in Claude Code or a
  Desktop agent session on this Mac; turn on Sync with Claude account for the exact window. Responses whose log
  line has no timestamp are counted in totals but never start or extend a window. It's still an
  estimate from local logs. With **Sync with Claude account** on, the window instead runs from
  Claude's reset time minus five hours to that reset time, exactly as Claude reports it.

## Why Claude's own 5-hour % differs

Claude's **Settings → Usage → Current session** bar and Credo's 5-hour percentage measure
different things:

| | Claude's session bar | Credo's 5-hour window |
|---|---|---|
| Measures | Share of your plan's usage limit consumed | Share of the 5-hour window's time elapsed (default), or tokens against a budget you set |
| Counts | Everything on your plan: claude.ai, desktop and mobile chats, and Claude Code | Responses in local Claude Code and Claude Desktop agent logs |
| Source | Anthropic's servers | Files on your Mac |

Regular chats don't write token counts to disk, and the plan limit isn't stored locally, so
from logs alone Credo can't reproduce Claude's figure. There can also be a gap in timing: if your
window began with a chat on the web or phone, Claude's window starts earlier than the first
response Credo can see, so Credo's reset looks later.

### Sync with Claude account

Turn on **Settings → General → Claude account → Sync with Claude account** to remove the gap.
Every 3 minutes Credo asks Claude's servers for your limits, the same way Claude Code's `/usage`
command does, using Claude Code's sign-in from your Keychain. Then:

- the 5-hour window starts at Claude's reset time minus five hours and ends at the reset;
- the 5-hour percentage is Claude's own "Current session" percentage, and Week shows Claude's
  weekly limit percentage;
- the token counts still come from local logs, so chats on the web or phone raise the percentage
  but not the token count.

Requirements and limits:

- Claude Code must be signed in with your Pro or Max plan. If its sign-in has expired, Credo
  says so; open Claude Code once (run `claude`) to refresh it. Credo never renews it itself,
  because that could sign Claude Code out.
- The service is unofficial and undocumented. If it changes or is blocked, Credo shows the error
  in Settings and goes back to working the window out from your logs.
- To check it from Terminal: `/Applications/Credo.app/Contents/MacOS/Credo --limits`.

Without sync, you can approximate Claude's figure instead: choose **5 hr**, set **100% equals** to
**Token budget**, and enter the tokens you typically get per session.

## Cost and cache savings

Prices are Anthropic's API list prices per million tokens, stored in
`~/Library/Application Support/Credo/pricing.json`. Model IDs are matched by prefix, so
`claude-opus-4-5` covers `claude-opus-4-5-20251101`. An unknown future model falls back to the
newest price in its family (Opus, Sonnet, Haiku and so on). Long-context price tiers are applied
per request where a model has them.

```
cost          = input × input price
              + cache write (5 min) × 5-minute write price
              + cache write (1 h) × 1-hour write price
              + cache read × cache-read price
              + output × output price

cache savings = cache read × (input price − cache-read price)
```

On a Pro or Max subscription you aren't billed per token, so treat cost as the value of what you used.

## History

Claude Code deletes old transcripts after 30 days by default. Each time Credo reads a new
response it appends one line to `~/Library/Application Support/Credo/history-v2.tsv`: message key,
timestamp, tool, model, project folder name, session ID and the five token counts. On launch Credo
loads that history first, so All-time totals keep transcripts that no longer exist on disk.
**Settings → General → Clear history** rebuilds it from the logs that remain.
