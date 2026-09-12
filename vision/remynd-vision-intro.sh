#!/bin/bash
# SessionStart — tell the agent it can see the screen, but only if it truly can.
#
# The prompt hook covers the case where the user complains about something
# visual. This covers the other half: the agent checking its own work without
# being asked. Rendering a video, running an app, opening a page — all of it
# can now be verified by looking, in the same turn, instead of asking the user
# what appeared.
#
# Stays silent when ReMynd is not actually recording, so the agent is never
# told it has eyes it does not have.

set -uo pipefail

ROOT="$HOME/.remynd-sync"
VISION="$ROOT/bin/remynd-vision"
CONFIG="$ROOT/config"

[ -x "$VISION" ] || exit 0
[ "${REMYND_VISION:-1}" = "0" ] && exit 0

if [ -f "$CONFIG" ] && grep -qE '^[[:space:]]*vision_enabled=(0|false|no)' "$CONFIG" 2>/dev/null; then
  exit 0
fi

profile="$(grep -E '^[[:space:]]*profile=' "$CONFIG" 2>/dev/null \
           | sed -E 's/^[[:space:]]*profile=//' | grep -v '^[[:space:]]*$' | tail -1)"
if [ -z "${profile:-}" ]; then
  profile="$(ls -1dt "$HOME/Library/Application Support/Move37"/ReMynd* 2>/dev/null | head -1)"
fi
[ -n "${profile:-}" ] && [ -d "$profile/Recordings" ] || exit 0

# A recording that stopped hours ago cannot answer "what just happened", so
# claim the capability only while frames are genuinely landing.
newest="$(ls -1t "$profile/Recordings" 2>/dev/null | grep -E '^[0-9]{4}\.' | head -1)"
[ -n "${newest:-}" ] || exit 0
log="$profile/Recordings/$newest/frames.log"
[ -f "$log" ] || exit 0

age=$(( $(date +%s) - $(stat -f %m "$log" 2>/dev/null || echo 0) ))
[ "$age" -lt 900 ] || exit 0

cat <<'EOF'
# Screen vision

ReMynd is recording this screen, so you can look at what was actually on it
rather than asking. `~/.remynd-sync/bin/remynd-vision --since 3m` extracts the
real frames as PNGs and prints their paths; Read those paths to see them.
Useful flags: `--app <name>` (only while that app was frontmost), `--max N`,
`--from "14:05" --to "14:09"`.

Use it to check your own work: after rendering a video, running an app, or
opening a page, look at the frames of it running instead of assuming it worked
or asking the user what appeared. It reads the existing recording — it does not
take screenshots and does not touch the screen.
EOF
