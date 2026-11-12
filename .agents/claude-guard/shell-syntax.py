#!/usr/bin/env python3
"""Tell the agent at once when a shell script it just wrote does not parse.

scripts/apply-claude-guard.sh installs this as ~/.claude/hooks/jarvis-shell-syntax.py
and registers it for PostToolUse on Edit and Write.

A shell script is a file ending in .sh or .bash, or one whose #! line runs sh or
bash, such as a Git hook. After the edit, the script is parsed with `bash -n`,
using /bin/bash when there is one: on macOS that is bash 3.2, the shell such a
script meets, which refuses some syntax a newer bash accepts. A script that does
not parse exits 2 with bash's message on stderr, which Claude Code shows the
agent; the edit itself has already happened. Anything else, including an error in
this hook, prints nothing and exits 0: this hook only advises.
"""
import json
import os
import subprocess
import sys

SUFFIXES = (".sh", ".bash")
SHELLS = ("sh", "bash")


def interpreter(first_line):
    """The program a #! line runs, through `env` when it names one."""
    if not first_line.startswith("#!"):
        return ""
    words = first_line[2:].split()
    if not words:
        return ""
    prog = os.path.basename(words[0])
    if prog == "env":
        rest = [w for w in words[1:] if not w.startswith("-") and "=" not in w]
        prog = os.path.basename(rest[0]) if rest else ""
    return prog


def is_shell_script(path):
    if path.endswith(SUFFIXES):
        return True
    try:
        with open(path, "rb") as f:
            first = f.readline(256).decode("utf-8", "replace").strip()
    except OSError:
        return False
    return interpreter(first) in SHELLS


def main():
    event = json.load(sys.stdin)
    path = (event.get("tool_input") or {}).get("file_path") or ""
    if not path or not os.path.isfile(path) or not is_shell_script(path):
        return 0
    bash = "/bin/bash" if os.access("/bin/bash", os.X_OK) else "bash"
    # `bash -n` runs nothing, so a script's own `shopt -s extglob` is not in
    # force while its patterns are parsed; turn it on for a script that names it.
    with open(path, "rb") as f:
        extglob = ["-O", "extglob"] if b"extglob" in f.read() else []
    result = subprocess.run(
        [bash] + extglob + ["-n", path], capture_output=True, text=True, errors="replace", timeout=8
    )
    if result.returncode == 0:
        return 0
    message = result.stderr.strip() or "bash -n exited %d" % result.returncode
    sys.stderr.write("%s does not parse under %s -n:\n%s\n" % (path, bash, message))
    return 2


if __name__ == "__main__":
    try:
        code = main()
    except Exception:
        code = 0
    sys.exit(code)
