# ReMynd and Siri

**Siri cannot take an MCP server.** That is not a gap in ReMynd — there is no MCP client
anywhere in macOS 26.5. The only framework that reaches Siri is App Intents, and Apple's MCP
work (first seen in the 26.1 betas) points the other way: it exposes *your apps' intents* to
outside AI, rather than letting Siri consume an outside MCP server. There is no URL to paste
and no config file to write.

What Siri *can* do is run a Shortcut by name, and a Shortcut on macOS can run a shell script.
That is the whole path, and it works today.

## What you get

    "Hey Siri, ReMynd yesterday"   → "Yesterday you worked on <the thing> for 2 hours 5
                                      minutes, then Claude for 1 hour 17 minutes…"
    "Hey Siri, ReMynd now"         → "You're in Terminal."
    "Hey Siri, ReMynd this week"   → "This week you were in Google Chrome for 15 hours…"

## What you do not get

Canned phrases, not conversation. Siri is not an agent here: it runs a fixed shortcut and
speaks what comes back. It cannot decide which tool to call, read across a week, or answer
"what did Ali say about the API key" — that needs a model, and Siri will not lend you one.

For real questions, use Claude. This is for the three things worth asking without a keyboard.

## Set it up (about a minute, once per phrase)

1. Open **Shortcuts** → **+** for a new shortcut.
2. Search the action list for **Run Shell Script** and add it.
3. Set **Shell** to `/bin/zsh`, and paste as the script:

       exec "$HOME/.remynd-sync/bin/remynd-say" yesterday

4. Add a **Show Result** action below it — that is the part Siri reads aloud.
5. Name the shortcut **ReMynd yesterday**.

Repeat with `now` and `this week` for the other two. The name is the phrase Siri listens
for, so keep it short and say-able.

## Why `remynd-say` and not the CLI

`remynd recent` is written to be READ: a ranked table, an hour-by-hour trail, verbatim OCR.
Spoken aloud it is unbearable. `remynd-say` answers in one sentence, because that is the
entire budget a voice assistant has before a person stops listening. It also refuses to say
"nothing" when the Mac simply was not recording — "no data" and "you did nothing" are
different sentences and only one of them is true.

## If Apple Intelligence is on

Shortcuts gains a model action, so you could feed `remynd-say`'s output plus the spoken
question to the on-device model and get something closer to a real answer. It is a small
model and it will not be Claude. Apple Intelligence is currently off on this Mac.
