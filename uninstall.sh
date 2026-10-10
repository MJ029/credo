#!/bin/bash
# Removes Credo. Pass --all to also delete its saved history and settings.
set -u
/usr/bin/pkill -x Credo 2>/dev/null || true
sudo rm -rf "/Applications/Credo.app"
sudo pkgutil --forget app.credo.macos >/dev/null 2>&1 || true
if [[ "${1:-}" == "--all" ]]; then
    rm -rf "$HOME/Library/Application Support/Credo"
    defaults delete app.credo.macos >/dev/null 2>&1 || true
    echo "Removed Credo, its history and settings."
else
    echo "Removed Credo. History kept in ~/Library/Application Support/Credo (use --all to delete)."
fi
