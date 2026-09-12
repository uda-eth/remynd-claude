#!/usr/bin/env python3
"""UserPromptSubmit hook — give the agent eyes when the feedback needs them.

Text feedback about a visual thing is nearly useless on its own. "The panel
flashes before it settles", "it's cut off on the right", "play it again, the
timing is off" — none of that can be checked by reading source. The agent
either guesses, or asks the user to take a screenshot, and the loop stalls.

ReMynd is already recording the screen. When a prompt reads as feedback about
something that was just on screen, this pulls the actual frames out of that
recording and tells the agent where they are. The agent looks at what the user
looked at, and the fix/see/fix loop closes without anyone taking a screenshot.

Deliberately quiet: it emits nothing at all unless the prompt reads as visual
feedback, so an ordinary prompt costs zero tokens. And it only ever *points* at
frames — the agent decides whether to open them.
"""

import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".remynd-sync")
VISION = os.path.join(ROOT, "bin", "remynd-vision")
CONFIG = os.path.join(ROOT, "config")
STATE_DIR = os.path.join(ROOT, "vision", "state")
FRAME_ROOT = os.path.join(ROOT, "vision", "frames")

# Window bounds. Too short and a slow reply misses the moment; too long and the
# frames drift away from what the feedback is about.
MIN_WINDOW = 60
MAX_WINDOW = 20 * 60
DEFAULT_WINDOW = 8 * 60
MAX_FRAMES = 6
WIDTH = 1400
BUDGET_SECONDS = 12


# --------------------------------------------------------------- intent

# Things you can only judge by looking.
VISUAL_NOUN = r"""(?:animation|animations|transition|transitions|video|videos|render|
    renders|rendering|playback|film|clip|frame|frames|screen|screens|display|ui|
    interface|layout|panel|panels|window|windows|modal|dialog|popup|overlay|
    sheet|toolbar|sidebar|button|buttons|icon|icons|logo|cursor|scroll|
    spacing|padding|margin|alignment|font|fonts|type|text|colour|color|colours|
    colors|gradient|shadow|border|corner|radius|glass|blur|chart|graph|image|
    screenshot|demo|onboarding|splash|tour|page|slide|carousel|thumbnail)"""

# Words that mark a complaint or an observation about how something looked.
DEFECT = r"""(?:wrong|off|broken|weird|odd|strange|janky|choppy|jerky|stutter\w*|
    flicker\w*|flash\w*|blink\w*|glitch\w*|blank|empty|black|white|invisible|
    missing|gone|cut\s*off|clipped|overlap\w*|misalign\w*|unaligned|crooked|
    jump\w*|shift\w*|lag\w*|slow|fast|big|small|tiny|huge|dark|light|ugly|
    squish\w*|stretch\w*|blurry|pixelated|not\s+showing|doesn'?t\s+show|
    didn'?t\s+show|doesn'?t\s+play|didn'?t\s+play|doesn'?t\s+appear|
    didn'?t\s+appear|never\s+appear\w*|not\s+working|still\s+there|
    behind|underneath|on\s+top\s+of|off\s*screen|offscreen|out\s+of\s+frame|
    wrong\s+(?:place|position|spot|order|size)|
    still\s+not|not\s+cent(?:er|re)ed|off\s*cent(?:er|re)|uncentered|
    too\s+far|nudge\w*|squeezed)"""

# Verbs describing something that happened on screen.
SAW_VERB = r"""(?:play\w*|ran|run|render\w*|show\w*|display\w*|appear\w*|pop\w*|
    load\w*|animat\w*|fade\w*|slide\w*|look\w*|start\w*|open\w*)"""

# An unambiguous request to go and look.
EXPLICIT = re.compile(r"""
    look\s+at\s+(?:my|the|that|this)?\s*(?:screen|display|monitor|recording)
  | (?:check|use|pull\s+up|watch)\s+(?:the\s+)?(?:rewind|remynd|recording|frames?|screen)
  | (?:what|did)\s+(?:did\s+)?you\s+see
  | you\s+saw
  | see\s+(?:what|how)\s+(?:happened|it\s+look)
  | on\s+(?:my|the)\s+screen
  | watch\s+(?:it|the|what)
  | see\s+for\s+yourself
  | look\s+at\s+what\s+(?:it|you|that)
""", re.I | re.X)

def _word(pattern):
    """Anchor an alternation at word boundaries.

    Unanchored, short alternatives match inside ordinary words — "ui" inside
    "build", "off" inside "office", "text" inside "context" — and any prompt
    with the word "build" in it reads as a complaint about the interface.
    """
    return re.compile(r"\b(?:" + pattern + r")\b", re.I | re.X)


NOUN_RE = _word(VISUAL_NOUN)
DEFECT_RE = _word(DEFECT)
SAW_RE = _word(SAW_VERB)
DEIXIS_RE = re.compile(r"\b(?:this|that|it|there|here|those|these)\b", re.I)

# "the last 5 minutes", "past 2 min" — lets the user widen the window in words.
WINDOW_RE = re.compile(
    r"\b(?:last|past|previous)\s+(?:(\d+)\s*)?(second|sec|minute|min|hour|hr)s?\b", re.I)

APP_RE = re.compile(
    r"\bin\s+(ReMynd|Chrome|Safari|Xcode|Figma|Preview|QuickTime|Finder|Simulator|Photos)\b",
    re.I)


def detect(prompt):
    """Return (should_fire, reason) for a prompt."""
    p = prompt.strip()
    if not p:
        return False, ""
    # Slash commands are handled by whatever they invoke.
    if p.startswith("/"):
        return False, ""

    if EXPLICIT.search(p):
        return True, "you were asked to look at the screen"

    has_noun = bool(NOUN_RE.search(p))
    has_defect = bool(DEFECT_RE.search(p))
    has_saw = bool(SAW_RE.search(p))
    has_deixis = bool(DEIXIS_RE.search(p))

    if has_noun and has_defect:
        return True, "the feedback describes how something looked"
    if has_noun and has_saw and has_deixis:
        return True, "the feedback points at something that played on screen"
    if has_defect and has_saw and has_deixis:
        return True, "the feedback points at something that went wrong on screen"
    return False, ""


def requested_window(prompt):
    m = WINDOW_RE.search(prompt)
    if not m:
        return None
    n = int(m.group(1)) if m.group(1) else 1
    unit = m.group(2).lower()
    secs = n * (1 if unit.startswith("sec") else 3600 if unit.startswith("h") else 60)
    return max(MIN_WINDOW, min(MAX_WINDOW, secs))


def requested_app(prompt):
    m = APP_RE.search(prompt)
    return m.group(1) if m else None


# --------------------------------------------------------------- state

def enabled():
    if os.environ.get("REMYND_VISION", "") == "0":
        return False
    try:
        with open(CONFIG) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("vision_enabled="):
                    return line.split("=", 1)[1].strip() not in ("0", "false", "no")
                if line.startswith("enabled=") and line.split("=", 1)[1].strip() == "0":
                    return False
    except OSError:
        pass
    return True


def window_start(session, now):
    """Start of the window: when this session last submitted a prompt."""
    path = os.path.join(STATE_DIR, f"{session}.last")
    previous = None
    try:
        with open(path) as fh:
            previous = float(fh.read().strip())
    except (OSError, ValueError):
        pass
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        with open(path, "w") as fh:
            fh.write(str(now))
    except OSError:
        pass
    if previous is None:
        return now - DEFAULT_WINDOW
    return now - max(MIN_WINDOW, min(MAX_WINDOW, now - previous))


def prune(keep_session):
    """Frames are disposable; don't let them pile up forever."""
    cutoff = time.time() - 6 * 3600
    try:
        for name in os.listdir(FRAME_ROOT):
            path = os.path.join(FRAME_ROOT, name)
            if name == keep_session:
                continue
            try:
                if os.path.getmtime(path) < cutoff:
                    subprocess.run(["/bin/rm", "-rf", path], timeout=10)
            except OSError:
                pass
    except OSError:
        pass


# --------------------------------------------------------------- main

def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    prompt = payload.get("prompt", "") or ""
    session = payload.get("session_id", "default") or "default"
    session = re.sub(r"[^A-Za-z0-9_.-]", "_", session)[:64]

    now = time.time()
    start = window_start(session, now)

    if not enabled() or not os.access(VISION, os.X_OK):
        return 0

    fire, reason = detect(prompt)
    if not fire:
        return 0

    override = requested_window(prompt)
    if override:
        start = now - override
    app = requested_app(prompt)

    out_dir = os.path.join(FRAME_ROOT, session, str(int(now)))
    cmd = [
        VISION,
        "--from", str(int(start)),
        "--to", str(int(now)),
        "--max", str(MAX_FRAMES),
        "--width", str(WIDTH),
        "--prefer", "motion",
        "--out", out_dir,
        "--json",
    ]
    if app:
        cmd += ["--app", app]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=BUDGET_SECONDS)
    except (subprocess.TimeoutExpired, OSError):
        return 0
    if proc.returncode != 0 or not proc.stdout.strip():
        return 0

    try:
        result = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        return 0

    frames = result.get("frames", [])
    if not frames:
        return 0

    prune(session)

    span = time.strftime("%H:%M", time.localtime(start)) + "–" + \
        time.strftime("%H:%M", time.localtime(now))
    apps = sorted({f.get("app", "") for f in frames if f.get("app")})
    app_note = ", ".join(apps) if apps else "the screen"

    lines = [
        "## What was actually on screen",
        "",
        f"The prompt above reads as visual feedback ({reason}), so these frames were "
        f"pulled from ReMynd's screen recording for {span} — {app_note}. They are what "
        "the user was looking at, not a fresh screenshot, so they show the moment being "
        "described even though it has passed.",
        "",
    ]
    for i, f in enumerate(frames, 1):
        label = f" [{f['app']}]" if f.get("app") else ""
        lines.append(f"{i}. {f['time']}{label} — {f['path']}")
    lines += [
        "",
        "Read the ones that look relevant (usually 2–3 is enough) before answering — "
        "checking what actually happened beats inferring it from the code. Frames are "
        "chosen from moments the screen was changing, so they cluster around movement.",
        "",
        "To look at any other stretch yourself, at any point in a turn:",
        "  ~/.remynd-sync/bin/remynd-vision --since 3m [--app <name>] [--max N]",
        "This is how you check your own work: render or run something, then look at the "
        "frames of it running rather than asking the user what they saw.",
    ]
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # A hook must never block the user's prompt.
        sys.exit(0)
