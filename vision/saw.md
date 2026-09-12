---
description: Look at the real screen frames from ReMynd for a recent window
allowed-tools: Bash(~/.remynd-sync/bin/remynd-vision:*), Read
---

Extract the actual screen frames for the window the user asked about and look at them.

Arguments (all optional): `$ARGUMENTS`
Interpret them loosely — e.g. `5m`, `last 10 minutes`, `3m ReMynd`, `in Chrome`,
`14:05 to 14:09`. Default to the last 5 minutes when nothing is given.

Steps:
1. Run the extractor, translating the arguments into flags:
   `~/.remynd-sync/bin/remynd-vision --since <window> [--app <name>] [--max N]`
   Use `--from "<time>" --to "<time>"` when an explicit range was given, and
   `--all-apps` only if the user is asking about the terminal itself.
2. Read the returned PNG paths — start with 2–3 of the most relevant, and open
   more only if they don't answer the question.
3. Describe what was actually on screen and answer the user's question from the
   frames, not from the code. If the frames contradict what the code implies,
   say so plainly and trust the frames.

If no frames come back, say why (the window may predate recording, or the app
may be excluded for privacy) rather than guessing at what was on screen.
