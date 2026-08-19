#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SessionStart hook — the baseline snapshot (PRD §5.2).
#
# Deliberately NOT gated on `source`, so it also fires on resume, clear and
# post-compact. Gating on source=startup would let a /compact silently discard
# the user's context and leave the rest of the session running blind.
#
# Fails silent (exit 0, no output) whenever anything is missing: no ReMynd, no
# recordings yet, sync disabled. A fresh install must never see an error.
# ---------------------------------------------------------------------------
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/remynd-digest.sh" 2>/dev/null || exit 0

cat >/dev/null 2>&1   # drain the hook payload on stdin; we don't need it here

[ "$(remynd_config_get enabled 1)" = "1" ] || exit 0

profile="$(remynd_find_profile)" || exit 0
db="$(remynd_db_path "$profile")"
[ -f "$db" ] || exit 0

budget="$(remynd_config_get session_budget_tokens 8000)"
minutes="$(remynd_config_get session_ocr_minutes 30)"
redact="$(remynd_config_get redact_credentials 1)"

digest="$(remynd_digest_full "$db" "$minutes" "$budget" "$redact" 2>/dev/null)" || exit 0
[ -n "$digest" ] || exit 0

# Seed this session's watermark at the current head, so the first delta only
# reports what happens from now on rather than re-sending the snapshot.
state="$(remynd_state_dir)"
mkdir -p "$state/sessions" 2>/dev/null
sid="${CLAUDE_SESSION_ID:-default}"
{
  echo "last_ocr_id=$(remynd_max_ocr_id "$db")"
  echo "last_window_id=$(remynd_max_window_id "$db")"
  echo "spent_tokens=$(( ${#digest} / 4 ))"
  echo "started_at=$(/bin/date +%s)"
} > "$state/sessions/$sid.wm" 2>/dev/null

# Refresh the shared cache in the background for other consumers (Codex, CLI).
( "$_here/remynd-refresh.sh" >/dev/null 2>&1 & ) 2>/dev/null

printf '%s' "$digest" | remynd_hook_payload SessionStart
exit 0
