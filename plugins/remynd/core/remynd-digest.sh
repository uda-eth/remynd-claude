#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ReMynd digest builder — turns the production app.db into agent context.
#
# Two shapes, one format (PRD §5.4): a full snapshot for session start, and a
# delta for "what happened since we last spoke". Both carry OCR body text.
#
# PERFORMANCE NOTE — the single most important thing in this file.
# app.db has no index on any timestamp column. A plain
#   WHERE firstSeenAt >= <cutoff>
# full-scans 873k rows and takes ~4 SECONDS. Because `id` is AUTOINCREMENT and
# therefore monotonic with firstSeenAt, bounding the rowid tail FIRST and
# filtering by time inside that subquery costs ~29 ms — a 136x difference,
# measured. Every query below is written that way. Do not "simplify" them.
# ---------------------------------------------------------------------------

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/remynd-lib.sh"

# How far back the rowid tail reaches. 60k OCR segments is ~6 hours of heavy
# use on the reference profile; the time filter inside the subquery does the
# real bounding, this just keeps the scan cheap.
REMYND_OCR_TAIL="${REMYND_OCR_TAIL:-60000}"
REMYND_WIN_TAIL="${REMYND_WIN_TAIL:-20000}"

# ---------------------------------------------------------------------------
# Redaction (PRD §5.8) — credential-shaped strings only, ~0.1% of text volume.
# Everything else passes through untouched. Defaults ON; the installer writes
# redact_credentials=0 to disable.
# ---------------------------------------------------------------------------
_remynd_redact_awk() {
  cat <<'AWK'
function redact(s) {
  gsub(/sk-[A-Za-z0-9_-]{16,}/,                     "sk-<redacted>", s)
  gsub(/sk-ant-[A-Za-z0-9_-]{16,}/,                 "sk-ant-<redacted>", s)
  gsub(/(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{16,}/,    "gh_<redacted>", s)
  gsub(/github_pat_[A-Za-z0-9_]{20,}/,              "github_pat_<redacted>", s)
  gsub(/AKIA[0-9A-Z]{16}/,                          "AKIA<redacted>", s)
  gsub(/ASIA[0-9A-Z]{16}/,                          "ASIA<redacted>", s)
  gsub(/xox[baprs]-[A-Za-z0-9-]{10,}/,              "xox<redacted>", s)
  gsub(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/, "<jwt-redacted>", s)
  gsub(/[Bb]earer[ \t]+[A-Za-z0-9._~+\/-]{20,}/,    "Bearer <redacted>", s)
  gsub(/-----BEGIN[ A-Z]*PRIVATE KEY-----/,         "-----BEGIN PRIVATE KEY <redacted>-----", s)
  gsub(/AIza[A-Za-z0-9_-]{30,}/,                    "AIza<redacted>", s)
  gsub(/[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}/, "<card-redacted>", s)
  # key = value / password: value, case-insensitive on the key
  gsub(/[Pp][Aa][Ss][Ss][Ww]?[Oo]?[Rr]?[Dd][\"']?[ \t]*[:=][ \t]*[^ \t]+/, "password=<redacted>", s)
  gsub(/[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z_-]*[\"']?[ \t]*[:=][ \t]*[^ \t]+/, "secret=<redacted>", s)
  gsub(/[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][\"']?[ \t]*[:=][ \t]*[^ \t]+/,       "api_key=<redacted>", s)
  gsub(/[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn][\"']?[ \t]*[:=][ \t]*[^ \t]+/, "access_token=<redacted>", s)
  return s
}
AWK
}


# ---------------------------------------------------------------------------
# sync_exclude (PRD §5.8) — apps and domains that ReMynd captured but that must
# never be sent to an agent.
#
# ReMynd itself has no per-app capture exclusion, so this is the only place a
# user can carve one out. Empty by default: opting in means everything.
# Matching is case-insensitive substring, against the focused app name.
# ---------------------------------------------------------------------------
_remynd_exclude_awk() {
  cat <<'AWK'
function is_excluded(a,   i, la) {
  if (n_ex == 0) return 0
  la = tolower(a)
  for (i = 1; i <= n_ex; i++) {
    if (ex_list[i] == "") continue
    if (index(la, ex_list[i]) > 0) return 1
  }
  return 0
}
AWK
}

remynd_exclude_pattern() {
  remynd_config_get sync_exclude "" |
    /usr/bin/awk '{ gsub(/[ \t]*,[ \t]*/, ","); print tolower($0) }'
}

# ---------------------------------------------------------------------------
# Structural layer: where the user was.
# ---------------------------------------------------------------------------

# Currently focused app + window.
remynd_now() {
  local db="$1"
  remynd_sql "$db" "
    SELECT applicationName, COALESCE(windowTitle,''), datetime(startedAt,'localtime')
    FROM (SELECT applicationName, windowTitle, startedAt, id
          FROM FocusedWindow ORDER BY id DESC LIMIT 50)
    ORDER BY id DESC LIMIT 1;" |
  /usr/bin/awk -F"$REMYND_FS" '
    NF { printf "%s", $1; if ($2 != "") printf " — \"%s\"", $2; printf "\n" }'
}

# Time spent per app in a window, most first.
remynd_app_rollup() {
  local db="$1" since="$2" limit="${3:-8}"
  remynd_sql "$db" "
    SELECT applicationName,
           CAST(SUM(MAX(0, strftime('%s', COALESCE(endedAt, startedAt)) - strftime('%s', startedAt))) / 60 AS INT) mins
    FROM (SELECT id, applicationName, startedAt, endedAt
          FROM FocusedWindow ORDER BY id DESC LIMIT $REMYND_WIN_TAIL)
    WHERE startedAt >= '$since' AND applicationName IS NOT NULL AND applicationName != '' AND applicationName NOT IN ('loginwindow','ScreenSaverEngine','Window Server','WindowServer')
    GROUP BY applicationName
    HAVING mins > 0
    ORDER BY mins DESC LIMIT $limit;" |
  /usr/bin/awk -F"$REMYND_FS" '
    NF { out = out sep $1 " " $2 "m"; sep = " · " }
    END { if (out != "") print out }'
}

# Distinct window titles seen in the period — the cheapest signal of "what
# were they actually doing".
remynd_window_trail() {
  local db="$1" since="$2" limit="${3:-12}"
  remynd_sql "$db" "
    SELECT applicationName, windowTitle, datetime(MIN(startedAt),'localtime') t
    FROM (SELECT id, applicationName, windowTitle, startedAt
          FROM FocusedWindow ORDER BY id DESC LIMIT $REMYND_WIN_TAIL)
    WHERE startedAt >= '$since' AND windowTitle IS NOT NULL AND windowTitle != ''
    GROUP BY applicationName, windowTitle
    ORDER BY t DESC LIMIT $limit;" |
  /usr/bin/awk -F"$REMYND_FS" '
    NF { printf "%s  %s — %s\n", substr($3, 12, 5), $1, $2 }'
}

# Web pages visited, by title.
remynd_web_trail() {
  local db="$1" since="$2" limit="${3:-10}"
  remynd_sql "$db" "
    SELECT COALESCE(v.title,''), u.url, MAX(v.navigatedToAt) t
    FROM (SELECT id, webURLId, title, navigatedToAt
          FROM WebURLVisit ORDER BY id DESC LIMIT $REMYND_WIN_TAIL) v
    JOIN WebUrl u ON u.id = v.webURLId
    WHERE v.navigatedToAt >= '$since'
    GROUP BY u.url
    ORDER BY t DESC LIMIT $limit;" |
  /usr/bin/awk -F"$REMYND_FS" '
    NF {
      url = $2
      sub(/^https?:\/\//, "", url)
      sub(/\/.*$/, "", url)
      if ($1 != "") printf "%s — \"%s\"\n", url, $1
      else printf "%s\n", url
    }'
}

# ---------------------------------------------------------------------------
# OCR body layer: what was actually on the screen (PRD §5.4).
#
# Deduped on normalizedText — the recorder re-observes the same string across
# frames, and collapsing it saves ~43% of tokens with zero information lost.
# Correlated with the focused app in awk rather than SQL, because a correlated
# subquery over an unindexed FocusedWindow would cost seconds.
# ---------------------------------------------------------------------------
remynd_ocr_since() {
  local db="$1" since="$2" budget_tokens="${3:-4000}" redact="${4:-1}"

  # Window timeline first (small), then OCR (large). awk merges them.
  { remynd_sql "$db" "
      SELECT 'W', datetime(startedAt,'localtime'), applicationName
      FROM (SELECT id, startedAt, applicationName
            FROM FocusedWindow ORDER BY id DESC LIMIT $REMYND_WIN_TAIL)
      WHERE startedAt >= '$since' AND applicationName IS NOT NULL
      ORDER BY startedAt ASC;"
    remynd_sql "$db" "
      SELECT 'O', datetime(firstSeenAt,'localtime'), REPLACE(REPLACE(displayText, char(10), ' '), char(13), ' '), normalizedText
      FROM (SELECT id, firstSeenAt, displayText, normalizedText
            FROM OCRTextSegment ORDER BY id DESC LIMIT $REMYND_OCR_TAIL)
      WHERE firstSeenAt >= '$since'
      ORDER BY firstSeenAt ASC;"
  } | LC_ALL=C /usr/bin/sort -t"$REMYND_FS" -k2,2 -s |
  /usr/bin/awk -F"$REMYND_FS" -v budget="$budget_tokens" -v doredact="$redact" \
                -v excl="$(remynd_exclude_pattern)" '
'"$(_remynd_redact_awk)"'
'"$(_remynd_exclude_awk)"'
    BEGIN { chars = 0; app = ""; lastapp = ""; truncated = 0; deferred = 0; excluded = 0
            n_ex = split(excl, ex_list, ",") }
    {
      if ($1 == "W") { app = $3; next }
      if ($1 != "O") next
      if (is_excluded(app)) { excluded++; next }

      # Dedupe on normalizedText AND on the rendered text. The recorder can
      # produce two rows whose normalizedText differs by a spinner glyph or a
      # cursor while the visible text is identical — same information, twice.
      key = $4
      if (key == "") key = $3
      if (key in seen) next
      seen[key] = 1

      text = $3
      if (text == "") next
      if (text in shown) next
      shown[text] = 1
      if (doredact == 1) text = redact(text)

      # Budget: stop emitting body text, keep counting what we deferred.
      if (truncated) { deferred++; next }
      if ((chars + length(text)) / 4 > budget) { truncated = 1; deferred++; next }

      if (app != lastapp) {
        printf "\n%s  %s\n", substr($2, 12, 5), (app == "" ? "(unknown app)" : app)
        lastapp = app
        chars += length(app) + 10
      }
      printf "  > %s\n", text
      chars += length(text) + 5
    }
    END {
      if (deferred > 0)
        printf "\n  …%d more captured lines in this window — ask /remynd for the full text\n", deferred
      if (excluded > 0)
        printf "\n  (%d lines withheld by your sync_exclude setting)\n", excluded
    }
  '
}

# ---------------------------------------------------------------------------
# Assembled digests
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# TIME ZONES — read this before touching any query.
#
# app.db stores every timestamp in **UTC**, despite what earlier ReMynd docs
# claimed. Verified 2026-08-19: a capture written at 10:22:30 EDT is stored as
# 14:22:30. Getting this wrong silently shifts every window by the UTC offset,
# so a "last 30 minutes" digest quietly returns nothing.
#
# The rule: FILTER in UTC, DISPLAY in local. Cutoffs are produced with
# `date -u`; every timestamp shown to a human goes through SQLite's
# datetime(col,'localtime').
# ---------------------------------------------------------------------------
remynd_cutoff() { /bin/date -u -v-"$1"M '+%Y-%m-%d %H:%M:%S'; }

# Convert a local time string the user typed into the UTC form the DB uses.
remynd_local_to_utc() {
  /bin/date -u -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# Full snapshot — SessionStart (PRD §5.2).
#
# The budget covers the WHOLE digest, not just the OCR section: the structural
# part is built first, measured, and its cost subtracted before the body text
# is allowed to spend what remains.
remynd_digest_full() {
  local db="$1" ocr_minutes="${2:-30}" budget="${3:-8000}" redact="${4:-1}"
  local hours_cut ocr_cut structural ocr used remaining

  hours_cut="$(remynd_cutoff 120)"
  ocr_cut="$(remynd_cutoff "$ocr_minutes")"

  structural="$(
    echo "# ReMynd — your recent activity"
    echo
    echo "Live from your own screen history, captured by ReMynd on this Mac. Read-only."
    echo "Generated $(/bin/date '+%Y-%m-%d %H:%M') local time."
    echo

    local now_line apps wins web
    now_line="$(remynd_now "$db")"
    [ -n "$now_line" ] && { echo "## Right now"; echo "$now_line"; echo; }

    apps="$(remynd_app_rollup "$db" "$hours_cut")"
    [ -n "$apps" ] && { echo "## Last 2 hours"; echo "$apps"; echo; }

    wins="$(remynd_window_trail "$db" "$hours_cut")"
    [ -n "$wins" ] && { echo "## What you had open"; echo "$wins"; echo; }

    web="$(remynd_web_trail "$db" "$hours_cut")"
    [ -n "$web" ] && { echo "## What you were reading"; echo "$web"; echo; }
  )"

  # Reserve ~60 tokens for the closing footer.
  used=$(( ${#structural} / 4 ))
  remaining=$(( budget - used - 60 ))
  [ "$remaining" -lt 200 ] && remaining=200

  printf '%s\n' "$structural"

  ocr="$(remynd_ocr_since "$db" "$ocr_cut" "$remaining" "$redact")"
  if [ -n "$ocr" ]; then
    echo "## On your screen (last ${ocr_minutes}m, verbatim)"
    echo "$ocr"
    echo
  fi

  echo "---"
  echo "Ask \`/remynd\` to search further back or reconstruct a specific day."
}

# Delta — UserPromptSubmit (PRD §5.3).
remynd_digest_delta() {
  local db="$1" since="$2" budget="${3:-6000}" redact="${4:-1}"
  local apps ocr wins

  apps="$(remynd_app_rollup "$db" "$since" 5)"
  wins="$(remynd_window_trail "$db" "$since" 6)"
  ocr="$(remynd_ocr_since "$db" "$since" "$budget" "$redact")"

  [ -z "$apps" ] && [ -z "$wins" ] && [ -z "$ocr" ] && return 1

  echo "# ReMynd — since we last spoke"
  echo
  [ -n "$apps" ] && { echo "$apps"; echo; }
  [ -n "$wins" ] && { echo "$wins"; echo; }
  [ -n "$ocr" ]  && { echo "$ocr"; }
  return 0
}

# ---------------------------------------------------------------------------
# Rowid-watermarked delta (PRD §5.3, acceptance criterion 5)
#
# The timestamp path above still pays for a 60k-row tail scan on every call —
# fine at session start, too slow to sit on the prompt path. Because the
# watermark can remember the last OCR rowid it injected, the delta becomes a
# pure primary-key range scan: WHERE id > <last>. That is an index seek, and
# its cost is proportional to what is actually new rather than to the tail.
# ---------------------------------------------------------------------------

remynd_max_ocr_id() {
  remynd_sql "$1" "SELECT COALESCE(MAX(id),0) FROM OCRTextSegment;"
}

remynd_max_window_id() {
  remynd_sql "$1" "SELECT COALESCE(MAX(id),0) FROM FocusedWindow;"
}

# remynd_ocr_since_id <db> <last_ocr_id> <last_window_id> <budget> <redact>
remynd_ocr_since_id() {
  local db="$1" last_ocr="$2" last_win="$3" budget_tokens="${4:-6000}" redact="${5:-1}"

  { remynd_sql "$db" "
      SELECT 'W', datetime(startedAt,'localtime'), applicationName FROM FocusedWindow
      WHERE id > $last_win AND applicationName IS NOT NULL AND applicationName != '' AND applicationName NOT IN ('loginwindow','ScreenSaverEngine','Window Server','WindowServer')
      ORDER BY id ASC;"
    remynd_sql "$db" "
      SELECT 'O', datetime(firstSeenAt,'localtime'), REPLACE(REPLACE(displayText, char(10), ' '), char(13), ' '), normalizedText
      FROM OCRTextSegment WHERE id > $last_ocr ORDER BY id ASC;"
  } | LC_ALL=C /usr/bin/sort -t"$REMYND_FS" -k2,2 -s |
  /usr/bin/awk -F"$REMYND_FS" -v budget="$budget_tokens" -v doredact="$redact" \
                -v excl="$(remynd_exclude_pattern)" '
'"$(_remynd_redact_awk)"'
'"$(_remynd_exclude_awk)"'
    BEGIN { chars = 0; app = ""; lastapp = ""; truncated = 0; deferred = 0; excluded = 0
            n_ex = split(excl, ex_list, ",") }
    {
      if ($1 == "W") { app = $3; next }
      if ($1 != "O") next
      if (is_excluded(app)) { excluded++; next }
      key = $4; if (key == "") key = $3
      if (key in seen) next
      seen[key] = 1
      text = $3
      if (text == "") next
      if (text in shown) next
      shown[text] = 1
      if (doredact == 1) text = redact(text)
      if (truncated) { deferred++; next }
      if ((chars + length(text)) / 4 > budget) { truncated = 1; deferred++; next }
      if (app != lastapp) {
        printf "\n%s  %s\n", substr($2, 12, 5), (app == "" ? "(unknown app)" : app)
        lastapp = app; chars += length(app) + 10
      }
      printf "  > %s\n", text
      chars += length(text) + 5
    }
    END {
      if (deferred > 0)
        printf "\n  …%d more captured lines — ask /remynd for the full text\n", deferred
      if (excluded > 0)
        printf "\n  (%d lines withheld by your sync_exclude setting)\n", excluded
    }
  '
}

# Apps touched since a rowid, for the delta header.
remynd_apps_since_id() {
  local db="$1" last_win="$2"
  remynd_sql "$db" "
    SELECT DISTINCT applicationName FROM FocusedWindow
    WHERE id > $last_win AND applicationName IS NOT NULL AND applicationName != '' AND applicationName NOT IN ('loginwindow','ScreenSaverEngine','Window Server','WindowServer')
    ORDER BY id ASC LIMIT 8;" |
  /usr/bin/awk -F"$REMYND_FS" 'NF { out = out sep $1; sep = " · " } END { if (out != "") print out }'
}

# remynd_digest_delta_id <db> <last_ocr_id> <last_window_id> <budget> <redact>
# Emits nothing and returns 1 when there is no news.
remynd_digest_delta_id() {
  local db="$1" last_ocr="$2" last_win="$3" budget="${4:-6000}" redact="${5:-1}"
  local apps ocr body

  apps="$(remynd_apps_since_id "$db" "$last_win")"
  ocr="$(remynd_ocr_since_id "$db" "$last_ocr" "$last_win" "$budget" "$redact")"

  body=""
  [ -n "$apps" ] && body="$body$apps"$'\n'
  [ -n "$ocr" ]  && body="$body$ocr"$'\n'
  [ -z "$body" ] && return 1

  printf '# ReMynd — since we last spoke\n\n%s' "$body"
  return 0
}
