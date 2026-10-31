#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Calls follow the selected profile, and arguments are checked.
#
# Synthetic: a temporary HOME holding a production and a development profile,
# built here with sqlite3. Reads no real ReMynd data and writes nothing outside
# that HOME. The MCP cases drive REMYND_MCP (default: this repo's mcp/remynd-mcp).
#
#   tests/calls-selected-profile.sh
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/plugins/remynd/core/remynd"
MCP="${REMYND_MCP:-$ROOT/mcp/remynd-mcp}"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: no [$3] in [${2:0:300}]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: found [$3] in [${2:0:300}]" ;; *) ok "$1" ;; esac; }

H="$(mktemp -d /tmp/remynd-calls.XXXXXX)"
trap 'rm -rf "$H"' EXIT
BASE="$H/Library/Application Support/Move37"
STATE="$H/state"
mkdir -p "$STATE" "$H/.remynd-sync/state"

ago() { /bin/date -u -v-"$1" '+%Y-%m-%d %H:%M:%S.000'; }

profile() { # <name> <sql for calls>
  local rec="$BASE/$1/Recordings"
  mkdir -p "$rec/Extras"
  /usr/bin/sqlite3 "$rec/app.db" "
    CREATE TABLE FocusedWindow (id INTEGER PRIMARY KEY, applicationName, windowTitle, startedAt, endedAt);
    CREATE TABLE OCRTextSegment (id INTEGER PRIMARY KEY, firstSeenAt, displayText, normalizedText);"
  /usr/bin/sqlite3 "$rec/Extras/extras.db" "
    CREATE TABLE Call (id INTEGER PRIMARY KEY, appName TEXT, startDate DATETIME, endDate DATETIME, title TEXT, participants);
    CREATE TABLE TranscriptionSegment (id INTEGER PRIMARY KEY AUTOINCREMENT, callID INTEGER, startTimestamp DATE, text TEXT, speaker TEXT);
    CREATE VIRTUAL TABLE TranscriptionSegment_FTS USING fts5(text, content='TranscriptionSegment', content_rowid='id');
    $2
    INSERT INTO TranscriptionSegment_FTS (rowid, text) SELECT id, text FROM TranscriptionSegment;"
}

# Two real calls in one app, three minutes apart, are two calls. And the dev
# build's newest call is newer than anything in production.
profile ReMynd-fixture "
  INSERT INTO Call VALUES (1,'Zoom','$(ago 10d)','$(ago 10d)','Prod planning','[]');
  INSERT INTO Call VALUES (2,'Zoom','$(ago 180M)','$(ago 150M)','Prod review','[]');
  INSERT INTO Call VALUES (3,'Zoom','$(ago 177M)','$(ago 150M)','Prod follow up','[]');
  INSERT INTO TranscriptionSegment (callID, startTimestamp, text, speaker) VALUES (2,'$(ago 170M)','budget from production','A');"
profile ReMynd-dev-fixture "
  INSERT INTO Call VALUES (8,'Zoom','$(ago 60M)','$(ago 50M)','Dev smoke test','[]');
  INSERT INTO TranscriptionSegment (callID, startTimestamp, text, speaker) VALUES (8,'$(ago 55M)','budget from development','A');"
PROD="$BASE/ReMynd-fixture"
DEV="$BASE/ReMynd-dev-fixture"

remynd() { env -i HOME="$H" PATH=/usr/bin:/bin REMYND_STATE_DIR="$STATE" bash "$CLI" "$@" 2>&1; }
pin() { printf 'profile=%s\n' "$1" > "$STATE/config"; }

for how in pinned auto; do
  if [ "$how" = pinned ]; then pin "$PROD"; else : > "$STATE/config"; fi
  out="$(remynd call last)"
  has   "$how: call last is production's newest" "$out" "Prod follow up"
  hasnt "$how: call last is not the dev build's" "$out" "Dev smoke test"
  out="$(remynd calls 3650)"
  hasnt "$how: calls leaves out the dev build" "$out" "Dev smoke test"
  for t in "Prod planning" "Prod review" "Prod follow up"; do has "$how: calls lists $t" "$out" "$t"; done
  out="$(remynd heard budget)"
  has   "$how: heard finds production's words" "$out" "budget from production"
  hasnt "$how: heard leaves out the dev build's" "$out" "budget from development"
done

pin "$DEV"
out="$(remynd call last)"
has   "pinned to dev: call last is the dev build's" "$out" "Dev smoke test"
out="$(remynd calls 3650)"
hasnt "pinned to dev: production's calls are left out" "$out" "Prod review"

pin "$PROD"
out="$(remynd moment "2026-09-14 10:00:00" x)"; rc=$?
is  "moment with bad minutes: exit 1" "$rc" 1
has "moment with bad minutes: names the problem" "$out" "whole number"
for argv in "recent -5" "recent abc" "search x abc" "search x -1" "apps x" "calls x" "heard y x"; do
  # shellcheck disable=SC2086
  out="$(remynd $argv)"; rc=$?
  is  "$argv: exit 1" "$rc" 1
  has "$argv: names the problem" "$out" "whole number"
  hasnt "$argv: no date(1) usage text" "$out" "usage: date"
done

# ---------------------------------------------------------------------------
# The MCP server, in the bare environment a client gives it.
# ---------------------------------------------------------------------------
mcp_call() { # <tool> <json arguments>
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" |
    env -i HOME="$H" CFFIXED_USER_HOME="$H" PATH=/usr/bin:/bin REMYND_STATE_DIR="$STATE" REMYND_CLI="$CLI" "$MCP" 2>/dev/null
}

if [ ! -x "$MCP" ]; then
  bad "no server at $MCP"
else
  out="$(mcp_call call_transcript '{"call":"last"}')"
  has   "mcp: call_transcript last is production's" "$out" "Prod follow up"
  hasnt "mcp: call_transcript last is not the dev build's" "$out" "Dev smoke test"
  out="$(mcp_call list_calls '{"days":3650}')"
  hasnt "mcp: list_calls leaves out the dev build" "$out" "Dev smoke test"
  has   "mcp: list_calls keeps both close calls" "$out" "Prod review"
  has   "mcp: list_calls keeps both close calls (2)" "$out" "Prod follow up"
  for tool_args in 'recent_activity {"minutes":"abc"}' 'search_screen_history {"query":"x","limit":"abc"}' \
                   'time_by_activity {"days":"abc"}' 'search_calls {"query":"x","limit":"abc"}' \
                   'list_calls {"days":"abc"}' 'recent_activity {"minutes":true}'; do
    out="$(mcp_call "${tool_args%% *}" "${tool_args#* }")"
    has "mcp: ${tool_args} is an error" "$out" '"isError":true'
    has "mcp: ${tool_args} names the problem" "$out" "must be a whole number"
  done
  out="$(mcp_call recent_activity '{"minutes":-5}')"
  has   "mcp: minutes -5 is an error" "$out" '"isError":true'
  has   "mcp: minutes -5 names the problem" "$out" "whole number"
  hasnt "mcp: minutes -5 shows no date(1) usage" "$out" "usage: date"
  out="$(mcp_call search_screen_history '{"query":"x","limit":1e30}')"
  has "mcp: limit 1e30 answers instead of crashing" "$out" "must be a whole number"
fi

# ---------------------------------------------------------------------------
# Which profile answered. Calls read one profile, so nothing may claim to speak
# for the whole Mac, and a stale pin is an error, not an empty history.
# ---------------------------------------------------------------------------
pin "$PROD"
out="$(remynd calls 3650)"
has "calls names its profile" "$out" "From profile: ReMynd-fixture (production)"
has "calls points at the other profile" "$out" "ReMynd-dev-fixture (development), 1 call"
has "calls says how to read it" "$out" "REMYND_PROFILE"
out="$(remynd call last)"
has "call last names its profile" "$out" "From profile: ReMynd-fixture (production)"
out="$(remynd heard budget)"
has "heard names its profile" "$out" "From profile: ReMynd-fixture (production)"
has "heard says what it did not search" "$out" "ReMynd-dev-fixture (development), 1 call"
out="$(remynd call 2)"
has   "an id wins over newer calls whose date holds the digit" "$out" "# Prod review"
hasnt "an id is not ambiguous" "$out" "pick one by id"
pin "$DEV"
out="$(remynd calls 3650)"
has "pinned to dev: calls names dev" "$out" "From profile: ReMynd-dev-fixture (development)"
has "pinned to dev: calls points at production" "$out" "ReMynd-fixture (production), 3 calls"

# A call only in another profile is not "never recorded".
profile ReMynd-empty "SELECT 1;"
EMPTY="$BASE/ReMynd-empty"
pin "$EMPTY"
out="$(remynd call last)"; rc=$?
is    "empty profile: call last exits 1" "$rc" 1
hasnt "empty profile: call last does not speak for the Mac" "$out" "on this Mac"
has   "empty profile: call last names the profile" "$out" "ReMynd-empty"
has   "empty profile: call last points at a profile with calls" "$out" "ReMynd-dev-fixture (development), 1 call"
has   "empty profile: call last says how" "$out" "REMYND_PROFILE"
out="$(remynd call zzz)"; rc=$?
is    "empty profile: a fragment exits 1" "$rc" 1
has   "empty profile: a fragment points at a profile with calls" "$out" "ReMynd-fixture (production), 3 calls"
out="$(remynd heard budget)"; rc=$?
is    "empty profile: heard exits 0" "$rc" 0
hasnt "empty profile: heard does not speak for every call" "$out" "any recorded call"
has   "empty profile: heard names the profile" "$out" "ReMynd-empty"
has   "empty profile: heard points at a profile with calls" "$out" "ReMynd-dev-fixture (development), 1 call"
out="$(remynd calls 3650)"; rc=$?
is    "empty profile: calls exits 0" "$rc" 0
has   "empty profile: calls names the profile" "$out" "From profile: ReMynd-empty (production)"
has   "empty profile: calls points at a profile with calls" "$out" "ReMynd-dev-fixture (development), 1 call"
out="$(remynd status)"
has   "status: calls line names the profile's scope" "$out" "Calls:       none recorded in this profile"
has   "status: names the others" "$out" "ReMynd-dev-fixture (development), 1 call"

# A backup holds copies, not another place to look.
profile ReMynd-fixture-backup "INSERT INTO Call VALUES (9,'Zoom','$(ago 10d)','$(ago 10d)','Backed up','[]');"
out="$(remynd calls 3650)"
hasnt "a backup is not offered as a profile" "$out" "ReMynd-fixture-backup"

# With nothing else on the Mac there is nothing to point at.
SOLO="$(mktemp -d /tmp/remynd-solo.XXXXXX)"
mkdir -p "$SOLO/Recordings/Extras"
/usr/bin/sqlite3 "$SOLO/Recordings/app.db" "CREATE TABLE FocusedWindow (id INTEGER PRIMARY KEY);"
out="$(env -i HOME="$SOLO" PATH=/usr/bin:/bin REMYND_STATE_DIR="$STATE" REMYND_PROFILE="$SOLO" bash "$CLI" calls 30 2>&1)"
hasnt "no other profile: no pointer" "$out" "REMYND_PROFILE"
has   "a profile with no extras.db still says where it looked" "$out" "From profile:"
rm -rf "$SOLO"

# A stale pin reads as an error from every command, naming the pin.
GONE="$BASE/ReMynd-renamed-away"
pin "$GONE"
for argv in "calls 30" "call last" "call 2" "heard budget" "recent" "search x" "day 2026-09-14"; do
  # shellcheck disable=SC2086
  out="$(remynd $argv)"; rc=$?
  is    "stale pin: $argv exits 1" "$rc" 1
  has   "stale pin: $argv names the pin" "$out" "$GONE"
  has   "stale pin: $argv says it is the pin" "$out" "pinned profile does not exist"
  hasnt "stale pin: $argv does not read as no calls" "$out" "no calls"
  hasnt "stale pin: $argv does not read as nothing said" "$out" "nothing matching"
done
out="$(remynd status)"
has "stale pin: status says so" "$out" "pinned profile does not exist"
: > "$STATE/config"
out="$(env -i HOME="$H" PATH=/usr/bin:/bin REMYND_STATE_DIR="$STATE" REMYND_PROFILE="$GONE" bash "$CLI" calls 30 2>&1)"; rc=$?
is  "stale REMYND_PROFILE: exits 1" "$rc" 1
has "stale REMYND_PROFILE: names the variable" "$out" "REMYND_PROFILE"
has "stale REMYND_PROFILE: names the path" "$out" "$GONE"

if [ -x "$MCP" ]; then
  pin "$PROD"
  TEN_DAYS_AGO="$(/bin/date -v-10d '+%Y-%m-%d')"
  out="$(mcp_call list_calls '{"days":3650}')"
  has "mcp: list_calls names its profile" "$out" "From profile: ReMynd-fixture (production)"
  has "mcp: list_calls points at the other profile" "$out" "ReMynd-dev-fixture (development), 1 call"
  out="$(mcp_call list_calls "{\"date\":\"$TEN_DAYS_AGO\"}")"
  has "mcp: list_calls with a date names its profile" "$out" "From profile: ReMynd-fixture (production)"
  has "mcp: list_calls with a date points at the other profile" "$out" "ReMynd-dev-fixture (development), 1 call"
  out="$(mcp_call list_calls '{"date":"2020-01-02"}')"
  has   "mcp: a date with none names the profile" "$out" "From profile: ReMynd-fixture (production)"
  has   "mcp: a date with none points at the other profile" "$out" "ReMynd-dev-fixture (development), 1 call"
  hasnt "mcp: a date with none does not speak for the Mac" "$out" "No calls were recorded on"
  out="$(mcp_call reconstruct_day "{\"date\":\"$TEN_DAYS_AGO\"}")"
  has "mcp: reconstruct_day names its calls' profile" "$out" "From profile: ReMynd-fixture (production)"
  out="$(mcp_call call_transcript '{"call":"2"}')"
  has "mcp: call_transcript names its profile" "$out" "From profile: ReMynd-fixture (production)"
  out="$(mcp_call search_calls '{"query":"budget"}')"
  has "mcp: search_calls names its profile" "$out" "From profile: ReMynd-fixture (production)"
  pin "$GONE"
  for tool_args in 'list_calls {"days":30}' 'call_transcript {"call":"last"}' 'search_calls {"query":"budget"}'; do
    out="$(mcp_call "${tool_args%% *}" "${tool_args#* }")"
    has   "mcp: stale pin: ${tool_args} is an error" "$out" '"isError":true'
    has   "mcp: stale pin: ${tool_args} names the pin" "$out" "pinned profile does not exist"
  done
  pin "$PROD"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
