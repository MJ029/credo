<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Credo app icon: a tachometer gauge">
</p>

<h1 align="center">Credo</h1>

<p align="center">
  Claude token usage in your Mac menu bar, plus glass desktop widgets.<br>
  Private by design: everything is read from logs already on your Mac.
</p>

<p align="center">
  <a href="../../releases/latest"><b>Download the latest release</b></a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="docs/HOW-IT-COUNTS.md">How Credo counts</a>
</p>

![Credo's menu bar item, popover and desktop widgets on a macOS desktop](docs/images/hero.png)

> Screenshots use illustrative sample data.

## What it does

Credo reads the session logs that Claude Code and Claude Desktop already write to your Mac and
turns them into a live view of your token usage: how much, on which models, in which tools and
projects, and what it would cost at API prices. It needs no API key, and by default makes no
network requests. Turn on **Sync with Claude account** to match Claude's own 5-hour and weekly limits.

- **Menu bar item.** Text only, no icon. Choose any time window (5 hr, Day, Week, All) and show
  usage, usage + percentage, percentage, or usage + percentage + time left.
- **Popover.** 5 hr / Today / 7D / 30D / All, by provider and by tool (All tools, CLI, Desktop), with totals, the
  input/output/cache split, the current 5-hour window, a daily chart, and breakdowns by model,
  tool and project.
- **Desktop widgets.** Six glass panels you can place anywhere: usage summary, 5-hour window,
  tokens by tool, cache savings, tokens by model and token economy.
- **Sync with Claude account (optional).** Shows Claude's real session %, reset time and weekly
  limit, and lines Credo's 5-hour window up with Claude's.
- **Clean install.** The installer can remove earlier versions first, erase saved data, or
  uninstall only. Credo also offers to move old copies to the Trash when it starts.
- **Accurate counting.** One record per API response, de-duplicated by message ID, with its own
  history so totals survive Claude Code's automatic transcript cleanup.

## Install

### Download (recommended)

1. Download **Credo-x.y.z.pkg** (or the **.dmg**) from the [latest release](../../releases/latest).
2. **Right-click the file → Open**, then click **Open** again.
   Credo isn't signed with an Apple Developer ID yet, so macOS asks once before opening it.
   If you double-clicked and macOS blocked it, go to **System Settings → Privacy & Security** and
   click **Open Anyway**.
3. Follow the installer. On the **Installation Type** step, choose:
   - **Remove previous versions first** (on by default): removes older Credo or TokenMeter apps.
   - **Also erase saved history and settings** (off by default): start completely fresh.
   - **Install Credo** (on by default): untick it, with the first option ticked, to uninstall only.

   Credo installs to `/Applications` and starts in the menu bar. If it finds old copies somewhere
   else when it starts, it asks before moving them to the Trash.

Requires macOS 13 Ventura or later on Apple silicon.

### Build from source

You need Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
git clone <this repository> credo
cd credo
./build.sh
```

`build.sh` compiles the app, signs it ad hoc for your Mac and writes `Credo-<version>.pkg` and
`Credo-<version>.dmg` next to the script, then opens the installer. In Finder you can
double-click **Install Credo.command** instead; it does the same and saves `build-log.txt`.

Quick check without installing:

```bash
build/root/Applications/Credo.app/Contents/MacOS/Credo --report
```

## Tour

### Popover

<img src="docs/images/popover.png" width="440" alt="Credo popover with totals, token mix, 5-hour window, daily chart and breakdowns">

Click the menu bar item to open it. At the top, pick a period (5 hr, Today, 7D, 30D, All), a
provider (All, Anthropic, OpenAI, Google) and a tool group (All tools, CLI, Desktop). Credo reads
Claude logs today; OpenAI and Google tools are planned.

| Section | What it shows |
|---|---|
| Totals | Tokens, API-price cost estimate, requests, sessions, cache-hit rate, active days |
| Token mix | Input, output, cache write and cache read, with their shares |
| Current 5-hour window | Time elapsed, tokens, cost, burn rate, start time, time until reset, and tokens against your budget if you set one |
| Tokens per day | Stacked bars per hour (5 hr, Today), day (7D/30D) or week (long All-time ranges) |
| By model / By tool / Top projects | Tokens and cost for each, largest first |

### Menu bar

![Menu bar examples: 72%, 42.3M · 72%, 42.3M · 72% · 1h 24m left, daily, weekly and all-time usage](docs/images/menubar.png)

In **Settings → General → Menu bar shows**, pick a **time window** and what to **show**:

| | Usage | Usage + % | % | Usage + % + time |
|---|---|---|---|---|
| **5 hr** | `42.3M` | `42.3M · 72%` | `72%` | `42.3M · 72% · 1h 24m left` |
| **Day** | `96.4M` | `96.4M · 48%` | `48%` | (5 hr only) |
| **Week** | `512M` | `512M · 64%` | `64%` | (5 hr only) |
| **All** | `1.84B` | `1.84B · 37%` | `37%` | (5 hr only) |

For the 5-hour window, 100% means the window has fully elapsed, or you can set a token budget.
For Day, Week and All, 100% is a token budget you set (for example your weekly allowance).
**Usage + % + time** is offered for the 5-hour window only, and counts down to its reset.
With **Sync with Claude account** on, the 5 hr and Week percentages are Claude's own
(5-hour session and weekly limit), and the time left is Claude's reset time.

### Desktop widgets

![The six Credo desktop widgets in light glass](docs/images/widgets.png)

Turn widgets on in **Settings → Widgets**. Each one is its own floating glass panel:

- **Drag** a widget anywhere to move it. Credo remembers where you put it.
- **Right-click** (or Control-click) a widget to refresh it, change its period, open settings or
  hide it.
- Choose whether widgets sit **on the desktop behind windows** or **float above everything**, and
  pick **light glass, dark glass or match system**.

| Widget | Size | Shows |
|---|---|---|
| Usage summary | Medium | Tokens, cost, token mix, last 7 days, top tools, 5-hour window |
| 5h window | Small | Battery-style ring with percentage used and time until reset |
| Tokens by tool | Medium | Icon rings with each tool's share |
| Cache savings | Small | Cache-hit ring and the dollars prompt caching saved |
| Tokens by model | Medium | Rings for the top models and the rest |
| Token economy | Medium | Cost per request, per session, per active day; tokens per request |

> Credo's widgets are not macOS system widgets, so they don't appear in **Edit Widgets**.
> System widgets have to be built with WidgetKit and full Xcode. Credo's panels keep the build
> simple and can update every few seconds.

### Settings

<p>
  <img src="docs/images/settings-general.png" width="400" alt="Settings, General tab">
  <img src="docs/images/settings-widgets.png" width="400" alt="Settings, Widgets tab">
</p>

- **General:** launch at login, refresh interval, Sync with Claude account, menu bar display
  (changes show in the menu bar immediately), data sources grouped by
  provider (Anthropic, OpenAI, Google; add your own log folders), pricing, and history.
- **Widgets:** placement, glass style, the period widgets cover, and an on/off switch for each widget.

## Where the numbers come from

| Tool | Logs read |
|---|---|
| Claude Code (terminal, VS Code, Desktop Code tab) | `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects`, `$CLAUDE_CONFIG_DIR/projects` |
| Claude Desktop agent sessions | `~/Library/Application Support/Claude/**/*.jsonl` (caches skipped) |
| Anything else | Folders you add in Settings → General → Data sources |
| OpenAI Codex CLI (planned) | `~/.codex/sessions`, detected and shown in Settings but not counted yet |
| Google Gemini CLI (planned) | `~/.gemini`, detected and shown in Settings but not counted yet |

Regular chats in Claude Desktop run on Anthropic's servers and don't write per-message token
counts to disk, so Credo can't count them.

**Why does Claude Code's built-in Stats panel show about twice as much?** Claude Code writes one
log line per part of a response (thinking, text, each tool call), and every line repeats the
whole response's token count. Adding up lines counts most responses two to four times. Credo
counts each response once by its message ID, which matches how usage is billed. See
[How Credo counts](docs/HOW-IT-COUNTS.md) for details and a script that shows both totals.

**Why doesn't Credo's 5-hour % match Claude's "Current session" bar?** Claude's bar is the share
of your plan's limit used across everything (web, desktop and mobile chats, and Claude Code), and
it's tracked on Anthropic's servers. Without sync, Credo shows how much of the window's time has
elapsed, from local logs, or tokens against a budget you set, and its window can start later than
Claude's if you began with a chat. Turn on **Sync with Claude account** to show Claude's own
figures. See [the full comparison](docs/HOW-IT-COUNTS.md#why-claudes-own-5-hour--differs).

**Costs** use Anthropic's API list prices and are an estimate of value. Pro and Max plans aren't
billed per token. Edit `~/Library/Application Support/Credo/pricing.json` and click
**Reload prices** to change them.

## What is and isn't counted

Credo counts **tokens reported by the Anthropic API in local session logs**, once per API
response. Anything that never reaches a local log, or isn't a token count, is not counted.

### Counted

Every assistant response in a log that carries a `usage` block contributes four numbers:

| Token type | Log field | Shown as |
|---|---|---|
| Fresh input | `input_tokens` | Input |
| Generated output | `output_tokens` | Output |
| Prompt-cache writes | `cache_creation_input_tokens` (5-minute and 1-hour writes are kept apart when the log splits them) | Cache write |
| Prompt-cache reads | `cache_read_input_tokens` | Cache read |

Total tokens = input + output + cache write + cache read.

**Example: one response, counted once.** Claude Code logs this response as three lines (a
thinking block, a text block and a tool call). Each line repeats the same `usage`, so a plain
sum would count it three times. Credo keys on `message.id` and keeps one copy:

```json
{"type":"assistant","entrypoint":"cli","cwd":"/Users/me/shop-api",
 "timestamp":"2026-10-10T14:03:21.512Z",
 "message":{"id":"msg_01ABC","role":"assistant","model":"claude-sonnet-4-5-20250929",
  "usage":{"input_tokens":12,"output_tokens":480,
           "cache_creation_input_tokens":2000,"cache_read_input_tokens":18000}}}
```

| What Credo records | Value |
|---|---|
| Tokens | 12 in + 480 out + 2,000 cache write + 18,000 cache read = **20,492** |
| Tool | Claude Code · Terminal (`entrypoint` is `cli`) |
| Project | `shop-api` (last folder of `cwd`) |
| Model | Sonnet 4.5 |
| Cost at API prices | 12×$3 + 2,000×$3.75 + 18,000×$0.30 + 480×$15, per million = **$0.0201** |
| Cache savings | 18,000 × ($3 − $0.30) per million = **$0.0486** |

Also counted:

- **All Claude Code surfaces**: terminal, VS Code / Cursor / JetBrains, the Claude Desktop Code
  tab and the Agent SDK, each labelled separately.
- **Claude Desktop agent sessions** (`local-agent-mode-sessions`).
- **Any `.jsonl` log folder you add** in Settings → General → Data sources, if it uses the same
  `message.usage` format.
- **Older usage whose transcripts Claude Code has since deleted**, once Credo has read it. Credo
  keeps its own history file (see [Privacy](#privacy)).
- **Responses from models Credo has no price for.** Their tokens are counted. Only the cost
  shows as $0 until you add a price in `pricing.json`.
- **Responses with no timestamp.** They count in totals using the file's modified time, but never
  start or extend the 5-hour window and aren't saved to the history file.

### Not counted

| Not counted | Example | Why |
|---|---|---|
| Regular chats in the Claude apps | A long conversation on claude.ai, the Claude mobile app or the Chat tab of Claude Desktop | These run on Anthropic's servers and write no per-message token counts to your Mac. |
| Usage on other machines | Claude Code run on a work laptop or in a cloud session | Credo only reads logs on the Mac it runs on. |
| Usage before the logs were read | Transcripts Claude Code deleted before you installed Credo | There is nothing left on disk to read. |
| Duplicate copies of a response | The same `msg_01ABC` logged on 3 lines, or copied into a resumed session | Counted once, by message ID. |
| Session totals | Lines with `"type":"result"` or `"type":"summary"` | They repeat per-response usage and would double count. |
| Placeholder messages | Lines with `"model":"<synthetic>"`, such as messages Claude Code wrote itself | No API call was made. |
| Your own messages | Lines with `"role":"user"` | Only assistant responses carry billed usage. |
| Empty usage | A failed or interrupted request reporting 0 input, output and cache tokens | Nothing to count. |
| Other `usage` fields | Anything besides the four above, for example `server_tool_use` / web-search request counts | Credo reads only the four token fields, so per-use charges are not in its cost estimate. |
| OpenAI and Google tools | Codex CLI (`~/.codex/sessions`), Gemini CLI (`~/.gemini`) | Detected and listed in Settings, but not parsed yet. |
| Cache and app-data folders | `Cache`, `IndexedDB`, `Local Storage`, `logs` and similar folders inside Claude Desktop's data folder | They never hold transcripts, so Credo skips them. |
| Prompt and response text | Your code, questions and Claude's answers | Credo never reads or stores message content, only the numbers and labels above. |
| Plan limits | "I've used 72% of my Max session" | A server-side figure, not a token count. Turn on **Sync with Claude account** to show Claude's own percentage. Credo's token totals still come from local logs. |

**Cost is an estimate.** It uses Anthropic's API list prices on the token counts above. On a Pro
or Max plan you aren't billed per token, so read it as the value of what you used.

## Privacy

- Credo reads files on your Mac and has no analytics. By default it makes no network requests.
- **Sync with Claude account** is off until you turn it on. Then, every 3 minutes, Credo reads
  Claude Code's sign-in from your Keychain (with macOS's own `security` tool) and sends one request
  to `api.anthropic.com` for your plan's limits, the same request Claude Code's `/usage` makes.
  The sign-in is never stored by Credo or sent anywhere else, and Credo never renews it. This
  service is unofficial and may change; if it stops working, Credo falls back to its logs.
- It stores a compact history (timestamps, model, tool, project folder name and token counts,
  never prompt or response text) in `~/Library/Application Support/Credo/history-v2.tsv`.
- Delete that folder, or run `./uninstall.sh --all`, to remove everything.

## Uninstall

Run the Credo installer, untick **Install Credo** on the Installation Type step, and keep
**Remove previous versions first** ticked (tick **Also erase saved history and settings** to remove
everything). Or from a copy of this repository:

```bash
./uninstall.sh          # removes the app, keeps history
./uninstall.sh --all    # also removes history and settings
```

Or quit Credo from its popover and drag `/Applications/Credo.app` to the Trash.

## Documentation

- [How Credo counts](docs/HOW-IT-COUNTS.md): de-duplication rules, tool labels, cost and cache savings
- [Architecture](docs/ARCHITECTURE.md): how the code is organised and how data flows
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE). Credo is an independent project and is not affiliated with Anthropic.
