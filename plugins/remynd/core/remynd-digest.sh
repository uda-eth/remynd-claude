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
# Agent self-capture (exclude_agent_ui)
#
# ReMynd records the screen, and the screen includes the coding agent's own
# terminal UI. Feeding that back is a mirror: the assistant re-reads its own
# previous answers, OCR'd and line-wrapped, as if it were new information about
# the user. Measured on one real delta: 593 OCR lines, of which 84 echoed the
# assistant's own prior output and 31 were TUI chrome.
#
# It is also pure waste — the agent already holds that conversation verbatim
# and losslessly, so dropping the OCR of it loses nothing at all.
#
# Detection: a terminal emulator whose window title marks it as an agent
# session. Structural lines (app, title, timing) are kept; only the OCR body
# text of those windows is dropped.
# ---------------------------------------------------------------------------
_remynd_agentui_awk() {
  cat <<'AWK'
function is_agent_ui(a, t) {
  if (skip_agent != 1) return 0
  if (a !~ /Terminal|iTerm|Ghostty|Alacritty|WezTerm|kitty|Warp|Hyper/) return 0
  if (t ~ /[Cc]laude|[Cc]odex|[Aa]ider|[Cc]ursor-agent/) return 1
  return 0
}
AWK
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
      SELECT 'W', datetime(startedAt,'localtime'), applicationName, COALESCE(windowTitle,'')
      FROM (SELECT id, startedAt, applicationName, windowTitle
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
                -v excl="$(remynd_exclude_pattern)" \
                -v skip_agent="$(remynd_config_get exclude_agent_ui 1)" '
'"$(_remynd_redact_awk)"'
'"$(_remynd_exclude_awk)"'
'"$(_remynd_agentui_awk)"'
    BEGIN { chars = 0; app = ""; wtitle = ""; lastapp = ""; truncated = 0
            deferred = 0; excluded = 0; selfcap = 0
            n_ex = split(excl, ex_list, ",") }
    {
      if ($1 == "W") { app = $3; wtitle = $4; next }
      if ($1 != "O") next
      if (is_excluded(app)) { excluded++; next }
      if (is_agent_ui(app, wtitle)) { selfcap++; next }

      # Dedupe on normalizedText AND on the rendered text. The recorder can
      # produce two rows whose normalizedText differs by a spinner glyph or a
      # cursor while the visible text is identical — same information, twice.
      key = $4
      if (key == "") key = $3
      if (key in seen) next
      seen[key] = 1

      # Redact FIRST, then dedupe on the text as it will actually be
      # delivered. Deduping on the raw text lets two rows that differ only in
      # a redacted secret both through, printing the same line twice.
      text = $3
      if (text == "") next
      if (doredact == 1) text = redact(text)
      if (text in shown) next
      shown[text] = 1

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
      if (selfcap > 0)
        printf "\n  (%d lines skipped: your coding agent UI, which the agent already has)\n", selfcap
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

    # Lead with WHAT, not WHERE. "Google Chrome 34m" is an accounting answer;
    # the subject lives in the window title.
    local wlo whi acts
    wlo="$(remynd_id_at_time "$db" FocusedWindow startedAt "$hours_cut")"
    whi="$(remynd_max_window_id "$db")"; whi=$(( whi + 1 ))
    acts="$(remynd_activity_rollup "$db" "$wlo" "$whi" 8)"
    [ -n "$acts" ] && { echo "## What you've been working on (last 2h)"; echo "$acts"; echo; }

    apps="$(remynd_app_rollup "$db" "$hours_cut")"
    [ -n "$apps" ] && { echo "## Time by app"; echo "$apps"; echo; }

    wins="$(remynd_window_trail "$db" "$hours_cut")"
    [ -n "$wins" ] && { echo "## Recently open"; echo "$wins"; echo; }

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
      SELECT 'W', datetime(startedAt,'localtime'), applicationName, COALESCE(windowTitle,'') FROM FocusedWindow
      WHERE id > $last_win AND applicationName IS NOT NULL AND applicationName != '' AND applicationName NOT IN ('loginwindow','ScreenSaverEngine','Window Server','WindowServer')
      ORDER BY id ASC;"
    remynd_sql "$db" "
      SELECT 'O', datetime(firstSeenAt,'localtime'), REPLACE(REPLACE(displayText, char(10), ' '), char(13), ' '), normalizedText
      FROM OCRTextSegment WHERE id > $last_ocr ORDER BY id ASC;"
  } | LC_ALL=C /usr/bin/sort -t"$REMYND_FS" -k2,2 -s |
  /usr/bin/awk -F"$REMYND_FS" -v budget="$budget_tokens" -v doredact="$redact" \
                -v excl="$(remynd_exclude_pattern)" \
                -v skip_agent="$(remynd_config_get exclude_agent_ui 1)" '
'"$(_remynd_redact_awk)"'
'"$(_remynd_exclude_awk)"'
'"$(_remynd_agentui_awk)"'
    BEGIN { chars = 0; app = ""; wtitle = ""; lastapp = ""; truncated = 0
            deferred = 0; excluded = 0; selfcap = 0
            n_ex = split(excl, ex_list, ",") }
    {
      if ($1 == "W") { app = $3; wtitle = $4; next }
      if ($1 != "O") next
      if (is_excluded(app)) { excluded++; next }
      if (is_agent_ui(app, wtitle)) { selfcap++; next }
      key = $4; if (key == "") key = $3
      if (key in seen) next
      seen[key] = 1
      # Redact FIRST, then dedupe on the text as it will actually be
      # delivered. Deduping on the raw text lets two rows that differ only in
      # a redacted secret both through, printing the same line twice.
      text = $3
      if (text == "") next
      if (doredact == 1) text = redact(text)
      if (text in shown) next
      shown[text] = 1
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
      if (selfcap > 0)
        printf "\n  (%d lines skipped: your coding agent UI, which the agent already has)\n", selfcap
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

# ---------------------------------------------------------------------------
# Activity rollup — what you were DOING, not which app you were in.
#
# "Google Chrome 536m" is an accounting answer to a question nobody asked.
# The subject lives in the window title, so this ranks normalised titles by
# dwell time instead of ranking apps.
#
# Normalisation matters more than it looks: a Terminal running Claude Code
# re-titles itself every frame with a different spinner glyph, so one stretch
# of work fragments into a dozen rows that each look minor. Collapsing those
# turns three 19-minute rows into one 87-minute activity.
# ---------------------------------------------------------------------------
_remynd_title_awk() {
  cat <<'AWK'
function norm_title(t) {
  gsub(/^\([0-9,]+\)[ ]*/, "", t)                 # (1) notification counts
  gsub(/\([0-9][0-9,]*\)/, "", t)                 # Inbox (35,979)
  gsub(/[✳✻✽◐◑◒◓●○◉◍◌⏺⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/, "", t)      # spinner frames
  gsub(/[◂▸►◄]/, " ", t)                          # progress arrows
  gsub(/[ ]+[-—][ ]+[0-9]+[x×][0-9]+[ ]*$/, "", t)  # terminal geometry
  gsub(/[ ]+[-—][ ]+(Google Chrome|Safari|Mozilla Firefox|Arc|Microsoft Edge)[ ]*$/, "", t)
  gsub(/^[A-Za-z0-9_.-]+[ ]+[-—][ ]+/, "", t)     # leading shell username
  gsub(/[ ]*[-—][ ]*caffeinate[ ]*/, " ", t)      # caffeinate wrapper
  gsub(/[\t ]+/, " ", t)
  sub(/^ +/, "", t); sub(/ +$/, "", t)
  sub(/[ ]*[-—|][ ]*$/, "", t)
  return t
}
AWK
}

# remynd_activity_rollup <db> <lo_id> <hi_id> [limit]
# Ranks what the user was actually doing, by minutes, across apps.
remynd_activity_rollup() {
  local db="$1" lo="$2" hi="$3" limit="${4:-14}"
  remynd_sql "$db" "
    SELECT CAST(SUM(MAX(0, strftime('%s', COALESCE(endedAt, startedAt)) - strftime('%s', startedAt))) AS INT) secs,
           applicationName, windowTitle
    FROM FocusedWindow
    WHERE id >= $lo AND id < $hi
      AND windowTitle IS NOT NULL AND windowTitle != ''
      AND applicationName NOT IN ('loginwindow','ScreenSaverEngine','WindowServer')
    GROUP BY applicationName, windowTitle;" |
  /usr/bin/awk -F"$REMYND_FS" -v limit="$limit" '
'"$(_remynd_title_awk)"'
    function canon(t,   c) {
      c = tolower(t)
      gsub(/[-—|:,]/, " ", c)
      gsub(/[ ]+/, " ", c)
      sub(/^ +/, "", c); sub(/ +$/, "", c)
      return c
    }
    {
      t = norm_title($3)
      if (t == "") next
      c = canon(t)
      if (c == "") next
      secs[c] += $1
      # Keep the shortest human title seen for this activity as the label.
      if (!(c in label) || length(t) < length(label[c])) label[c] = t
      if (!(c in app)) app[c] = $2
    }
    END {
      # Merge activities whose canonical key is a prefix of another: a window
      # that appends detail ("Carla | Messages" -> "Carla | Messages - Ali,
      # Eric, ...") is the same activity, not a separate one.
      n = 0
      for (c in secs) { n++; ks[n] = c }
      for (i = 1; i <= n; i++)
        for (j = 1; j <= n; j++) {
          if (i == j || secs[ks[i]] == -1 || secs[ks[j]] == -1) continue
          # Only merge within the same app, and never let a very short generic
          # title act as the absorbing prefix — a Finder window called "ReMynd"
          # is not the same activity as a Terminal running the landing page.
          if (app[ks[i]] != app[ks[j]]) continue
          if (length(ks[i]) < 10) continue
          if (length(ks[i]) < length(ks[j]) && index(ks[j], ks[i] " ") == 1) {
            secs[ks[i]] += secs[ks[j]]
            secs[ks[j]] = -1
          }
        }
      n = 0
      for (c in secs) { if (secs[c] >= 0) { n++; keys[n] = c } }
      # simple descending sort by seconds
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (secs[keys[j]] > secs[keys[i]]) { tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp }
      shown = 0
      for (i = 1; i <= n && shown < limit; i++) {
        s = secs[keys[i]]
        if (s < 120) continue          # under two minutes is noise, not an activity
        h = int(s / 3600); m = int((s % 3600) / 60)
        if (h > 0) dur = sprintf("%dh%02dm", h, m); else dur = sprintf("%dm", m)
        printf "  %-7s %s  (%s)\n", dur, label[keys[i]], app[keys[i]]
        shown++
      }
    }'
}

# Sites visited in a window, from real URLs.
#
# An earlier version guessed the site from the tail of the window title. That
# produced "control", "jng" and "ready." as sites, which is worse than saying
# nothing. If the browser extension isn't installed, WebURLVisit is empty and
# this prints nothing at all — an honest blank beats confident noise.
remynd_domains() {
  local db="$1" lo="$2" hi="$3" limit="${4:-10}"
  local wlo whi
  wlo="$(remynd_sql "$db" "SELECT COALESCE(MIN(id),0) FROM WebURLVisit;")"
  whi="$(remynd_sql "$db" "SELECT COALESCE(MAX(id),0) FROM WebURLVisit;")"
  [ "${whi:-0}" -gt 0 ] || return 0

  remynd_sql "$db" "
    SELECT u.url, COUNT(*) n
    FROM (SELECT id, webURLId, navigatedToAt FROM WebURLVisit ORDER BY id DESC LIMIT 40000) v
    JOIN WebUrl u ON u.id = v.webURLId
    WHERE v.navigatedToAt >= (SELECT datetime(startedAt) FROM FocusedWindow WHERE id >= $lo LIMIT 1)
      AND v.navigatedToAt <  (SELECT datetime(startedAt) FROM FocusedWindow WHERE id >= $hi LIMIT 1)
    GROUP BY u.url;" |
  /usr/bin/awk -F"$REMYND_FS" -v limit="$limit" '"'"'
    {
      d = $1
      sub(/^https?:\/\//, "", d)
      sub(/\/.*$/, "", d)
      sub(/^www\./, "", d)
      if (d == "" || d !~ /\./) next
      hits[d] += $2
    }
    END {
      n = 0
      for (d in hits) { n++; k[n] = d }
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (hits[k[j]] > hits[k[i]]) { t = k[i]; k[i] = k[j]; k[j] = t }
      out = ""
      for (i = 1; i <= n && i <= limit; i++) out = out (i > 1 ? " . " : "  ") k[i]
      if (out != "") print out
    }'"'"'
}
