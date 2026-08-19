---
name: remynd
description: Search and reconstruct the user's own screen history — what THEY did, saw, read, or worked on. Use for "what was I doing on <date>", "find that thing I saw", "who is X", "what is that project/app/site", "how much time did I spend on Y", or any question whose answer lives in their past activity rather than in this repo. Backed by ReMynd's local OCR timeline of every recorded screen frame. Read-only.
---

# ReMynd — the user's own screen history

ReMynd records this Mac's screen, OCRs every frame, and keeps it in a local SQLite database. That
makes the user's past *retrievable*: what they read, wrote, watched and clicked, searchable by text
and reconstructable by day.

**Every session already starts with a digest of recent activity**, injected automatically, and it is
topped up as they work. Reach for this skill when you need to go **beyond** that digest — further
back in time, or deeper into the verbatim text.

Everything here is **read-only**. The running app owns these files; never write to them.

## Use the `remynd` command

**Always invoke it by absolute path: `~/.remynd-sync/bin/remynd`.** Your shell is not a login
shell, so it has not sourced the user's profile and bare `remynd` will usually not resolve. Do not
waste turns hunting for it. If that path does not exist, the sync is not installed — say so rather
than guessing at the user's history.

The examples below omit the prefix for readability; use the full path when you run them.

```bash
remynd now                      # what they're doing right now
remynd recent 60                # digest of the last 60 minutes
remynd search "stripe webhook"  # full-text search everything they've seen
remynd day 2026-08-13           # reconstruct a specific day
remynd apps 7                   # where their time went, last 7 days
remynd text "2026-08-13 23:30" "2026-08-13 23:45"   # verbatim screen text
remynd status                   # profile, freshness, whether redaction is on
```

## Choosing a command

| The question | The command |
|---|---|
| "what was I doing on Tuesday" | `remynd day <date>` |
| "find that article about X" | `remynd search "X"` |
| "what's that tool I was looking at" | `remynd search`, then `remynd text` around the hit |
| "how much time do I spend in Slack" | `remynd apps 30` |
| "what was I just reading" | `remynd recent 15` |
| "what did that error say" | `remynd search "<error fragment>"` |

**Search first, then widen.** `remynd search` gives you timestamps; feed a promising timestamp into
`remynd text "<from>" "<to>"` to read everything that was on screen around it. That two-step is how
you answer "I saw something about this last week but I can't remember where".

## Reading the output well

- **Times shown are LOCAL**, formatted `YYYY-MM-DD HH:MM:SS`. The `remynd` command converts them
  for you. **The database underneath stores UTC** — so if you ever bypass `remynd` and query
  `app.db` yourself, your time windows will be silently wrong by the UTC offset. Older ReMynd docs
  claim the database is local time; they are mistaken. Prefer the command.
- **OCR is imperfect.** Text is read off pixels, so expect occasional garbled words, and expect
  interface chrome (button labels, menu items) mixed in with real content. Read around it.
- **Order within a single second is arbitrary** — OCR segments from one frame have the same
  timestamp and no meaningful sequence among themselves.
- **A gap in the data means the Mac was asleep, locked, or ReMynd was paused** — not that the user
  did nothing. Don't narrate gaps as inactivity.
- **Credential-shaped strings are redacted** by default, appearing as `sk-<redacted>` and similar.
  That is the redaction working, not corrupted data.

## Being useful with this

Answer from what you find, and **cite when it matters** — a timestamp or an app name lets the user
verify you. When the history is ambiguous, say what you found and what you're unsure of rather than
constructing a confident story from fragments.

If a question is about the user's own past, prefer looking it up here over asking them. That is the
entire point: they already told their computer, and this is how you read it back.

## Coverage — check before concluding "no data"

The context injected at session start covers only the **last couple of hours**. It is not the extent
of what exists. Recorded history usually spans weeks. Before telling the user there is no record of
something, run `~/.remynd-sync/bin/remynd status` (it prints the span) or just query the day — never
infer absence from the session digest alone.

## When there's nothing to find

`remynd status` tells you whether ReMynd has recorded at all. A brand-new install has little or no
history — say so plainly instead of speculating.
