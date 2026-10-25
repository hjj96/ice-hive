#!/bin/bash
# upright.sh <screenshot.png> <app log>
# The app is landscape-only; `simctl io screenshot` writes the simulator's portrait framebuffer. Turn the PNG upright
# by the side the app logged in its «scene presented … iface=landscapeRight|landscapeLeft» line (landscape right — the
# Info.plist's first orientation, Dynamic Island on the left — when the log has no such line). A PNG that is already
# wider than tall is left alone.
png=$1 log=$2 rot=270
[ -f "$png" ] || exit 0
if grep -q 'iface=landscapeLeft' "$log" 2>/dev/null; then rot=90; fi
w=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/{print $2}')
h=$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/{print $2}')
if [ -n "$w" ] && [ -n "$h" ] && [ "$w" -lt "$h" ]; then sips -r "$rot" "$png" > /dev/null 2>&1 || true; fi
exit 0
