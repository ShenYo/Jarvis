#!/usr/bin/env python3
"""Tell the agent when to save its session notes, and where they are after a compaction.

scripts/apply-claude-guard.sh installs this as ~/.claude/hooks/jarvis-session-notes.py
and registers it for two events:

  UserPromptSubmit   once the context passes HINT_TOKENS, say how large it is and how
                     old the notes are, so the agent can save them and suggest /compact
                     at the next boundary;
  SessionStart       after a compaction, point the agent at the notes.

The notes are the session-notes Skill's file, docs/temp/session-notes/<session id>.md
in the repository the session started in. This hook only advises: on any error it
prints nothing and exits 0.
"""
import json
import os
import subprocess
import sys
import time

# A cache read costs a tenth of an input token or less, but every request reads the
# whole context, and a context left idle past the cache's lifetime is written again
# in full. Past about 300k tokens, compacting at a boundary costs less than carrying on.
HINT_TOKENS = 300_000
NOTES_DIR = "docs/temp/session-notes"
TAIL_BYTES = 4 << 20


def context_tokens(transcript):
    """The context size of the latest main-thread request, or None if unknown.

    A compaction after that request replaces it with the compaction's own count.
    """
    with open(transcript, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL_BYTES))
        lines = f.read().splitlines()
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        if entry.get("subtype") == "compact_boundary":
            return (entry.get("compactMetadata") or {}).get("postTokens")
        usage = (entry.get("message") or {}).get("usage") if entry.get("type") == "assistant" else None
        if isinstance(usage, dict):
            return sum(usage.get(k) or 0 for k in
                       ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    return None


def notes_path(event):
    project = os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ""
    session = event.get("session_id") or ""
    if not project or not session or "/" in session:
        return None
    root = subprocess.run(["git", "-C", project, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, timeout=5)
    if root.returncode != 0:
        return None
    return os.path.join(root.stdout.strip(), NOTES_DIR, session + ".md")


def age(path):
    minutes = int((time.time() - os.path.getmtime(path)) // 60)
    return "updated just now" if minutes < 1 else f"updated {minutes} min ago"


def say(event_name, text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event_name,
                                             "additionalContext": text}}))


def main():
    event = json.load(sys.stdin)
    name = event.get("hook_event_name")
    if name == "SessionStart" and event.get("source") == "compact":
        path = notes_path(event)
        if path and os.path.isfile(path):
            say(name, f"This session was just compacted. Its session notes, {age(path)}, are at "
                      f"{path}: read them before continuing. They hold what the summary dropped.")
    elif name == "UserPromptSubmit":
        tokens = context_tokens(event.get("transcript_path") or "")
        if not tokens or tokens < HINT_TOKENS:
            return
        path = notes_path(event)
        notes = (f"Session notes: {age(path)}, at {path}." if path and os.path.isfile(path)
                 else "This session has no notes yet.")
        say(name, f"Context is about {tokens // 1000}k tokens, past the {HINT_TOKENS // 1000}k "
                  f"where compacting pays off. {notes} When the work reaches a boundary (committed "
                  "and pushed, no agent or background task running, nothing half-done), bring the "
                  "notes up to date with the session-notes Skill, then suggest /compact to the user. "
                  "Mid-task, carry on.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
