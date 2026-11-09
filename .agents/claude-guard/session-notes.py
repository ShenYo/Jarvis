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
            tokens = sum(usage.get(k) or 0 for k in
                         ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            # A message Claude Code writes itself, such as a usage-limit notice, reports
            # zero; the request before it holds the real size.
            if tokens:
                return tokens
    return None


def notes_path(event):
    """The session's notes file, or None where the Skill would not write one."""
    project = os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or ""
    session = event.get("session_id") or ""
    if not project or not session or "/" in session:
        return None
    root = subprocess.run(["git", "-C", project, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, timeout=5)
    if root.returncode != 0:
        return None
    path = os.path.join(root.stdout.strip(), NOTES_DIR, session + ".md")
    # The Skill writes only where Git ignores the path.
    ignored = subprocess.run(["git", "-C", root.stdout.strip(), "check-ignore", "-q", path],
                             timeout=5)
    return path if ignored.returncode == 0 else None


def age(path):
    minutes = int((time.time() - os.path.getmtime(path)) // 60)
    if minutes < 1:
        return "updated just now"
    if minutes < 120:
        return f"updated {minutes} min ago"
    if minutes < 48 * 60:
        return f"updated {minutes // 60} hours ago"
    return f"updated {minutes // (24 * 60)} days ago"


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
        if path:
            notes = (f"Session notes: {age(path)}, at {path}." if os.path.isfile(path)
                     else "This session has no notes yet.")
            step = "bring the notes up to date with the session-notes Skill, then suggest"
        else:
            notes = ("This project cannot hold session notes: it is not a Git repository, "
                     "or Git does not ignore docs/temp/ here.")
            step = "suggest"
        say(name, f"Context is about {tokens // 1000}k tokens, past the {HINT_TOKENS // 1000}k "
                  f"where compacting pays off. {notes} When the work reaches a boundary (committed "
                  f"and pushed, no agent or background task running, nothing half-done), {step} "
                  "/compact to the user. Mid-task, carry on.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
