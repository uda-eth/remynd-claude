#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# UserPromptSubmit hook — the always-hot engine (PRD §5.3).
#
#   nothing new            -> exit 0, no output, zero tokens
#   trivial new            -> exit 0, no output (MIN_DELTA suppresses noise)
#   session budget spent   -> structural only, said once, never silently
#   otherwise              -> the delta, OCR body text included
#
# There is deliberately NO time-based rate limit. A 90s floor would let a user
# prompting every 30s run three prompts behind, which contradicts the whole
# point. Delta size is proportional to elapsed time, so injecting often is
# already cheap — the floor is a minimum *size*, not a minimum interval.
# ---------------------------------------------------------------------------
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/remynd-digest.sh" 2>/dev/null || exit 0

# The hook payload carries session_id. Extract it without jq.
#
# Read with a timeout rather than a bare `cat`: if the caller never closes the
# pipe, an unconditional read blocks forever and the user's prompt hangs behind
# it. Two seconds is far more than a hook payload ever needs, and on timeout we
# simply fall back to the environment.
payload=""
IFS= read -r -t 2 -d '' payload 2>/dev/null || true
sid="$(printf '%s' "$payload" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-default}"

[ "$(remynd_config_get enabled 1)" = "1" ] || exit 0

profile="$(remynd_find_profile)" || exit 0
db="$(remynd_db_path "$profile")"
[ -f "$db" ] || exit 0

state="$(remynd_state_dir)"
mkdir -p "$state/sessions" 2>/dev/null
wm="$state/sessions/$sid.wm"

last_ocr=0; last_win=0; spent=0; noted_exhausted=0
if [ -f "$wm" ]; then
  # shellcheck disable=SC1090
  last_ocr="$(/usr/bin/sed -n 's/^last_ocr_id=//p'    "$wm" | tail -1)"
  last_win="$(/usr/bin/sed -n 's/^last_window_id=//p' "$wm" | tail -1)"
  spent="$(/usr/bin/sed -n 's/^spent_tokens=//p'      "$wm" | tail -1)"
  noted_exhausted="$(/usr/bin/sed -n 's/^noted_exhausted=//p' "$wm" | tail -1)"
fi
[ -n "$last_ocr" ] || last_ocr=0
[ -n "$last_win" ] || last_win=0
[ -n "$spent" ] || spent=0
[ -n "$noted_exhausted" ] || noted_exhausted=0

head_ocr="$(remynd_max_ocr_id "$db")"
head_win="$(remynd_max_window_id "$db")"
[ -n "$head_ocr" ] || exit 0

# First prompt of a session that never saw SessionStart: adopt the head and
# stay quiet, rather than dumping the entire database.
if [ ! -f "$wm" ]; then
  { echo "last_ocr_id=$head_ocr"; echo "last_window_id=$head_win"
    echo "spent_tokens=0"; echo "started_at=$(/bin/date +%s)"; } > "$wm" 2>/dev/null
  exit 0
fi

# Nothing captured since last time — silent, zero tokens.
[ "$head_ocr" -le "$last_ocr" ] && [ "$head_win" -le "$last_win" ] && exit 0

budget_pct="$(remynd_config_get session_budget_pct 35)"
ctx_window="$(remynd_config_get context_window_tokens 200000)"
delta_cap="$(remynd_config_get delta_cap_tokens 6000)"
min_delta="$(remynd_config_get min_delta_tokens 50)"
redact="$(remynd_config_get redact_credentials 1)"

session_budget=$(( ctx_window * budget_pct / 100 ))

if [ "$spent" -ge "$session_budget" ]; then
  # Budget exhausted: structural only, and say so exactly once.
  apps="$(remynd_apps_since_id "$db" "$last_win")"
  { echo "last_ocr_id=$head_ocr"; echo "last_window_id=$head_win"
    echo "spent_tokens=$spent"; echo "noted_exhausted=1"; } > "$wm" 2>/dev/null
  [ -n "$apps" ] || exit 0
  if [ "$noted_exhausted" = "1" ]; then
    printf '# ReMynd — since we last spoke\n\n%s\n' "$apps" | remynd_hook_payload UserPromptSubmit
  else
    printf '# ReMynd — since we last spoke\n\n%s\n\n_ReMynd has used its context budget for this session, so it is now sending activity headlines only. The captured text is still there — ask `/remynd` for it._\n' "$apps" | remynd_hook_payload UserPromptSubmit
  fi
  exit 0
fi

remaining=$(( session_budget - spent ))
[ "$remaining" -lt "$delta_cap" ] && delta_cap="$remaining"

delta="$(remynd_digest_delta_id "$db" "$last_ocr" "$last_win" "$delta_cap" "$redact" 2>/dev/null)" || {
  { echo "last_ocr_id=$head_ocr"; echo "last_window_id=$head_win"
    echo "spent_tokens=$spent"; echo "noted_exhausted=$noted_exhausted"; } > "$wm" 2>/dev/null
  exit 0
}

tokens=$(( ${#delta} / 4 ))

# MIN_DELTA — noise, not news. Advance the watermark anyway so the trivia
# accumulates into the next delta instead of being re-examined every prompt.
if [ "$tokens" -lt "$min_delta" ]; then
  exit 0
fi

{ echo "last_ocr_id=$head_ocr"; echo "last_window_id=$head_win"
  echo "spent_tokens=$(( spent + tokens ))"; echo "noted_exhausted=$noted_exhausted"; } > "$wm" 2>/dev/null

printf '%s' "$delta" | remynd_hook_payload UserPromptSubmit
exit 0
