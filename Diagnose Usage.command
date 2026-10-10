#!/bin/bash
# Double-click to write diagnose.txt for Credo (token counts only — no prompts or code).
cd "$(dirname "$0")"
/usr/bin/python3 scripts/diagnose_usage.py >/dev/null

APP="/Applications/Credo.app/Contents/MacOS/Credo"
{
    echo
    echo "## Installed Credo"
    /usr/bin/defaults read /Applications/Credo.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "not installed"
    echo "Now: $(date '+%Y-%m-%d %H:%M:%S %Z') ($(date -u '+%H:%M UTC'))"
    echo
    echo "## Menu bar settings"
    /usr/bin/defaults read app.credo.macos 2>/dev/null | /usr/bin/grep -E 'menuBar|budget|syncClaude|refreshInterval' || echo "(defaults)"
    if [[ -x "$APP" ]]; then
        echo
        echo "## Credo --report"
        "$APP" --report 2>&1 | /usr/bin/sed "s|$HOME|~|g"
        echo
        echo "## Credo --limits (Sync with Claude account check; macOS may ask to allow Keychain access)"
        "$APP" --limits 2>&1
    fi
} >> diagnose.txt

echo "Saved diagnose.txt"
echo
read -r -p "Done. Attach diagnose.txt if you open an issue on GitHub. Press Return to close…"
