#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ReMynd × AI agents — shared library
#
# Profile detection, freshness signals, JSON emission, token accounting.
# Dependencies: bash, /usr/bin/sqlite3, /usr/bin/awk, /usr/bin/sed. Nothing else.
# jq is deliberately NOT used: ReMynd supports macOS 14+, and jq only ships
# with macOS 26. See docs/PRD-always-hot.md §13.3.
#
# Everything here is READ-ONLY with respect to ReMynd's data.
# ---------------------------------------------------------------------------

REMYND_STATE_DIR="${REMYND_STATE_DIR:-$HOME/.remynd-sync}"
REMYND_SQLITE="${REMYND_SQLITE:-/usr/bin/sqlite3}"
[ -x "$REMYND_SQLITE" ] || REMYND_SQLITE="$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)"

# Field separator for sqlite3 output. Unit Separator (0x1F) never appears in
# OCR text, unlike '|' which appears constantly in code and tables.
REMYND_FS=$'\037'

# ---------------------------------------------------------------------------
# Profile detection — production first (PRD §5.7)
#
# Requires Recordings/app.db. Prefers a production bundle over a dev one.
# Tie-breaks on the freshest database. Never scores on SecondBrain files: the
# brain is not in the production release, and keying on it is exactly the bug
# that left the previous integration emitting zero bytes.
# ---------------------------------------------------------------------------
remynd_find_profile() {
  # Explicit override wins: the REMYND_PROFILE env var first, then a
  # `profile=` line in the config. Useful when a machine has both a
  # production and a development ReMynd and you want to pin one.
  local override="${REMYND_PROFILE:-}"
  [ -n "$override" ] || override="$(remynd_config_get profile "")"
  if [ -n "$override" ]; then
    [ -f "$override/Recordings/app.db" ] && { printf '%s\n' "$override"; return 0; }
    return 1
  fi

  local base="$HOME/Library/Application Support/Move37"
  [ -d "$base" ] || return 1

  local best="" best_rank=-1 best_mtime=-1
  local d name rank mtime
  for d in "$base"/ReMynd-* "$base"/ScreenomeX-*; do
    [ -d "$d" ] || continue
    [ -f "$d/Recordings/app.db" ] || continue          # hard requirement
    name="$(basename "$d")"
    case "$name" in
      *-fresh-backup|*-backup|*BackupTree*) continue ;;
    esac

    case "$name" in
      *-dev-*|*-dev) rank=0 ;;                          # dev build
      *)             rank=1 ;;                          # production
    esac
    mtime="$(remynd_db_mtime "$d/Recordings/app.db")"

    if [ "$rank" -gt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ "$mtime" -gt "$best_mtime" ]; }; then
      best="$d"; best_rank="$rank"; best_mtime="$mtime"
    fi
  done

  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Freshness signal. The -wal sidecar is mandatory: under WAL the recorder's
# writes land there and app.db's own mtime can sit unchanged for minutes.
remynd_db_mtime() {
  local db="$1" m=0 t
  for f in "$db" "$db-wal"; do
    [ -f "$f" ] || continue
    t="$(stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$t" -gt "$m" ] && m="$t"
  done
  printf '%s\n' "$m"
}

remynd_db_path() { printf '%s/Recordings/app.db\n' "$1"; }

# Read-only URI. WAL allows concurrent readers while the recorder writes.
# OCR'd text and window titles regularly contain invalid UTF-8 (the recogniser
# emits partial sequences). Left alone, awk aborts with "towc: multibyte
# conversion failure" mid-stream. iconv -c drops the bad sequences so the rest
# of the pipeline can stay in a UTF-8 locale, which the title normaliser needs
# for its multibyte character classes.
remynd_sql() {
  local db="$1"; shift
  "$REMYND_SQLITE" -readonly -noheader -separator "$REMYND_FS" "file:$db?mode=ro&immutable=0" "$@" 2>/dev/null |
    /usr/bin/iconv -c -f UTF-8 -t UTF-8 2>/dev/null
}

# Same query path without the iconv pass. For results that cannot contain OCR
# text — row ids, counts, timestamps — sanitising is pointless, and the extra
# process shows up on the prompt-latency budget because the delta hook makes
# several of these calls per prompt.
remynd_sql_num() {
  local db="$1"; shift
  "$REMYND_SQLITE" -readonly -noheader -separator "$REMYND_FS" "file:$db?mode=ro&immutable=0" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# JSON emission without jq
#
# Escapes per RFC 8259: backslash, quote, the two-char control escapes, and
# any remaining C0 control as \u00XX. Reads stdin, writes one JSON string.
# ---------------------------------------------------------------------------
remynd_json_string() {
  /usr/bin/awk '
    BEGIN { RS="^$"; ORS=""; printf "\"" }
    {
      s = $0
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"", s)
      gsub(/\n/, "\\n", s)
      gsub(/\r/, "\\r", s)
      gsub(/\t/, "\\t", s)
      gsub(/\010/, "\\b", s)
      gsub(/\014/, "\\f", s)
      for (i = 1; i <= 31; i++) {
        if (i == 8 || i == 9 || i == 10 || i == 12 || i == 13) continue
        c = sprintf("%c", i)
        gsub(c, sprintf("\\u%04x", i), s)
      }
      printf "%s", s
    }
    END { printf "\"" }
  '
}

# Wrap stdin as a Claude Code hook payload for the given event.
remynd_hook_payload() {
  local event="$1"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":' "$event"
  remynd_json_string
  printf '}}\n'
}

# ---------------------------------------------------------------------------
# Token accounting. ~4 chars per token is the working approximation; the
# budget governor only needs to be right to within a few percent.
# ---------------------------------------------------------------------------
remynd_tokens_of_file() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  /usr/bin/awk 'BEGIN{n=0} {n+=length($0)+1} END{printf "%d\n", (n+3)/4}' "$f"
}

remynd_state_dir() {
  mkdir -p "$REMYND_STATE_DIR" 2>/dev/null
  printf '%s\n' "$REMYND_STATE_DIR"
}

# Config, written by the installer, read by the hooks. Simple key=value so it
# can be edited by hand without a parser.
remynd_config_get() {
  local key="$1" default="$2" file
  file="$(remynd_state_dir)/config"
  [ -f "$file" ] || { printf '%s\n' "$default"; return; }
  local v
  v="$(/usr/bin/sed -n "s/^${key}=//p" "$file" | tail -1)"
  [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$default"
}

# ---------------------------------------------------------------------------
# Binary search for the rowid at a timestamp.
#
# Needed because there is no index on any timestamp column, so
# `SELECT MIN(id) ... WHERE firstSeenAt >= x` costs a ~4s full scan. `id` is
# AUTOINCREMENT and therefore monotonic with time, so ~28 primary-key seeks
# (~30ms total) find the boundary instead.
#
# remynd_id_at_time <db> <table> <timecol> <target>
# ---------------------------------------------------------------------------
remynd_id_at_time() {
  local db="$1" table="$2" col="$3" target="$4"
  local lo hi mid t
  lo="$(remynd_sql_num "$db" "SELECT COALESCE(MIN(id),0) FROM $table;")"
  hi="$(remynd_sql_num "$db" "SELECT COALESCE(MAX(id),0) FROM $table;")"
  [ -z "$lo" ] && { echo 0; return; }
  [ "$hi" -le "$lo" ] && { echo "$lo"; return; }

  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    t="$(remynd_sql_num "$db" "SELECT $col FROM $table WHERE id >= $mid ORDER BY id ASC LIMIT 1;")"
    if [ -z "$t" ]; then hi=$(( mid ))
    elif [ "$t" \< "$target" ]; then lo=$(( mid + 1 ))
    else hi=$(( mid )); fi
  done
  printf '%s\n' "$lo"
}
