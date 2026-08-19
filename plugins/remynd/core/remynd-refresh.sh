#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cache refresher (PRD §5.1).
#
# Writes the current digest to state/context.md and a small state/sync.json,
# but only when the database has actually advanced. Consumers that cannot run
# a hook — the Codex adapter, the ReMynd Integrations tab, `remynd status` —
# read those two files instead of querying.
#
# Safe to run on a timer or fire-and-forget in the background.
# ---------------------------------------------------------------------------
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/remynd-digest.sh" 2>/dev/null || exit 0

force=0
[ "${1:-}" = "--force" ] && force=1

profile="$(remynd_find_profile)" || exit 0
db="$(remynd_db_path "$profile")"
[ -f "$db" ] || exit 0

state="$(remynd_state_dir)"
mtime="$(remynd_db_mtime "$db")"

if [ "$force" -eq 0 ] && [ -f "$state/sync.json" ]; then
  prev="$(/usr/bin/sed -n 's/.*"db_mtime"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$state/sync.json" | head -1)"
  [ -n "$prev" ] && [ "$mtime" -le "$prev" ] && exit 0
fi

# Single-writer lock so concurrent sessions don't fight over the cache.
lock="$state/.refresh.lock"
if ! mkdir "$lock" 2>/dev/null; then
  # Stale lock older than 2 minutes gets broken.
  if [ -d "$lock" ]; then
    age=$(( $(/bin/date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) ))
    [ "$age" -gt 120 ] && rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

budget="$(remynd_config_get session_budget_tokens 8000)"
minutes="$(remynd_config_get session_ocr_minutes 30)"
redact="$(remynd_config_get redact_credentials 1)"

tmp="$state/.context.md.tmp"
if remynd_digest_full "$db" "$minutes" "$budget" "$redact" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  mv "$tmp" "$state/context.md"
else
  rm -f "$tmp"
  exit 0
fi

last_event="$(remynd_sql "$db" "SELECT COALESCE(datetime(MAX(firstSeenAt),'localtime'),'') FROM (SELECT firstSeenAt FROM OCRTextSegment ORDER BY id DESC LIMIT 1);")"
windows_today="$(remynd_sql "$db" "
  SELECT COUNT(*) FROM (SELECT id, startedAt FROM FocusedWindow ORDER BY id DESC LIMIT $REMYND_WIN_TAIL)
  WHERE startedAt >= '$(/bin/date -u -j -f '%Y-%m-%d %H:%M:%S' "$(/bin/date '+%Y-%m-%d') 00:00:00" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)';")"

# Hand-rolled JSON — no jq (PRD §13.3). All values here are numbers or
# controlled strings, so simple quoting is sufficient.
cat > "$state/sync.json" <<EOF
{
  "profile": "$(printf '%s' "$profile" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')",
  "db_mtime": $mtime,
  "generated_at": $(/bin/date +%s),
  "generated_at_iso": "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')",
  "last_event_at": "$(printf '%s' "$last_event" | /usr/bin/sed 's/"/\\"/g')",
  "windows_today": ${windows_today:-0},
  "context_tokens": $(remynd_tokens_of_file "$state/context.md")
}
EOF

exit 0
