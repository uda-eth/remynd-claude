# Shrinking the ReMynd MCP tool surface

**What this is:** one file changed, `remynd-mcp.swift`, tool descriptions and schema strings only. No tool added or removed, no behaviour changed, no code path touched. The server answers exactly what it answered before.

**Why:** every MCP request re-sends the whole tool surface. Measured against a no-tools baseline on the same CLI, ReMynd's 12 tools cost **4,935 tokens on every request**. A median benchmark run made 6 requests, so about **29,600 tokens of a 55,700-token run was the server describing itself** — more than half, before a single byte of the user's history.

**Measured result:** 4,935 → **3,722 tokens per request, a 24.6% cut**, with all 12 tools and their full capability intact.

---

## How the numbers were produced

A benchmark in `~/dev/remynd-bench` put two tool surfaces over the same ReMynd history on this Mac and asked both the same 23 questions, 3 repeats, blind-judged, with success criteria fixed in `CRITERIA.md` before the runner existed. 138 runs for the main comparison, 69 more for a third arm. Full method and every amendment are in that repo; `proof/REPORT.md` has the results.

Two findings from it drive this change.

**1. The surface is the cost.** Per-tool accounting over 69 runs of the real server:

| tool | calls | avg result tokens | description cost per request |
|---|---|---|---|
| `search_screen_history` | 41 | 1,271 | ~221 |
| `show_moment` | 61 | 2,261 | ~362 |
| `reconstruct_day` | 34 | 1,465 | ~216 |
| `screen_text_in_range` | 27 | 7,966 | ~248 |
| `call_transcript` | 18 | 4,698 | ~192 |
| `search_calls` | 16 | 818 | ~119 |
| `list_calls` | 12 | 415 | ~140 |
| `sync_status` | 10 | 807 | ~84 |
| `time_by_activity` | **5** | 396 | ~99 |
| `fetch` | 1 | 11,890 | ~97 |
| `recent_activity` | **0** | — | ~89 |
| `search` | **0** | — | ~87 |

**2. `show_moment` was the single most expensive tool, and its description was the reason.** It told the model: *"Call it on your own, in the same turn, whenever your answer rests on particular moments… Don't ask first and don't offer frames at the end of your answer; show them."* The model obeyed — 61 calls across 69 runs. A call that returns a frame costs about **3,694 tokens**, and **16 of 35 sampled calls returned no frame at all** because the segment could not be decrypted.

In a test arm where the same tool was described as costly and gated to "only when the person asks to see something", calls fell from **61 to 4** with no loss of answer quality — that arm scored higher than the full surface.

---

## What changed, tool by tool

Every description now leads with the question the tool answers and keeps only the guidance that changes what the model does. The facts that were load-bearing are all still there:

- timestamps record when text was **on screen**, not when the event happened (`search_screen_history`, `search`)
- OCR digits are unreliable; don't quote raw (`screen_text_in_range`, `fetch`)
- the screen tools **cannot hear**; calls live in the call tools (`search_screen_history`, `list_calls`)
- speaker labels are ~85% reliable; check a quote against its neighbours (`call_transcript`)
- `time_by_activity` counts back from today and takes `days`, not a date range
- `sync_status` distinguishes "no record" from "not recording then"
- a frame is **not redacted** — never read a password or key out of one (`show_moment`)

| tool | description chars | |
|---|---|---|
| `search_screen_history` | 884 → 368 | |
| `reconstruct_day` | 865 → 342 | |
| `recent_activity` | 359 → 242 | |
| `screen_text_in_range` | 995 → 403 | |
| `time_by_activity` | 399 → 305 | |
| `search` | 348 → 260 | |
| `fetch` | 389 → 243 | |
| `list_calls` | 560 → 225 | |
| `call_transcript` | 771 → 405 | |
| `search_calls` | 477 → 429 | **new fact added** |
| `show_moment` | 1,450 → 949 | **behaviour change, see below** |
| `sync_status` | 339 → 282 | |
| **total** | **7,836 → 4,453** | 43% smaller |

Schema property descriptions were tightened the same way: 2,970 → 2,531 chars.

### The two substantive edits

**`show_moment` is now gated.** It keeps the "show, don't ask" intent for answers that are genuinely about something visual, but it is explicitly told not to fetch frames to check a fact, and to spend them on the one or two headline moments rather than every moment an answer touches. It also now says that a decryption failure is not an answer — three benchmark runs returned *"the frames couldn't be decrypted for that day"* **as the entire answer to "what did I work on"**, naming none of the actual work.

**`search_calls` gained a fact it was missing.** It returns at most **100 lines, newest first, and takes no date range**. Nothing in the old description said so, and a caller that filters its output by date will silently get nothing for any older day. The description now says to use `list_calls` for a date and then `call_transcript`. This was found the hard way: it made an entire arm of the benchmark unable to reach any August call.

---

## What was deliberately NOT changed

- **No tool removed.** `recent_activity` and `search` were called zero times in 69 runs, but 23 questions are not the product. `search`/`fetch` are the ChatGPT connector shape; removing them would break that client. Dropping the two unused tools would save roughly another 400 tokens per request if the team decides the evidence is enough.
- **No schema field removed**, so every existing call still validates.
- **No result formatting touched**, so nothing downstream of a tool call changes.
- **The decryption bug is not fixed here.** `show_moment` fails to decrypt frames for many moments — 16 of 35 sampled calls — and it is per-segment, not per-day: 2026-07-21 and 2026-08-19 each both succeeded and failed at different moments. That is a separate defect worth its own ticket.

## Verification

- Builds clean with `./build.sh` (universal binary, smoke test passes).
- Overhead re-measured with the same method that produced the 4,935 baseline: **3,722 tokens per request**.
- A control binary built from the unmodified source measures **4,935**, exactly matching the installed binary, so the comparison isolates this change rather than build drift.
- A 138-run paired benchmark of control vs slim on the same 23 questions is the accuracy check; results appended below when it completes.

## Rollback

`remynd-mcp.swift.bak` is the original source, and `remynd-mcp.control` is a binary built from it. Rolling back is a rebuild from the `.bak`, or a rename of the control binary into place.
