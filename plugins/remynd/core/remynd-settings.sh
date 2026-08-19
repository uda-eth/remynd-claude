#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Merge (or remove) the ReMynd hooks in a Claude Code settings.json.
#
# Uses sqlite3's JSON1 functions rather than jq: jq is absent on macOS 14 and
# 15, which ReMynd supports, and requiring it would dead-end those users.
# sqlite3 is guaranteed present on every Mac.
#
#   remynd-settings.sh install <settings.json>
#   remynd-settings.sh remove  <settings.json>
#
# Prints the new JSON on stdout. Never writes the file — the caller does that,
# so it can validate first and keep a backup. Exits non-zero on any problem,
# leaving the caller's file untouched.
# ---------------------------------------------------------------------------
set -euo pipefail

SQLITE=/usr/bin/sqlite3
[ -x "$SQLITE" ] || SQLITE="$(command -v sqlite3)"

MARKER="remynd-sync-hook"
SESSION_CMD='bash "$HOME/.remynd-sync/core/remynd-session-hook.sh"  # remynd-sync-hook'
DELTA_CMD='bash "$HOME/.remynd-sync/core/remynd-delta-hook.sh"  # remynd-sync-hook'

mode="${1:-}"; file="${2:-}"
[ -n "$mode" ] && [ -n "$file" ] || { echo "usage: remynd-settings.sh install|remove <settings.json>" >&2; exit 2; }
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }

# Read the file into SQL as a single-quoted literal, so we never depend on
# readfile() path quoting.
raw="$(cat "$file")"
[ -n "$raw" ] || raw='{}'
esc="$(printf '%s' "$raw" | /usr/bin/sed "s/'/''/g")"

valid="$("$SQLITE" :memory: "SELECT json_valid('$esc');" 2>/dev/null || echo 0)"
[ "$valid" = "1" ] || { echo "settings.json is not valid JSON" >&2; exit 3; }

# Strip any hook group that mentions our marker, from both arrays. Also drops
# the legacy remynd-brain-hook from the previous, vault-based integration.
strip_sql="
WITH src(j) AS (SELECT json('$esc')),
     withhooks(j) AS (
       SELECT json_set(j, '\$.hooks', json(COALESCE(json_extract(j, '\$.hooks'), '{}'))) FROM src
     ),
     a(j) AS (
       SELECT json_set(j, '\$.hooks.SessionStart', json(COALESCE((
         SELECT json_group_array(json(value)) FROM json_each(
           json(COALESCE(json_extract(j, '\$.hooks.SessionStart'), '[]')))
         WHERE value NOT LIKE '%$MARKER%' AND value NOT LIKE '%remynd-brain-hook%'
       ), '[]'))) FROM withhooks
     ),
     b(j) AS (
       SELECT json_set(j, '\$.hooks.UserPromptSubmit', json(COALESCE((
         SELECT json_group_array(json(value)) FROM json_each(
           json(COALESCE(json_extract(j, '\$.hooks.UserPromptSubmit'), '[]')))
         WHERE value NOT LIKE '%$MARKER%'
       ), '[]'))) FROM a
     )
SELECT j FROM b;"

stripped="$("$SQLITE" :memory: "$strip_sql" 2>/dev/null)" || { echo "failed to read hooks" >&2; exit 4; }
[ -n "$stripped" ] || { echo "failed to read hooks" >&2; exit 4; }

if [ "$mode" = "remove" ]; then
  # Drop the arrays entirely if we left them empty, so we don't litter.
  esc2="$(printf '%s' "$stripped" | /usr/bin/sed "s/'/''/g")"
  "$SQLITE" :memory: "
    WITH s(j) AS (SELECT json('$esc2')),
         a(j) AS (SELECT CASE WHEN json_array_length(j,'\$.hooks.SessionStart')=0
                              THEN json_remove(j,'\$.hooks.SessionStart') ELSE j END FROM s),
         b(j) AS (SELECT CASE WHEN json_array_length(j,'\$.hooks.UserPromptSubmit')=0
                              THEN json_remove(j,'\$.hooks.UserPromptSubmit') ELSE j END FROM a),
         c(j) AS (SELECT CASE WHEN json_extract(j,'\$.hooks')='{}' OR json_extract(j,'\$.hooks') IS NULL
                              THEN json_remove(j,'\$.hooks') ELSE j END FROM b)
    SELECT j FROM c;"
  exit 0
fi

# Append our two hook groups.
esc2="$(printf '%s' "$stripped" | /usr/bin/sed "s/'/''/g")"
scmd="$(printf '%s' "$SESSION_CMD" | /usr/bin/sed "s/'/''/g")"
dcmd="$(printf '%s' "$DELTA_CMD"   | /usr/bin/sed "s/'/''/g")"

"$SQLITE" :memory: "
WITH s(j) AS (SELECT json('$esc2')),
     a(j) AS (
       SELECT json_set(j, '\$.hooks.SessionStart',
         json_insert(json(json_extract(j, '\$.hooks.SessionStart')), '\$[#]',
           json_object('hooks', json_array(json_object(
             'type', 'command',
             'command', '$scmd',
             'statusMessage', 'Loading your ReMynd context…',
             'timeout', 20))))) FROM s
     ),
     b(j) AS (
       SELECT json_set(j, '\$.hooks.UserPromptSubmit',
         json_insert(json(json_extract(j, '\$.hooks.UserPromptSubmit')), '\$[#]',
           json_object('hooks', json_array(json_object(
             'type', 'command',
             'command', '$dcmd',
             'timeout', 10))))) FROM a
     )
SELECT j FROM b;"
