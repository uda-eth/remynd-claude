#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ReMynd × your coding agent — one-command setup
#
#   bash <(curl -fsSL https://remyndai.com/claude/install.sh)
#
# Wires your ReMynd screen history into Claude Code and/or Codex as always-on
# context: every session starts knowing what you were working on, and stays
# current as you work.
#
# Requires: macOS, ReMynd. Nothing else — no jq, no Homebrew, no Python.
# Writes only inside ~/.remynd-sync, ~/.claude and ~/.codex. Never touches
# your ReMynd data, which it opens read-only.
#
# Safe to re-run. `install.sh --uninstall` removes everything it added.
# ---------------------------------------------------------------------------
set -euo pipefail

HOME_DIR="$HOME"
SYNC_DIR="$HOME_DIR/.remynd-sync"
CORE_DIR="$SYNC_DIR/core"
BIN_DIR="$SYNC_DIR/bin"
CLAUDE_DIR="$HOME_DIR/.claude"
CODEX_DIR="$HOME_DIR/.codex"
REPO_RAW="https://raw.githubusercontent.com/uda-eth/remynd-claude/main"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

CORE_FILES="remynd remynd-lib.sh remynd-digest.sh remynd-refresh.sh remynd-session-hook.sh remynd-delta-hook.sh remynd-settings.sh"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  say "Removing ReMynd sync…"
  if [ -f "$CLAUDE_DIR/settings.json" ] && [ -f "$CORE_DIR/remynd-settings.sh" ]; then
    if NEW="$(bash "$CORE_DIR/remynd-settings.sh" remove "$CLAUDE_DIR/settings.json" 2>/dev/null)" && [ -n "$NEW" ]; then
      cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.remynd-backup"
      printf '%s\n' "$NEW" > "$CLAUDE_DIR/settings.json"
      ok "Removed the ReMynd hooks from Claude Code settings"
    else
      warn "Could not edit $CLAUDE_DIR/settings.json — remove the remynd-sync-hook entries by hand."
    fi
  fi
  rm -rf "$CLAUDE_DIR/skills/remynd"
  if [ -f "$CODEX_DIR/AGENTS.md" ]; then
    /usr/bin/sed -i '' '/<!-- remynd:start -->/,/<!-- remynd:end -->/d' "$CODEX_DIR/AGENTS.md" 2>/dev/null || true
    ok "Removed the ReMynd block from ~/.codex/AGENTS.md"
  fi
  rm -rf "$SYNC_DIR"
  ok "Removed $SYNC_DIR"
  say "Done. Your ReMynd recordings were not touched."
  exit 0
fi

[ "$(uname)" = "Darwin" ] || die "ReMynd is macOS-only, and so is this."
[ -x /usr/bin/sqlite3 ] || die "/usr/bin/sqlite3 is missing. That ships with macOS — something is wrong with this system."

# ---------------------------------------------------------------------------
# 1. Install the core
# ---------------------------------------------------------------------------
mkdir -p "$CORE_DIR" "$BIN_DIR" "$SYNC_DIR/sessions"

SRC_DIR=""
_self="${BASH_SOURCE[0]:-}"
if [ -n "$_self" ] && [ -f "$_self" ]; then
  _d="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)"
  [ -d "$_d/plugins/remynd/core" ] && SRC_DIR="$_d/plugins/remynd/core"
fi

if [ -n "$SRC_DIR" ]; then
  say "Installing from this checkout"
  for f in $CORE_FILES; do cp "$SRC_DIR/$f" "$CORE_DIR/$f"; done
else
  say "Downloading ReMynd sync"
  for f in $CORE_FILES; do
    curl -fsSL "$REPO_RAW/plugins/remynd/core/$f" -o "$CORE_DIR/$f" \
      || die "could not download $f — check your connection and try again."
  done
fi
chmod +x "$CORE_DIR"/* 2>/dev/null || true
ln -sf "$CORE_DIR/remynd" "$BIN_DIR/remynd"

# ---------------------------------------------------------------------------
# 2. Config (PRD §5.6, §5.8 defaults)
# ---------------------------------------------------------------------------
if [ ! -f "$SYNC_DIR/config" ]; then
  cat > "$SYNC_DIR/config" <<'CFG'
# ReMynd sync configuration. Edit freely; the hooks read this on every run.

enabled=1

# Which ReMynd data to read. Blank means auto-detect, preferring the
# production app over a development build. Set an absolute profile path to pin
# it — useful if you run a dev build and want that one instead.
#   profile=/Users/you/Library/Application Support/Move37/ReMynd-<id>
profile=

# Credential-shaped strings (API keys, tokens, card numbers, password= lines)
# are replaced before anything is sent to your agent. Set to 0 to send
# absolutely everything untouched.
redact_credentials=1

# Session-start snapshot: how much verbatim screen text to include, and the
# ceiling for the whole digest.
# How much verbatim screen text to include at session start, and the ceiling
# for the whole opening digest. Small on purpose: the structural summary is
# what carries meaning, and the agent can pull detail on demand with /remynd.
# Raising ocr_minutes to 30 costs ~8k tokens per session for little added
# accuracy (measured), so keep this low unless you want the firehose.
session_ocr_minutes=5
session_budget_tokens=1500

# Per-session ceiling for topping up context, as a percentage of the agent's
# context window. Past it, updates fall back to activity headlines and say so.
session_budget_pct=35
context_window_tokens=200000

# Largest single top-up, and the floor below which an update is noise, not news.
delta_cap_tokens=6000
min_delta_tokens=50

# Your coding agent's own terminal UI gets recorded like everything else, and
# feeding it back is a mirror: the assistant re-reads its own previous answers,
# OCR'd and line-wrapped. It already has that conversation, so this is skipped
# by default. Set to 0 to include it.
exclude_agent_ui=1

# Apps and domains that ReMynd records but that must never reach your agent.
# Comma-separated, case-insensitive, matched against the focused app name.
# Empty means everything is sent, which is the default.
#   sync_exclude=1Password,Bitwarden,Banking
sync_exclude=
CFG
  ok "Wrote $SYNC_DIR/config"
else
  ok "Kept your existing $SYNC_DIR/config"
fi

# ---------------------------------------------------------------------------
# 3. Which agents?
# ---------------------------------------------------------------------------
WANT_CLAUDE=0; WANT_CODEX=0
case "${1:-}" in
  --claude) WANT_CLAUDE=1 ;;
  --codex)  WANT_CODEX=1 ;;
  --all)    WANT_CLAUDE=1; WANT_CODEX=1 ;;
  *)
    [ -d "$CLAUDE_DIR" ] && WANT_CLAUDE=1
    [ -d "$CODEX_DIR" ]  && WANT_CODEX=1
    ;;
esac

if [ "$WANT_CLAUDE" -eq 0 ] && [ "$WANT_CODEX" -eq 0 ]; then
  warn "Neither ~/.claude nor ~/.codex found — no agent to wire up."
  warn "Install Claude Code (https://claude.com/claude-code) or Codex, then re-run."
  warn "The 'remynd' command still works: $BIN_DIR/remynd"
fi

# ---------------------------------------------------------------------------
# 4. Claude Code — SessionStart + UserPromptSubmit hooks
#
# settings.json is edited with sqlite3's JSON1 functions rather than jq, since jq is absent on
# macOS 14 and 15 and requiring it would dead-end those users. See remynd-settings.sh.
# ---------------------------------------------------------------------------
if [ "$WANT_CLAUDE" -eq 1 ]; then
  SETTINGS="$CLAUDE_DIR/settings.json"
  mkdir -p "$CLAUDE_DIR"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

  cp "$SETTINGS" "$SETTINGS.remynd-backup"

  if NEW="$(bash "$CORE_DIR/remynd-settings.sh" install "$SETTINGS" 2>/dev/null)" && [ -n "$NEW" ]; then
    printf '%s\n' "$NEW" > "$SETTINGS"
    ok "Claude Code: SessionStart + UserPromptSubmit hooks installed"
  else
    cp "$SETTINGS.remynd-backup" "$SETTINGS"
    die "could not update $SETTINGS safely — restored your backup, nothing changed.
Is it valid JSON? Check with: sqlite3 :memory: \"SELECT json_valid(readfile('$SETTINGS'));\""
  fi

  SKILL_DIR="$CLAUDE_DIR/skills/remynd"
  mkdir -p "$SKILL_DIR"
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/../skills/remynd/SKILL.md" ]; then
    cp "$SRC_DIR/../skills/remynd/SKILL.md" "$SKILL_DIR/SKILL.md"
  else
    curl -fsSL "$REPO_RAW/plugins/remynd/skills/remynd/SKILL.md" -o "$SKILL_DIR/SKILL.md" 2>/dev/null || true
  fi
  [ -f "$SKILL_DIR/SKILL.md" ] && ok "Claude Code: /remynd skill installed"
fi

# ---------------------------------------------------------------------------
# 5. Codex — AGENTS.md block + the remynd CLI
#
# Codex has no per-prompt hook, so it gets fresh-at-session-start (a
# regenerated AGENTS.md block) plus fresh-on-demand (the remynd command,
# which Codex can run itself). PRD §5.9.
# ---------------------------------------------------------------------------
if [ "$WANT_CODEX" -eq 1 ]; then
  mkdir -p "$CODEX_DIR"
  AGENTS="$CODEX_DIR/AGENTS.md"
  [ -f "$AGENTS" ] || : > "$AGENTS"
  /usr/bin/sed -i '' '/<!-- remynd:start -->/,/<!-- remynd:end -->/d' "$AGENTS" 2>/dev/null || true
  cat >> "$AGENTS" <<'BLOCK'
<!-- remynd:start -->
## ReMynd — the user's own screen history

This Mac runs ReMynd, which records the screen, OCRs every frame, and keeps it locally. The user's
past is therefore searchable, and you can read it with the `remynd` command (read-only):

```
remynd now                     what they're doing right now
remynd recent 60               digest of the last 60 minutes
remynd search "<query>"        full-text search everything they've seen
remynd day 2026-08-13          reconstruct a specific day
remynd apps 7                  where their time went
remynd text "<from>" "<to>"    verbatim screen text in a time range
remynd status                  freshness and whether redaction is on
```

If `remynd` is not on PATH, use `~/.remynd-sync/bin/remynd`.

**Use it whenever a question is about what the user did, saw, read or worked on** — "what was I
doing on Tuesday", "find that thing I read about X", "how much time did I spend on Y". Search first
to get a timestamp, then `remynd text` around it to read what was on screen.

Times shown by `remynd` are local — it converts them for you. The database underneath stores UTC, so
querying `app.db` directly will silently shift every window by the UTC offset. Use the command.

A timestamp is when the user SAW something, not when it happened — an inbox reminder about a meeting
is stamped when it appeared on screen. And trust the activity timeline (`remynd day` / `remynd text`)
over clock times printed inside a calendar grid or email header, which may be in another timezone or
belong to a different event.

OCR is imperfect, so expect some garbled words and interface chrome mixed in.
Gaps mean the Mac was asleep, locked, or recording was paused — not that the user did nothing.
Credential-shaped strings appear as `<redacted>`; that is the redaction working.
<!-- remynd:end -->
BLOCK
  ok "Codex: ReMynd block added to ~/.codex/AGENTS.md"
fi

# ---------------------------------------------------------------------------
# 6. PATH + first refresh
# ---------------------------------------------------------------------------
PATH_LINE='export PATH="$HOME/.remynd-sync/bin:$PATH"'
for rc in "$HOME_DIR/.zshrc" "$HOME_DIR/.bashrc"; do
  [ -f "$rc" ] || continue
  grep -qF '.remynd-sync/bin' "$rc" 2>/dev/null || {
    printf '\n# ReMynd\n%s\n' "$PATH_LINE" >> "$rc"
    ok "Added remynd to your PATH in $(basename "$rc")"
  }
done

echo
if profile="$("$CORE_DIR/remynd" status 2>/dev/null | /usr/bin/sed -n 's/^Profile: *//p')" && [ -n "$profile" ]; then
  ok "Found your ReMynd recordings"
  "$CORE_DIR/remynd" refresh >/dev/null 2>&1 || true
  "$CORE_DIR/remynd" status | /usr/bin/sed 's/^/    /'
else
  warn "No ReMynd recordings found yet."
  warn "Setup is in place and activates on its own once ReMynd has recorded for a while."
fi

echo
say "Done."
[ "$WANT_CLAUDE" -eq 1 ] && echo "    Claude Code: start a new session (or /clear) — your context loads automatically."
[ "$WANT_CODEX" -eq 1 ]  && echo "    Codex: start a new session — it will know to use the remynd command."
echo "    Anywhere:    remynd search \"something you saw\""
echo
echo "    Everything is read-only and local. Turn it off any time with:"
echo "      $SYNC_DIR/config  →  enabled=0"
echo "    Or remove it entirely:  bash <(curl -fsSL $REPO_RAW/install.sh) --uninstall"
