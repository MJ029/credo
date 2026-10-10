# Changelog

## 2.2.2

- The 5-hour window starts at the minute of the first response after the previous window ended
  (a window started at 8:40 PM resets at 1:40 AM), matching Claude's minute-precise reset times.
  This replaces 2.2.1's whole-UTC-hour start.

## 2.2.1

- Fix: the 5-hour window starts at the whole UTC hour again, as in TokenMeter, so its reset time
  matches Claude's. (2.1's "start at the first message" change made it up to 59 minutes late.)
- Fix: Day rolled over late in half-hour time zones (until 00:30 in India), and an ended 5-hour
  window could linger until the next hour.
- Diagnose Usage.command also reports the installed version, menu bar settings and the Claude
  sync check.

## 2.2.0

- **Sync with Claude account** (Settings › General, off by default). Credo asks Claude for your
  plan's limits every 3 minutes, the same way Claude Code's `/usage` does, using Claude Code's
  sign-in from the Keychain. The 5-hour window, its percentage and reset time then match Claude's
  own session bar, the popover shows your weekly limit, and the 5h widget shows % used. Falls back
  to the logs if the sign-in has expired or the service changes. `Credo --limits` tests it.
- Menu bar can show **usage + % + time left** for the 5-hour window, e.g.
  `42.3M · 72% · 1h 24m left`. Time left updates every 30 seconds.
- Fix: changes in Settings now show in the menu bar immediately, with no restart.
- Clean install: the installer's Installation Type step offers **Remove previous versions first**
  (on), **Also erase saved history and settings** (off) and **Install Credo** (untick to uninstall
  only).
- On first launch Credo offers to move leftover TokenMeter or duplicate Credo apps to the Trash.

## 2.1.0

- Popover adds a provider row: All, Anthropic, OpenAI and Google. Credo reads Claude
  (Anthropic) logs today; choosing OpenAI or Google explains what's planned (Codex CLI, ChatGPT
  desktop, Gemini CLI).
- New **5 hr** time range in the popover and widgets: totals, models, tools and projects for the
  current 5-hour window, charted by hour.
- Settings › Data sources is grouped by provider. Codex CLI (OpenAI) and Gemini CLI (Google)
  folders are detected and shown, ready for counting in a later version.
- Fix: log copies without a timestamp can no longer pull old tokens into the current 5-hour
  window.

## 2.0.0

Renamed from TokenMeter to **Credo**.

- New tachometer logo and app icon.
- Menu bar item is text only. Choose any time window (5 hr, Day, Week, All) and show usage,
  usage + percentage, or percentage, against time elapsed or a token budget you set.
- Glass popover with an All tools / CLI / Desktop picker and a percentage badge on the 5-hour window.
- Six desktop widgets, each a draggable glass panel: Usage summary, 5h window, Tokens by tool,
  Cache savings, Tokens by model and Token economy. Light, dark or system glass; on the desktop
  or floating.
- Settings split into General and Widgets tabs.
- The 5-hour percentage is labelled "elapsed". An optional 5-hour token budget shows usage against it,
  and the app explains how this differs from Claude's own session bar.
- Cache savings: what prompt caching saved compared with paying full input price.
- Widgets accept the first click, so they can be dragged and right-clicked reliably.
- `build.sh` also produces a `.dmg`.
- Upgrading from TokenMeter replaces the old app and keeps its history and pricing.

## 1.1.0

- Counts each API response once by message ID, which also fixes double counting of Claude Desktop
  agent sessions.
- Splits tools by where sessions ran: Terminal, VS Code, Desktop Code tab, Desktop agent sessions.
- Adds a "Claude Code (all)" view, plus diagnostic and verification scripts.
- Fixes overlapping date labels on the daily chart.

## 1.0.0

- First release: menu bar app, popover with periods, token mix, 5-hour window, chart and
  breakdowns, a desktop widget, and a `.pkg` installer built with the Command Line Tools.
