# PRD — ReMynd × Claude Code: always-hot context

**Status:** BUILT — M1–M6 + M8 implemented and passing; 30/30 acceptance checks green (§14)
**Owner:** Tony Udotong
**Date:** 2026-08-19
**Target:** ReMynd **production release** (1.2.9397 line) — not dev builds, not the brain feature branches.
**Agents:** Claude Code (primary), Codex (secondary — see §5.9)

---

## 1. Problem

A ReMynd user should be able to open Claude Code and have it already know what they have been
working on — and stay knowing it as the session runs. Today that does not happen for a single
production user.

The integration we ship (`remyndai.com/claude/install.sh` → SessionStart hook + `/brain` skill) is
built entirely on the Second Brain vault. **The Second Brain does not exist in the production
release.** It is also stale even where a vault does exist: it reads paths the 2026-07-22 vault
migration removed.

And even when it did work, it was *cold*: `SessionStart` fires once. A four-hour session never
learns anything the user did after minute zero.

## 2. Evidence (verified 2026-08-19)

| Check | Result |
|---|---|
| `strings /Applications/ReMynd.app/Contents/MacOS/ReMynd \| grep -ci SecondBrain` | **0** |
| same against `RewindKit.framework` | **0** |
| `git ls-tree -r origin/development \| grep -i secondbrain` | **0 files** (same for `main`, `release`) |
| `bash ~/.claude/remynd/session-context.sh \| wc -c` | **0 bytes** — gates on `CRITICAL_FACTS.md`, renamed to `hot.md` on 2026-07-22 |
| `/brain` SKILL.md paths | `wiki/entities/{people,apps,domains}`, `wiki/daily/` — all removed by the migration |
| `ClaudeCodeSection` in `SettingsIntegrationsView.swift` | present on `design/liquid-glass-rollout`, `feature/second-brain-weights`, `feature/integrations`; **absent from `development`** |

Conclusion: the vault is not a production data source, and will not be until the
`feature/second-brain-weights` stack merges and ships. This PRD does not wait for that.

## 3. What production actually has

The production `app.db` is a richer source than the vault, and it is **continuously written by the
recorder** — there is no synthesis pass to lag behind, so a live query is never stale by construction.

Measured against the real production profile (1.4 GB):

| Table | Contents |
|---|---|
| `OCRTextSegment` + `OCRTextSegment_FTS` | 873,465 rows; full-text search over everything on screen |
| `FocusedWindow` | `applicationName`, `windowTitle`, `startedAt`/`endedAt` — denormalized, no join needed |
| `WebURLVisit` + `WebUrl` | URL, title, focus duration, transition |
| `TaggedMoment`, `ApplicationRun`, `UserInputEventsBy10Min`, `HIDEvent` | session/idle/activity signals |
| `FrameOCR_FTS` / `OCRText_FTS` | legacy OCR path — some installs' earliest data lives here |

Query cost on that DB:

- app-usage rollup since a cutoff: **275 ms cold / 29 ms warm** (no index on `startedAt` — full scan)
- recent-window tail (`ORDER BY id DESC LIMIT 10`): **10 ms**

Fast enough to drive a per-prompt freshness check, but the cold number is why the design puts a
cache in front of the hooks rather than querying inline (§5.1).

Freshness signal: `max(mtime(app.db), mtime(app.db-wal))`. The `-wal` sidecar is mandatory —
under WAL the recorder's writes land there and `app.db`'s own mtime can sit unchanged for minutes.

## 4. Goals / non-goals

**Goals**
1. Works on a stock production ReMynd install, today, with no unmerged branches.
2. Context is **hot**: never more than one prompt behind what the user is doing.
3. Costs nothing when nothing happened — an idle session injects zero tokens.
4. Installable and updatable from the Integrations tab in one click.
5. **Full fidelity.** A user who turns this on gets everything ReMynd captured, OCR body text
   included — not a sanitized summary of it.
6. Read-only. Never writes to ReMynd data.

**Non-goals**
- Shipping the Second Brain to production (separate, larger effort).
- Any cloud component. Everything is local; the only egress is the user's own Claude requests.
- Windows/Linux. macOS only, like ReMynd.
- Deciding for the user what is too sensitive to sync. They opted in; they get everything (§5.8).

## 5. Architecture

Four pieces. The hooks stay dumb and fast; a refresher does the work out of band.

### 5.1 Refresher (out of band)

`remynd-refresh.sh` queries `app.db` read-only and writes two files under
`~/.claude/remynd/state/`:

- `context.md` — the current digest (§5.4)
- `sync.json` — `{ db_mtime, generated_at, last_event_at, profile }`

It runs detached, and only when the DB's mtime has advanced past `sync.json.db_mtime`. This keeps
the 275 ms cold query off the prompt path — the hooks only ever `cat` a small file.

### 5.2 SessionStart hook — the baseline

Emits the full digest as `additionalContext`. Deliberately **not** gated on `source`, so it also
fires on `resume`, `clear`, and post-`compact` — otherwise a compaction silently discards the
user's context and the session runs blind for the rest of its life.

Budget: **≤ 8k tokens** — a structural digest of the session-so-far plus full OCR body text for the
**last 30 minutes**, so the session opens knowing not just where the user was but what they were
reading. Governed by §5.6.

### 5.3 UserPromptSubmit hook — the always-hot engine

This is the part that answers "shouldn't be stale when new ReMynd context captures".

```
watermark = ~/.claude/remynd/state/<session_id>.watermark    # last event timestamp injected
if (db_mtime <= watermark.db_mtime) exit 0                   # nothing captured — silent, 0 tokens
delta = activity strictly after watermark.last_event_at
if (delta is empty) exit 0
if (tokens(delta) < MIN_DELTA) exit 0                        # ~50 tokens of noise, not news
emit delta; watermark := now
```

Properties that matter:
- **Silent when idle.** No output means no tokens. A session where the user only talks to Claude
  costs exactly as much as it does today.
- **Delta, not re-send.** Only activity newer than the last injection — structural anchors *and*
  the OCR body text captured in that gap. A typical 1–3 minute gap is 1.5–4.5k tokens (§5.6);
  per-delta cap 6k, past which it defers the oldest text and names what it deferred.
- **Per-session watermark**, keyed on `session_id` from the hook payload, so two concurrent Claude
  Code windows don't starve each other.
- **No time-based rate limit.** An earlier draft floored injections at 90 s apart. That directly
  contradicts goal 2 — at a 90 s floor, a user prompting every 30 s runs up to three prompts behind.
  It also solved a problem that does not exist: the delta is *self-limiting*, because its size is
  proportional to elapsed time. Ten seconds of capture is ~140 tokens; the cost of injecting often is
  already near zero. The floor is therefore a **minimum delta** (`MIN_DELTA`, ~50 tokens), which
  suppresses noise without ever putting the context behind.

### 5.4 The digest format

Two tiers in one format, so the model reads the same shape whether it is the opening snapshot or a
mid-session delta:

```
# ReMynd — your recent activity (live, as of 14:32)
## Right now
Terminal — "rewind — claude" (12m)
## Last 2 hours
Google Chrome 34m · Terminal 28m · Xcode 9m
## What you were reading
github.com/move37-com/rewind — "PR #2158 …"

## Since we last spoke                      <- delta injections
14:28  Xcode — SettingsIntegrationsView.swift
       > private struct ClaudeCodeSection: View {
       >     @StateObject private var setup = ClaudeCodeSetup()
       > …
14:30  Chrome — "WAL mode - SQLite"
       > Write-ahead logging … readers do not block writers …
```

**OCR body text is included.** The structural line (time, app, title) anchors each entry; the
captured screen text follows it. Nothing is summarized away and nothing is withheld — the tiering
is about *when* text arrives, not *whether* it does.

Processing applied to OCR text before injection, in order:
1. **Dedupe on `normalizedText`** within the window — the recorder re-observes the same on-screen
   string across frames. Measured: 11,510 segments → 6,186 (-43% tokens) with zero information lost.
2. **Group by capture surface**, so text arrives as coherent blocks rather than interleaved fragments.
3. **Chronological order**, with the structural anchor first.

No content filtering. See §5.6 for what happens when the budget runs out — it degrades by *deferring*
text to the skill, never by silently dropping it.

### 5.5 The skill

`/remynd` — on-demand deep retrieval, rewritten against the **production** schema:
FTS over `OCRTextSegment`, day reconstruction from `FocusedWindow`, browsing from
`WebURLVisit`+`WebUrl`, legacy `FrameOCR_FTS` fallback for old installs.

Vault-optional: if `SecondBrain/hot.md` exists (dev build today, production someday), the skill
layers it in. It is never required, and the skill must never gate on a vault file the way the
current one does.

### 5.6 Token budget governor

Full-fidelity OCR is affordable per prompt and expensive per session. Measured on the production
profile (2026-08-13, 23:00–00:00, one hour of real use):

| Payload | Segments | Chars | ≈ Tokens |
|---|---|---|---|
| Raw OCR body text | 11,510 | 346,452 | **~87k / hour** |
| Deduped on `normalizedText` | 6,186 | 196,362 | ~49k / hour |
| Deduped, fragments <25 chars dropped | 2,632 | 154,040 | ~39k / hour |

≈ **1,440 tokens per active minute** raw, ≈ **820 deduped**. Dedup is always applied, so 820 is the
rate that governs everything below. A 1–3 minute gap between prompts is a **0.8–2.5k token delta**.
A three-hour active session accumulates ~150k tokens — comfortable on a 1M context, fatal on 200k.

So the governor is per-session and context-aware, not a content filter:

```
SESSION_BUDGET = 35% of the session's context window     # tunable
per-delta cap  = 6k tokens                               # a long gap still lands
```

- Under budget → full OCR body text, deduped, in every delta.
- Delta exceeds the per-delta cap → most recent activity in full, older activity as structural lines
  plus an explicit pointer: `…14 more minutes captured — ask /remynd for the text`.
- Session budget exhausted → deltas fall back to structural-only, and say so, once. The text is
  never gone; it is one skill call away.

At 820 tokens per active minute, a 35% budget buys:

| Context window | Budget | Full-OCR runway |
|---|---|---|
| 1M | 350k tokens | **~7 active hours** |
| 200k | 70k tokens | **~85 active minutes** |

Both exceed a realistic working session before any deferral kicks in, which is the bar. The user is
never silently downgraded — every truncation states what was withheld and how to get it.

### 5.7 Profile detection — production first

Rewrite `remynd_find_profile`:
1. **Require** `Recordings/app.db`. Drop the `CRITICAL_FACTS.md` scoring entirely — that is the bug
   that killed the current hook.
2. Prefer non-dev bundles (`ReMynd-<uid>` over `ReMynd-dev-*`), per the production-only requirement.
3. Tie-break on freshest `app.db`/`-wal` mtime.
4. Allow `REMYND_PROFILE` env override for support.
5. Emit JSON without `jq` (§13.3) — the profile lookup and both hooks are dependency-free shell.

### 5.8 Privacy and the sync decision

The decision to sync happens **once, explicitly, in the Integrations tab**. It is the only gate.
Past it, the user gets everything ReMynd captured — OCR body text included. We do not second-guess
what they meant by yes.

What that means concretely:
- **Opt-in, never silent.** No install, no injection, until the user connects it.
- **Everything is in scope**, including screen text from any app ReMynd was recording.
- **What ReMynd never recorded cannot appear.** Production's capture controls are, in full:
  a global recording pause (`recordingPaused`), and `ignoreIncognitoBrowserWindows` — which
  **defaults to true**, so incognito browser windows are excluded out of the box. Both are stored in
  the `recorderPreferences` dictionary under the `ai.m37.screenomex` defaults domain.
- **Production has no per-app or per-domain exclusion list.** Verified 2026-08-19: the capture
  settings in `SettingsViewModel.swift` on `origin/development` are recording on/off, screenshot
  interval, call screenshot interval, capture-incognito, recording tone, tagging step — and nothing
  else. An earlier draft of this PRD claimed the sync would inherit an existing exclusion list. That
  was wrong; no such list exists.
- **So the sync provides one.** Because capture offers no per-app carve-out, the integration ships
  its own `sync_exclude` list — app bundle IDs and domains that are captured but never injected.
  It **defaults to empty**: the user asked for everything and gets everything. It exists so that a
  user who later wants to carve out one app has somewhere to do it, rather than being forced to
  choose between all and nothing.
- **The copy states it plainly**: connecting sends your captured screen activity, including text
  read off the screen, to your AI agent as part of your own requests. It goes nowhere else — no
  ReMynd server, no third party.
- **One-click disconnect** that stops injection immediately and removes local state.

**One flagged risk — decided.** "Everything" includes credentials that happen to be on screen —
API keys in a terminal, a password manager mid-reveal, a card number in a checkout form. Those land
in the agent's transcript and in the provider's logs. The mitigation is a *narrow* redaction pass
over credential-shaped strings only (`sk-…`, `ghp_…`, AWS keys, PAN-shaped digit runs) — roughly
0.1% of text volume. Everything else syncs untouched.

**Decided 2026-08-19 (Tony): `redact_credentials` defaults ON**, and remains a toggle the user can
turn off.

### 5.9 Agent adapters — Claude Code and Codex

The refresher, the digest, the governor and the SQL are **agent-agnostic**. Only the delivery is
per-agent, because the two agents expose different surfaces:

| | Claude Code | Codex |
|---|---|---|
| Per-session context | `SessionStart` hook | regenerated `~/.codex/AGENTS.md` |
| **Per-prompt freshness** | `UserPromptSubmit` hook — **push** | *no equivalent hook* |
| On-demand retrieval | `/remynd` skill | MCP tool (`mcp_servers` in `config.toml`) |

Claude Code can be pushed to every turn; Codex cannot. So Codex gets fresh-at-session-start plus
fresh-on-demand, and the freshness gap is closed by the MCP server rather than a hook — the model
pulls current context when it needs it, instead of us pushing it.

The MCP server (`remynd-context`) is one binary serving both agents, exposing `recent_activity`,
`search_screen_text`, `reconstruct_day`. Building it once for Codex also gives Claude Code a
pull path, so the two agents converge on the same retrieval surface.

**Codex is scoped as secondary** — the Claude Code path ships first and proves the core; Codex is
M8. Confirm whether that ordering is right, or whether both must land together.

## 6. Packaging

Move from `curl | bash` writing into `~/.claude` to a **Claude Code plugin + marketplace**, in the
existing repo `uda-eth/remynd-claude` (transfer to `move37-com` still owed):

```
.claude-plugin/marketplace.json
plugins/remynd/
  .claude-plugin/plugin.json      # versioned
  hooks/hooks.json                # SessionStart, UserPromptSubmit
  skills/remynd/SKILL.md
  scripts/{remynd-lib,remynd-refresh,session-context,prompt-delta}.sh
```

Install becomes:
```
claude plugin marketplace add uda-eth/remynd-claude
claude plugin install remynd@remynd
```
Verified available on Claude Code 2.1.235 (`claude plugin --help`).

Why this over the current installer: versioning, `/plugin` visibility, clean uninstall, and updates
that reach users who installed months ago — the exact failure mode that left today's hook broken
after the vault migration.

`install.sh` stays as a fallback (older Claude Code, no marketplace) and shells into the same
scripts, so there is one implementation.

Scripts live in a shared `core/` that the plugin, the fallback installer, and the Codex adapter all
call, so the digest logic and the SQL exist exactly once.

## 7. Integrations tab

Replace fire-and-forget "Set up Claude Code" with a real connection row:

- **Disconnected** — one-line value prop, `Connect` button, copyable command underneath. Where more
  than one agent is detected on the machine, the user picks which to sync (Claude Code / Codex /
  both). The connect confirmation states plainly what is synced, including screen text.
- **Connecting** — streamed output (already built, keep it).
- **Connected** — green state, plugin version, and a live freshness line:
  `Synced 2 minutes ago · 1,204 windows today`, read from `state/sync.json`.
- **Disconnect** — runs `claude plugin uninstall` and removes `~/.claude/remynd` (and the Codex
  adapter's `AGENTS.md` block + MCP entry, where installed).

Port from `design/liquid-glass-rollout`'s `ClaudeCodeSection` onto a fresh branch off
`development` (§8 M6).

## 8. Milestones

| # | Milestone | Done when |
|---|---|---|
| **M1** | Production data contract | `remynd-lib.sh` rewritten (app.db-required, production-preferred); the digest queries finalized and benchmarked on the 1.4 GB prod DB; `jq` removed from the install path; `sync_exclude` plumbed (empty default) |
| **M2** | Refresher + digest | `remynd-refresh.sh` writes `context.md` + `sync.json`; runs detached; skips when DB unchanged; OCR body text included and deduped; budget governor implemented and unit-tested against the measured rates |
| **M3** | Always-hot hooks | SessionStart (all sources) + UserPromptSubmit watermark delta; proven silent when idle, proven to inject within one prompt of new capture |
| **M4** | Production `/remynd` skill | Rewritten against prod schema; vault-optional; verified answering "what was I doing yesterday" from prod app.db alone |
| **M5** | Plugin + marketplace | Repo restructured; `claude plugin install remynd@remynd` works clean-room; `install.sh` fallback delegates to the same scripts |
| **M6** | Integrations tab | Fresh branch off `development`, connection row with live freshness, PR opened |
| **M7** | Proof pack | Clean-room install on a production profile; screenshots of both UI states; transcript showing context going hot mid-session *carrying OCR body text* |
| **M8** | Codex adapter | `AGENTS.md` regeneration + `remynd-context` MCP server registered in `~/.codex/config.toml`; same core, same digest |

**Delivered 2026-08-19.** M1–M6 and M8 are implemented in this repo and pass the acceptance suite
(`tests/acceptance.sh`, 30 checks). M8 shipped as the `AGENTS.md` block plus the shared `remynd` CLI
rather than an MCP server: Codex can run the command itself, which needs no server process and keeps
one implementation across both agents. The MCP server remains available as a later addition if a
pull-only surface is wanted. M7 (proof pack) is the remaining milestone.

Commit and push at each milestone. PR opened, not merged.

## 9. Acceptance criteria

1. On a machine with only `/Applications/ReMynd.app` (1.2.9397) and Claude Code, install succeeds and
   the first session opens knowing the user's recent apps, windows and sites.
2. Mid-session: user switches to a new app for 2+ minutes → the **next** prompt carries it,
   *including the text that was on screen*. Verified by transcript, not by inspection.
3. Idle session: 20 prompts with no new capture → **zero** injected tokens beyond SessionStart.
4. Deltas carry **OCR body text**, deduped on `normalizedText`; a 2-minute gap lands in ≤ 4.5k
   tokens. Per-delta cap 6k; session budget 35% of context window; every truncation names what it
   deferred and how to retrieve it.
5. UserPromptSubmit hook adds < 50 ms p95 to prompt latency (cache-read path).
6. Survives `/compact` — context is re-injected, not lost.
7. No writes to any ReMynd file. `app.db` opened `?mode=ro` throughout.
8. Fresh ReMynd install with no history: installs quietly, injects nothing, no errors.
9. Session budget exhaustion degrades to structural-only *and says so once* — never silently.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Cold query (275 ms) on the prompt path | Hooks read cache only; refresher runs detached |
| `app.db` grows; scans slow down | Bound every query by time window + `LIMIT`; revisit if p95 regresses |
| Per-prompt hook annoys power users | `MIN_DELTA` suppresses noise; documented off switch; injections are self-limiting by elapsed time (§5.3) |
| Full OCR floods the context window | Budget governor (§5.6), measured not guessed; degrades to structural + skill pointer, never silent |
| Credentials on screen reach provider logs | `redact_credentials` defaults ON, narrow credential-shaped patterns only (§5.8) |
| User surprise at what got synced | Explicit connect gate, plain-language copy, one-click disconnect; capture exclusions inherited from ReMynd |
| Vault ships later and this diverges | Vault-optional layering designed in from M4, not retrofitted |
| Repo still under `uda-eth` | Transfer to `move37-com` before the Integrations tab ships publicly |

## 11. Decisions taken

| Date | Decision |
|---|---|
| 2026-08-19 | Read production `app.db` directly; vault-optional. The brain is not in the production release. |
| 2026-08-19 | Freshness = watermark delta on `UserPromptSubmit`; silent when idle. |
| 2026-08-19 | Integrations UI lands on a fresh branch off `development`. |
| 2026-08-19 | OCR body text **is** included once the user opts in. Full fidelity, dedup only. |
| 2026-08-19 | Skill name is **`/remynd`**. |
| 2026-08-19 | `redact_credentials` defaults **ON**, user-toggleable. |
| 2026-08-19 | No time-based rate limit. `MIN_INTERVAL` removed in favour of `MIN_DELTA` (§13.2). |
| 2026-08-19 | `jq` dependency dropped — unavailable on macOS 14/15, which ReMynd supports (§13.3). |
| 2026-08-19 | Session budget stays 35%; runway recomputed at the deduped rate (§13.4). |
| 2026-08-19 | Production has no capture exclusion list; the sync ships its own, defaulting to empty (§13.1). |

## 12. Open questions

**Resolved 2026-08-19** — see §13 for the answers and evidence. One remains:

1. **Codex ordering** — M8 as scoped (Claude Code ships and proves the core first), or must Codex
   land in the same release? This is a product call, not a technical one. Recommendation: M8.
   Codex cannot be verified end-to-end on this machine (not installed), and its freshness ceiling is
   structurally lower — no per-turn hook — so proving the push path on Claude Code first de-risks the
   shared core before the pull adapter is built on top of it.

## 13. Resolutions

### 13.1 Exclusion list — production has none

Verified against `origin/development` and the shipping binary. Production's only capture controls are
a global pause and `ignoreIncognitoBrowserWindows` (default **true**). There is no per-app or
per-domain exclusion. The PRD's earlier claim that the sync would inherit one was wrong and is
corrected in §5.8; the integration now ships its own `sync_exclude`, defaulting to empty.

### 13.2 `MIN_INTERVAL` — removed, not tuned

A 90 s injection floor contradicts goal 2: a user prompting every 30 s would run up to three prompts
behind. It also solved a non-problem — delta size is proportional to elapsed time, so frequent
injections are inherently cheap (~140 tokens for 10 s of capture). Replaced with `MIN_DELTA` (~50
tokens), which suppresses noise without ever putting the context behind. See §5.3.

### 13.3 `jq` — dropped

`/usr/bin/jq` (`jq-1.7.1-apple`) ships with macOS 26. But ReMynd's `LSMinimumSystemVersion` is
**14.0**, and jq is absent on macOS 14 and 15 — where a user without Homebrew hits a hard install
failure with no path forward. The hooks emit small, fixed-shape JSON; hand-rolled emission with
correct escaping removes the dependency entirely. No third-party requirement survives.

### 13.4 Session budget — 35% confirmed

At the governing deduped rate of 820 tokens per active minute, a 35% budget yields ~7 active hours on
a 1M context and ~85 active minutes on 200k. Both clear a realistic working session before any
deferral. (An earlier draft quoted ~4 hours / ~50 minutes; that used the raw 1,440 rate, inconsistent
with dedup always being applied. Corrected in §5.6.)


## 14. What the build found

Implementation surfaced four things the PRD could not have known. Each is now encoded in the code
and guarded by a test.

### 14.1 `app.db` stores UTC, not local time

ReMynd's own documentation says local. It is wrong. Verified 2026-08-19: a frame captured at
10:22:30 EDT is stored as `2026-08-19 14:22:30`. Filtering a "last 30 minutes" window with a
local-time cutoff therefore returns **nothing at all**, silently — the failure looks exactly like an
idle user. The rule now enforced throughout: **filter in UTC, display in local**, with cutoffs from
`date -u` and every human-facing timestamp passed through `datetime(col,'localtime')`.

### 14.2 There is no index on any timestamp column

`WHERE firstSeenAt >= <cutoff>` full-scans 873k rows: **3,954 ms**. Because `id` is `AUTOINCREMENT`
and monotonic with time, bounding the rowid tail first and filtering inside that subquery costs
**29 ms** — 136×. The delta path goes further: the watermark stores the last OCR rowid, making
`WHERE id > <last>` a primary-key range scan. Measured **27 ms** for a typical delta and **20 ms**
for the no-news case, against a 50 ms budget.

### 14.3 A hook that reads stdin can hang the session

Both hooks originally drained stdin with `cat`. That never returns if the caller holds the pipe
open — which would freeze the user's prompt behind it. Claude Code always closes stdin, so this
would have shipped undetected and failed only in unusual conditions. SessionStart now reads stdin
not at all; the delta hook uses a bounded `read -t 2` and falls back to the environment. Guarded by
a regression test.

### 14.4 Redaction and exclusion both had to be built, not inherited

§13.1 established that production has no per-app capture exclusion. `sync_exclude` is therefore
implemented here — empty by default, matching case-insensitively against the focused app name, and
**announcing what it withheld** rather than dropping quietly. Credential redaction covers OpenAI,
Anthropic, GitHub, AWS, Slack, JWT, Bearer, Google and PEM key shapes plus card numbers and
`password=`/`secret=`/`api_key=` assignments.

### 14.5 Dedupe needed a second key

Deduping on `normalizedText` alone leaves near-duplicates: the recorder emits rows whose normalized
text differs only by a spinner glyph or cursor while the rendered text is identical. Deduping on the
rendered text as well removes them, and loses nothing — identical display text is identical
information.

## 15. Shipped surface

```
.claude-plugin/marketplace.json      plugin marketplace manifest
plugins/remynd/
  .claude-plugin/plugin.json         versioned plugin
  hooks/hooks.json                   SessionStart + UserPromptSubmit
  skills/remynd/SKILL.md             the /remynd skill
  core/
    remynd                           the CLI both agents share
    remynd-lib.sh                    profile detection, JSON, rowid search
    remynd-digest.sh                 digest builder, budget governor, redaction
    remynd-session-hook.sh           opening snapshot
    remynd-delta-hook.sh             the always-hot engine
    remynd-refresh.sh                out-of-band cache
    remynd-settings.sh               safe settings.json merge (no jq)
install.sh                           Claude Code and/or Codex, plus --uninstall
tests/acceptance.sh                  30 checks against a real profile
```

Dependencies: `bash`, `/usr/bin/sqlite3`, `/usr/bin/awk`, `/usr/bin/sed`. All are system binaries on
every supported macOS. No jq, no Homebrew, no Python, no node, no network at runtime.
