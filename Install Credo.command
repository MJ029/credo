#!/bin/bash
# Double-click this file in Finder to build and install Credo.
# Everything it prints is also saved to build-log.txt next to it.
cd "$(dirname "$0")"
LOG="$PWD/build-log.txt"
exec > >(tee "$LOG") 2>&1

echo "Credo installer — $(date)"
echo "macOS $(sw_vers -productVersion) on $(uname -m)"
echo

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are needed to build the app."
    echo "A window will open: click Install, wait for it to finish,"
    echo "then double-click 'Install Credo.command' again."
    xcode-select --install
    echo
    echo "STATUS: NEEDS_COMMAND_LINE_TOOLS"
    read -r -p "Press Return to close this window…"
    exit 1
fi
echo "Swift: $(swift --version 2>&1 | head -1)"
echo

chmod +x build.sh uninstall.sh Installer/*/preinstall Installer/scripts/* 2>/dev/null
if bash build.sh --no-open; then
    PKG="$(ls -t Credo-*.pkg | head -1)"
    echo
    echo "STATUS: BUILD_OK $PKG"
    echo "Opening the installer. Pick your clean-install options, click Install and enter your Mac password."
    open "$PKG"
    sleep 2
else
    echo
    echo "STATUS: BUILD_FAILED"
    echo "The log is saved in build-log.txt. Attach it when you open an issue on GitHub."
    read -r -p "Press Return to close this window…"
fi
