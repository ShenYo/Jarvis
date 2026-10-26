#!/usr/bin/env python3
"""Claude Code and Codex PreToolUse guard for the Bash tool.

The permission rules in guard.json match command text, so `git -C . branch -D
x`, `bash -c "..."`, `git commit -an` and `rm -vrf` reach a prohibited
operation without matching any of them. This hook parses the command instead:
it splits compound commands, unwraps shells, `eval`, `$(...)`, heredocs fed to
a shell, wrappers such as `env` and `xargs`, path-qualified binaries and git
aliases, expands short-flag clusters, and resolves a bare `git push` against
the branch it would push.

It answers "deny" for the permanently prohibited operations and "ask" for the
human-review checkpoints, and says nothing otherwise, so the normal permission
flow decides. It never answers "allow".

What it cannot see: a script file it is asked to run, a program that builds a
command at run time, and code in a language whose strings it does not scan.
The auto-mode classifier is the layer for those.

With the argument `--codex` it runs as a Codex hook. Codex cannot ask (it
parses "ask" and then runs the command), and it runs the command when a hook
fails or overruns, so in that mode every "ask" is emitted as "deny", the
reason says why, and any error anywhere becomes a "deny" naming it, with exit
status 0. Without the argument nothing changes.

Compatible with Python 3.9, the version macOS ships at /usr/bin/python3.
"""
import json
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

MAX_DEPTH = 6
MAX_ALIAS_DEPTH = 8

CODEX = "--codex" in sys.argv[1:]
GUARD = "Codex guard" if CODEX else "Claude guard"

# Every git lookup shares one budget, well inside the hook's 10 s timeout (the
# one apply-codex-guard.sh writes for Codex; guard.json's for Claude Code): a
# hook that times out blocks the call under Claude Code, which is safe but
# unhelpful, and under Codex runs it. The 6 s budget leaves 4 s for the
# interpreter to start and for the analysis outside the git lookups. A lookup
# that runs out of budget answers "unknown", and unknown asks.
DEADLINE = time.monotonic() + 6

PROHIBITED = (
    "This is permanently prohibited for agents, even when the user asks. "
    "State the exact command and its target, and ask the user to run it "
    "themselves."
)
CHECKPOINT = "This is a human-review checkpoint: a person decides it."
CODEX_CHECKPOINT = (
    CHECKPOINT[:-1] + ", and Codex cannot ask. State the exact command and "
    "let the user run it, or do it in a runtime that can ask."
)


class Result:
    def __init__(self):
        self.deny = []
        self.ask = []

    def no(self, why):
        if why not in self.deny:
            self.deny.append(why)

    def check(self, why):
        if why not in self.ask:
            self.ask.append(why)


class Ctx:
    """The shell's working directory as far as the analysis can follow it.
    None means unknown: a bare push from an unknown place asks."""

    def __init__(self, cwd, prev=None, stack=None):
        self.cwd = cwd
        self.prev = prev
        self.stack = list(stack or [])

    def copy(self):
        return Ctx(self.cwd, self.prev, self.stack)

    def resolve(self, target):
        if target in ("$OLDPWD", "${OLDPWD}"):
            return self.prev
        target = re.sub(r"^\$(HOME|\{HOME\})", "~", target)
        if self.cwd is None and not target.startswith(("/", "~")):
            return None
        if "__SUBST__" in target or "$" in target or "`" in target:
            return None
        return os.path.normpath(os.path.join(self.cwd or "/", os.path.expanduser(target)))

    def go(self, target):
        self.prev, self.cwd = self.cwd, self.resolve(target)


# --- reading the command --------------------------------------------------

HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def cut_heredocs(text):
    """Replace each heredoc with a placeholder word; return text and bodies."""
    lines = text.split("\n")
    out, bodies = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        pending = []

        def mark(m):
            pending.append((m.group(1) == "-", m.group(3)))
            return " __HEREDOC_%d__ " % (len(bodies) + len(pending) - 1)

        # A `<<<` here-string is not a heredoc.
        line = re.sub(r"(?<!<)" + HEREDOC.pattern, mark, line)
        out.append(line)
        i += 1
        for strip_tabs, word in pending:
            body = []
            while i < len(lines):
                cand = lines[i].lstrip("\t") if strip_tabs else lines[i]
                i += 1
                if cand == word:
                    break
                body.append(lines[i - 1])
            bodies.append("\n".join(body))
    return "\n".join(out), bodies


def cut_substitutions(text, subs):
    """Pull out $(...), `...`, <(...) and >(...); turn unquoted newlines
    into `;`. Each substitution becomes a placeholder word, and its text is
    appended to `subs` to be analysed as a command of its own."""
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if text[i + 1] == "\n":
                i += 2
                continue
            out.append(text[i:i + 2])
            i += 2
            continue
        if quote is None and text.startswith("$'", i):
            j, raw = i + 2, []
            while j < n and text[j] != "'":
                step = 2 if text[j] == "\\" and j + 1 < n else 1
                raw.append(text[j:j + step])
                j += step
            out.append(shlex.quote(ansi_c("".join(raw))))
            i = j + 1
            continue
        if quote is None and text.startswith('$"', i):
            i += 1  # a locale string reads as a plain double-quoted one
            continue
        if quote is None and c == "'":
            quote = "'"
            out.append(c)
            i += 1
            continue
        if c == '"':
            quote = None if quote == '"' else '"'
            out.append(c)
            i += 1
            continue
        opener = text[i:i + 2]
        if opener == "$(" or (quote is None and opener in ("<(", ">(")):
            depth, j, q = 1, i + 2, None
            while j < n and depth:
                ch = text[j]
                if q:
                    if ch == q:
                        q = None
                    elif ch == "\\" and q == '"':
                        j += 1
                elif ch in "'\"":
                    q = ch
                elif ch == "\\":
                    j += 1
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                j += 1
            subs.append(text[i + 2:j - 1])
            out.append("__SUBST__")
            i = j
            continue
        if c == "`":
            j = text.find("`", i + 1)
            j = n if j < 0 else j
            subs.append(text[i + 1:j])
            out.append("__SUBST__")
            i = j + 1
            continue
        if c == "\n" and quote is None:
            out.append(" ; ")
            i += 1
            continue
        if c == "#" and quote is None and (i == 0 or text[i - 1] in " \t\n;&|("):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def ansi_c(raw):
    """Decode the body of a bash $'...' string the way bash would."""
    try:
        import codecs
        return codecs.decode(raw.replace("\\'", "'").replace("\\e", "\\x1b"),
                             "unicode_escape")
    except Exception:
        return raw


SEPARATORS = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")", "{", "}", "!"}
REDIRECTS = {">", ">>", "<", "<>", ">&", "<&", "&>", "&>>", ">|"}
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "time", "!"}


OPERATORS = sorted(SEPARATORS | REDIRECTS | {"<<<"}, key=len, reverse=True)


def split_operators(tokens):
    """shlex returns a run of punctuation as one token: `);` or `)|`. Split
    such a run into the operators it is made of, longest first."""
    out = []
    for t in tokens:
        if t and not t.strip(";&|()<>") and t not in OPERATORS:
            while t:
                op = next((o for o in OPERATORS if t.startswith(o)), t[0])
                out.append(op)
                t = t[len(op):]
        else:
            out.append(t)
    return out


def segments(text):
    """Split into simple commands. Yields (operator before it, words); a
    subshell's parentheses come through as their own ("(", None) and
    (")", None) so the caller can scope a cd inside one."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    tokens = split_operators(list(lex))
    seg, op, out = [], None, []
    k = 0
    while k < len(tokens):
        t = tokens[k]
        nxt = tokens[k + 1] if k + 1 < len(tokens) else None
        if t in SEPARATORS:
            if seg:
                out.append((op, seg))
            seg = []
            if t in ("(", ")"):
                out.append((t, None))
                op = None
            else:
                op = t
        elif t.isdigit() and nxt in REDIRECTS:
            pass  # the fd number in 2>/dev/null is not a word of the command
        elif t == "<" and nxt is not None:
            seg += ["__STDIN_FILE__", nxt]
            k += 1
        elif t in REDIRECTS:
            k += 1  # its target
        elif t == "<<<":
            if nxt is not None:
                seg += ["__HERESTRING__", nxt]
            k += 1
        else:
            seg.append(t)
        k += 1
    if seg:
        out.append((op, seg))
    return out


def analyze_text(text, ctx, res, depth=0, bodies=None):
    if depth > MAX_DEPTH:
        res.no("the command nests shells or eval more than %d deep" % MAX_DEPTH)
        return
    text, own = cut_heredocs(text)
    bodies = (bodies or []) + []
    base = len(bodies)
    if own:
        # Placeholders are numbered per call; shift them past inherited ones.
        text = re.sub(r"__HEREDOC_(\d+)__",
                      lambda m: "__HEREDOC_%d__" % (int(m.group(1)) + base), text)
        bodies.extend(own)
    subs = []
    text = cut_substitutions(text, subs)
    for sub in subs:
        analyze_text(sub, ctx.copy(), res, depth + 1, bodies)
    outer, prev = [], None
    for op, seg in segments(text):
        if op == "(":
            outer.append(ctx)
            ctx, prev = ctx.copy(), None
            continue
        if op == ")":
            ctx, prev = (outer.pop() if outer else ctx), None
            continue
        piped = piped_text(prev, ctx, bodies) if op in ("|", "|&") and prev else []
        analyze_argv(seg, ctx, res, depth, bodies, piped)
        prev = seg


def piped_text(seg, ctx, bodies):
    """What a command writes to the next one in a pipeline, where it can be
    read without running anything: a heredoc, echo or printf arguments, or
    the files cat reads."""
    out = list(heredoc_bodies(seg, bodies)) + stdin_files(seg, ctx)
    try:
        argv = unwrap(plain_args(seg), Result())
    except ValueError:
        return out
    if not argv:
        return out
    name, args = os.path.basename(argv[0]), argv[1:]
    if name == "echo":
        out.append(" ".join(a for a in args if not re.match(r"^-[neE]+$", a)))
    elif name == "printf":
        out.extend(a.replace("\\n", "\n") for a in args)
    elif name == "cat":
        for a in args:
            if not a.startswith("-"):
                body = read_small(a, ctx.cwd)
                out.append(body if body is not None else "")
    return out


def stdin_files(seg, ctx):
    out = []
    for k, a in enumerate(seg):
        if a == "__STDIN_FILE__" and k + 1 < len(seg):
            body = read_small(seg[k + 1], ctx.cwd)
            out.append(body if body is not None else "")
    return out


# --- commands ---------------------------------------------------------------

ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "mksh", "fish"}
INTERPRETERS = re.compile(r"^(python[0-9.]*|node|nodejs|deno|bun|ruby|perl|php)$")


def check_assignment(name, value, res):
    up = name.upper()
    if up == "GIT_CONFIG_PARAMETERS" and "hookspath" in value.lower():
        res.no("GIT_CONFIG_PARAMETERS sets core.hooksPath, which skips Git hooks")
    if up.startswith("GIT_CONFIG_KEY_") and value.lower() == "core.hookspath":
        res.no("GIT_CONFIG_KEY_* sets core.hooksPath, which skips Git hooks")
    if up == "HUSKY" and value == "0":
        res.no("HUSKY=0 skips Git hooks")


def heredoc_bodies(argv, bodies):
    found = []
    for a in argv:
        m = re.match(r"^__HEREDOC_(\d+)__$", a)
        if m and int(m.group(1)) < len(bodies):
            found.append(bodies[int(m.group(1))])
    for k, a in enumerate(argv):
        if a == "__HERESTRING__" and k + 1 < len(argv):
            found.append(argv[k + 1])
    return found


def plain_args(argv):
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in ("__HERESTRING__", "__STDIN_FILE__"):
            skip = True
            continue
        if re.match(r"^__HEREDOC_\d+__$", a):
            continue
        out.append(a)
    return out


# Wrappers that run the command after their own options, and which of those
# options take a value (short options may also carry it attached: -n1, -oL).
WRAPPERS = {
    "command": ("", ()), "builtin": ("", ()), "nohup": ("", ()),
    "noglob": ("", ()), "time": ("", ()),
    "exec": ("a", ()),
    "sudo": ("ugCDhprtUTR", ("--user", "--group", "--close-from", "--chdir", "--host",
                             "--prompt", "--role", "--type", "--other-user",
                             "--command-timeout", "--chroot")),
    "doas": ("uC", ()),
    "nice": ("n", ("--adjustment",)),
    "timeout": ("sk", ("--signal", "--kill-after")),
    "stdbuf": ("ioe", ("--input", "--output", "--error")),
    "xargs": ("InPLdEsa", ("--max-args", "--max-procs", "--max-lines", "--delimiter",
                            "--eof", "--max-chars", "--arg-file", "--replace", "--process-slot-var")),
    "env": ("uCS", ("--unset", "--chdir", "--split-string")),
}


def strip_options(name, argv, res):
    """Drop a wrapper's own options; return (rest, value of env -S or None)."""
    short_vals, long_vals = WRAPPERS[name]
    split = None
    while argv:
        a = argv[0]
        if a == "--":
            return argv[1:], split
        if name == "env" and a == "-":
            argv = argv[1:]
            continue
        if name == "env" and ASSIGN.match(a):
            m = ASSIGN.match(a)
            check_assignment(m.group(1), m.group(2), res)
            argv = argv[1:]
            continue
        if name == "nice" and re.match(r"^-\d+$", a):
            argv = argv[1:]
            continue
        if a.startswith("--") and len(a) > 2:
            opt, eq, val = a.partition("=")
            if opt in long_vals and not eq:
                val, argv = (argv[1] if len(argv) > 1 else ""), argv[1:]
            if opt == "--split-string":
                split = val
            argv = argv[1:]
            continue
        if a.startswith("-") and len(a) > 1:
            letter = a[1]
            if letter in short_vals:
                val = a[2:] if len(a) > 2 else (argv[1] if len(argv) > 1 else "")
                argv = argv[1:] if len(a) > 2 else argv[2:]
                if letter == "S" and name == "env":
                    split = val
            else:
                argv = argv[1:]
            continue
        return argv, split
    return argv, split


def unwrap(argv, res):
    """Strip assignments and wrapper commands; return the real argv."""
    while argv:
        m = ASSIGN.match(argv[0])
        if m:
            check_assignment(m.group(1), m.group(2), res)
            argv = argv[1:]
            continue
        name = os.path.basename(argv[0])
        if name not in WRAPPERS:
            return argv
        argv, split = strip_options(name, argv[1:], res)
        if split is not None:
            argv = shlex.split(split) + argv  # and unwrap what it split, too
        if name == "timeout" and argv:
            argv = argv[1:]  # the duration
        if argv and argv[0].startswith("-"):
            raise ValueError("unrecognised %s option %s" % (name, argv[0]))
    return argv


def analyze_argv(argv, ctx, res, depth, bodies, piped=()):
    while argv and argv[0] in KEYWORDS:
        argv = argv[1:]
    if not argv or argv[0] in ("for", "case", "select", "function"):
        return
    stdin = heredoc_bodies(argv, bodies) + stdin_files(argv, ctx) + list(piped)
    argv = unwrap(plain_args(argv), res)
    if not argv:
        return
    name = os.path.basename(argv[0])
    args = argv[1:]

    if name in ("cd", "pushd", "popd"):
        follow_cd(name, [a for a in args if a not in ("-P", "-L", "-e", "-@")], ctx)
        return
    if name in SHELLS:
        mode, code = shell_mode(args)
        texts = [code] if mode == "c" else (stdin if mode == "stdin" else [])
        for text in texts:
            analyze_text(text, ctx.copy(), res, depth + 1)
        return
    if name == "eval":
        analyze_text(" ".join(args), ctx, res, depth + 1)
        return
    if name == "trap":
        action = [a for a in args if a != "--" and not re.match(r"^-[lp]$", a)]
        if action:
            analyze_text(action[0], ctx.copy(), res, depth + 1)
        return
    if name in ("export", "declare", "typeset", "local", "readonly"):
        for a in args:
            m = ASSIGN.match(a)
            if m:
                check_assignment(m.group(1), m.group(2), res)
        return
    if INTERPRETERS.match(name):
        inline = interpreter_code(args)
        reads_stdin = not inline and not [a for a in args if not a.startswith("-")] or "-" in args
        for code in inline + (stdin if reads_stdin else []):
            analyze_code(code, ctx, res, depth + 1)
        return
    if name == "git":
        analyze_git(args, ctx, res, depth)
    elif name == "gh":
        analyze_gh(args, ctx, res, stdin)
    elif name == "rm":
        analyze_rm(args, res)
    elif name == "find":
        analyze_find(args, ctx, res, depth, bodies)


def follow_cd(name, args, ctx):
    if name == "popd":
        ctx.prev, ctx.cwd = ctx.cwd, (ctx.stack.pop() if ctx.stack else None)
    elif name == "pushd":
        if not args or args[0].startswith(("+", "-")):
            ctx.prev, ctx.cwd = ctx.cwd, None  # a rotation the analysis does not follow
        else:
            ctx.stack.append(ctx.cwd)
            ctx.go(args[0])
    elif not args:
        ctx.go("~")
    elif args[0] == "-":
        ctx.prev, ctx.cwd = ctx.cwd, ctx.prev
    else:
        ctx.go(args[0])


SHELL_VALUE_OPTIONS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}


def shell_mode(args):
    """("c", code) for sh -c CODE, ("stdin", None) when the shell reads its
    commands from standard input, ("script", path) when it runs a file."""
    k = 0
    while k < len(args):
        a = args[k]
        if a in SHELL_VALUE_OPTIONS:
            k += 2
            continue
        if a == "--":
            return ("script", args[k + 1]) if k + 1 < len(args) else ("stdin", None)
        if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a):
            j = k + 1
            while j < len(args) and args[j].startswith(("-", "+")):
                j += 2 if args[j] in SHELL_VALUE_OPTIONS else 1
            return ("c", args[j]) if j < len(args) else ("stdin", None)
        if re.match(r"^-[A-Za-z]*s[A-Za-z]*$", a):
            return "stdin", None
        if not a.startswith(("-", "+")):
            return "script", a
        k += 1
    return "stdin", None


def interpreter_code(args):
    out = []
    for k, a in enumerate(args):
        if a in ("-c", "-e", "-E", "--eval", "-p", "--print", "-r") and k + 1 < len(args):
            out.append(args[k + 1])
        elif re.match(r"^-[A-Za-z]*[ce]$", a) and k + 1 < len(args):
            out.append(args[k + 1])
    return out


CODE_DELETE = re.compile(
    r"rmtree|rm_rf|rm_r\b|FileUtils\.rm|removedirs|"
    r"rmSync\([^)]*recursive|fs\.rm\(|promises\.rm\(|rimraf|remove_tree")
STRING = re.compile(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"", re.S)
LIST_OF_STRINGS = re.compile(
    r"\[\s*((?:['\"][^'\"]*['\"]\s*,\s*)+['\"][^'\"]*['\"])\s*,?\s*\]")


SPAWNS = re.compile(
    r"subprocess|os\.system|os\.popen|os\.exec|os\.spawn|pty\.spawn|child_process|"
    r"execSync|execFile|spawnSync|\bspawn\(|\bsystem\(|Open3|IO\.popen|"
    r"Deno\.Command|Bun\.spawn|\$\.spawn|shell_exec|passthru|proc_open")


def analyze_code(code, ctx, res, depth):
    # A string is data unless the code can hand it to a process: a script
    # that edits a document about `git rm` is not running `git rm`. Deletion
    # is judged on the code with its strings taken out, for the same reason.
    if CODE_DELETE.search(STRING.sub('""', code)):
        res.no("code deletes a directory tree")
    if not SPAWNS.search(code):
        return
    for m in LIST_OF_STRINGS.finditer(code):
        words = [w[1:-1] for w in re.findall(r"'[^']*'|\"[^\"]*\"", m.group(1))]
        if words:
            analyze_argv(words, ctx, res, depth, [])
    for m in STRING.finditer(code):
        s = m.group(1) if m.group(1) is not None else m.group(2)
        if re.search(r"\b(git|gh|rm|find)\b", s):
            try:
                analyze_text(s, ctx, res, depth + 1)
            except ValueError:
                pass


# --- options ------------------------------------------------------------------

class Opts:
    def __init__(self):
        self.short = set()
        self.long = []        # (name, value or None)
        self.pos = []
        self.dashdash = False


def parse(args, short_vals="", long_vals=()):
    o = Opts()
    k = 0
    while k < len(args):
        a = args[k]
        if o.dashdash:
            o.pos.append(a)
        elif a == "--":
            o.dashdash = True
        elif a.startswith("--"):
            name, eq, val = a.partition("=")
            if not eq and name in long_vals and k + 1 < len(args):
                val = args[k + 1]
                k += 1
            o.long.append((name, val if eq or name in long_vals else None))
        elif a.startswith("-") and len(a) > 1 and not re.match(r"^-\d", a):
            for j, ch in enumerate(a[1:]):
                if ch in short_vals:
                    if j + 2 == len(a) and k + 1 < len(args):
                        k += 1
                    break
                o.short.add(ch)
        else:
            o.pos.append(a)
        k += 1
    return o


def has_long(o, full, minlen):
    """True for `full`, an unambiguous prefix of it (git accepts those), or a
    longer option that extends it (--force-with-lease extends --force)."""
    for name, _ in o.long:
        if name.startswith(full) or (len(name) >= minlen and full.startswith(name)):
            return True
    return False


# --- git ----------------------------------------------------------------------

GIT_BUILTINS = set("""
add am annotate apply archive bisect blame branch bundle cat-file check-attr
check-ignore check-mailmap check-ref-format checkout checkout-index cherry
cherry-pick citool clean clone column commit commit-graph commit-tree config
count-objects credential describe diff diff-files diff-index diff-tree
difftool fetch fetch-pack filter-branch fmt-merge-msg for-each-ref
for-each-repo format-patch fsck gc get-tar-commit-id grep gui hash-object help
hook index-pack init instaweb interpret-trailers log ls-files ls-remote
ls-tree mailinfo mailsplit maintenance merge merge-base merge-file merge-index
merge-tree mergetool mktag mktree multi-pack-index mv name-rev notes pack-objects
pack-redundant pack-refs patch-id prune prune-packed pull push range-diff
read-tree rebase reflog remote repack replace request-pull rerere reset restore
rev-list rev-parse revert rm send-email send-pack shortlog show show-branch
show-index show-ref sparse-checkout stash status stripspace submodule switch
symbolic-ref tag unpack-file unpack-objects update-index update-ref
update-server-info var verify-commit verify-pack verify-tag version whatchanged
worktree write-tree filter-repo lfs
""".split())

GIT_GLOBAL_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                    "--config-env", "--exec-path", "--super-prefix", "--list-cmds"}


def git_config_key(key, res, persistent=False, unset=False):
    k = key.lower()
    if k == "core.hookspath":
        if unset:
            res.no("unsetting core.hooksPath turns Git hooks off")
        elif persistent:
            res.check("changing core.hooksPath decides which Git hooks run")
        else:
            res.no("a one-off core.hooksPath override skips Git hooks")
    elif re.match(r"^remote\..+\.(url|pushurl)$", k):
        res.no("it rewrites a Git remote URL")
    elif re.match(r"^url\..+\.(insteadof|pushinsteadof)$", k):
        res.no("it rewrites Git remote URLs through insteadOf")


def run_git(directory, *args):
    left = DEADLINE - time.monotonic()
    if directory is None or left <= 0:
        return None
    try:
        p = subprocess.run(["git", "-C", directory] + list(args),
                           capture_output=True, text=True, timeout=min(2.0, left))
        return p.stdout.strip() if p.returncode == 0 else None
    except Exception:
        return None


def git_lines(directory, *args):
    out = run_git(directory, *args)
    return [line for line in (out or "").split("\n") if line]


def analyze_git(args, ctx, res, depth, alias_depth=0, overrides=None):
    directory = ctx.cwd
    overrides = dict(overrides or {})  # -c settings, which aliases can come from
    k = 0
    while k < len(args) and args[k].startswith("-"):
        a = args[k]
        name, eq, val = a.partition("=")
        if name in GIT_GLOBAL_VALUE and not eq:
            val = args[k + 1] if k + 1 < len(args) else ""
            k += 1
        if name == "-C":
            directory = Ctx(directory).resolve(val)
        elif name == "-c":
            key, _, value = val.partition("=")
            overrides[key.lower()] = value
            git_config_key(key, res)
        elif name == "--config-env":
            git_config_key(val.partition("=")[0], res)
        k += 1
    if k >= len(args):
        return
    sub, rest = args[k], args[k + 1:]

    if sub not in GIT_BUILTINS:
        key = "alias." + sub.lower()
        alias = overrides[key] if key in overrides else run_git(directory, "config", "--get", key)
        if not alias:
            return
        if alias_depth >= MAX_ALIAS_DEPTH:
            res.no("git alias %s is %d aliases deep, deeper than the guard follows"
                   % (sub, alias_depth))
            return
        if alias.startswith("!"):
            analyze_text(alias[1:] + " " + " ".join(shlex.quote(r) for r in rest),
                         Ctx(directory), res, depth + 1)
        else:
            analyze_git(shlex.split(alias) + rest, Ctx(directory), res, depth,
                        alias_depth + 1, overrides)
        return

    o = parse(rest, *GIT_VALUES.get(sub, ("", ())))
    if has_long(o, "--no-verify", len("--no-veri")):
        res.no("git %s --no-verify skips Git hooks" % sub)

    rule = GIT_RULES.get(sub)
    if rule:
        rule(o, directory, res)


GIT_VALUES = {
    "push": ("o", ("--repo", "--receive-pack", "--exec", "--push-option")),
    "commit": ("mFCctu", ("--message", "--file", "--reuse-message", "--reedit-message",
                          "--template", "--author", "--date", "--fixup", "--squash",
                          "--trailer", "--cleanup", "--pathspec-from-file")),
    "branch": ("tu", ("--track", "--set-upstream-to", "--contains", "--no-contains",
                      "--merged", "--no-merged", "--points-at", "--format", "--sort")),
    "tag": ("mFu", ("--message", "--file", "--local-user", "--contains", "--points-at",
                    "--format", "--sort", "--cleanup")),
    "checkout": ("bB", ("--orphan", "--conflict", "--pathspec-from-file")),
    "switch": ("cC", ("--create", "--force-create", "--orphan", "--conflict")),
    "restore": ("s", ("--source", "--pathspec-from-file", "--conflict")),
    "reset": ("", ("--pathspec-from-file",)),
    "clean": ("e", ("--exclude",)),
    "stash": ("m", ("--message", "--pathspec-from-file")),
    "worktree": ("b", ("--reason",)),
    "config": ("f", ("--file", "--blob", "--type", "--default", "--comment", "--value")),
}


def push_rule(o, directory, res):
    if has_long(o, "--force", len("--for")) or "f" in o.short:
        res.no("git push --force rewrites remote history")
    if has_long(o, "--mirror", len("--mi")):
        res.no("git push --mirror can delete and rewrite remote refs")
    if has_long(o, "--delete", len("--de")) or "d" in o.short:
        res.no("git push --delete deletes a remote ref")
    if has_long(o, "--prune", len("--pru")):
        res.no("git push --prune deletes remote refs")
    repo_opt = [v for n, v in o.long if n == "--repo" and v]
    remote = repo_opt[-1] if repo_opt else (o.pos[0] if o.pos else None)
    refspecs = o.pos if repo_opt else o.pos[1:]
    if has_long(o, "--dry-run", 4) or "n" in o.short:
        return  # a dry run sends nothing
    for spec in refspecs:
        if spec.startswith("+"):
            res.no("a +refspec force-pushes")
        if spec.startswith(":"):
            res.no("pushing an empty source deletes the remote ref %s" % spec[1:])
    current = run_git(directory, "symbolic-ref", "--short", "-q", "HEAD")
    if remote is None:
        remote = push_remote(directory, current)
    if sandbox_remote(directory, remote):
        return  # the checkpoint guards a shared remote, not a scratch repo
    # A release tag is a checkpoint: consumers pin to it and no agent may
    # delete one, so pushing it waits for the person to say yes.
    tag_push(o, refspecs, directory, res)
    defaults = default_branches(directory, remote)
    if has_long(o, "--all", len("--al")) or has_long(o, "--branches", len("--br")):
        res.check("git push --all pushes the default branch too")
        return
    if not refspecs:
        refspecs = bare_push_refspecs(directory, remote, current)
        if refspecs is None:
            res.check("a bare git push from %s may push the default branch"
                      % (current or "an unknown branch"))
            return
    for spec in refspecs:
        dest = spec.lstrip("+").split(":")[-1]
        if dest in ("HEAD", "@"):
            dest = current or "HEAD"
        dest = re.sub(r"^refs/heads/", "", dest)
        if dest in defaults or dest in ("HEAD", "") or "*" in dest:
            res.check("git push to %s may update the default branch, which bypasses "
                      "the pull request" % (dest or "every matching branch"))


def tag_push(o, refspecs, directory, res):
    if has_long(o, "--tags", len("--tag")) or has_long(o, "--follow-tags", len("--fo")):
        res.check("git push --tags or --follow-tags pushes tags, and a release tag "
                  "needs the user's go-ahead")
        return
    if (run_git(directory, "config", "--get", "push.followTags") or "").lower() in (
            "true", "yes", "on", "1"):
        res.check("push.followTags is set, so this push may carry a release tag")
        return
    for spec in refspecs:
        for side in spec.lstrip("+").split(":"):
            if not side or side.startswith("refs/heads/"):
                continue
            if side.startswith("refs/tags/"):
                found = side
            else:
                # None means git could not answer: unknown asks, like the rest.
                found = run_git(directory, "tag", "--list", "--", side)
            if found is None or found:
                res.check("git push %s may push a tag, and a release tag needs the "
                          "user's go-ahead" % spec)
                return


def push_remote(directory, branch):
    """The remote a bare push goes to, in git's order of precedence."""
    for key in (["branch.%s.pushRemote" % branch] if branch else []) + ["remote.pushDefault"] + (
            ["branch.%s.remote" % branch] if branch else []):
        value = run_git(directory, "config", "--get", key)
        if value:
            return value
    return "origin"


def bare_push_refspecs(directory, remote, current):
    """The refspecs a push with none on the command line uses, or None when
    the analysis cannot tell."""
    configured = git_lines(directory, "config", "--get-all", "remote.%s.push" % remote)
    if configured:
        return configured
    mode = run_git(directory, "config", "--get", "push.default") or "simple"
    if mode == "nothing":
        return []
    if current is None:
        return None
    if mode == "matching":
        return [":"]
    if mode in ("upstream", "tracking"):
        merge = run_git(directory, "config", "--get", "branch.%s.merge" % current)
        return [current + ":" + merge] if merge else None
    return [current]


SCRATCH_ROOTS = None


def scratch_roots():
    global SCRATCH_ROOTS
    if SCRATCH_ROOTS is None:
        roots = {tempfile.gettempdir(), os.environ.get("TMPDIR") or "",
                 os.environ.get("CLAUDE_JOB_DIR") or "", "/tmp", "/var/tmp",
                 "/private/tmp", "/private/var/folders", "/var/folders"}
        SCRATCH_ROOTS = {os.path.realpath(r) for r in roots if r}
    return SCRATCH_ROOTS


def sandbox_remote(directory, remote):
    """True when every URL the push goes to is a repository in a scratch
    directory on this machine. A path elsewhere on disk may be a shared
    mount, and is treated like any other remote."""
    urls = git_lines(directory, "config", "--get-all", "remote.%s.pushurl" % remote) or \
        git_lines(directory, "config", "--get-all", "remote.%s.url" % remote) or [remote]
    for url in urls:
        path = url[len("file://"):] if url.startswith("file://") else url
        if re.match(r"^[\w.+-]+://", path) or re.match(r"^[^/]*@[^/]*:", path) or directory is None:
            return False
        path = os.path.realpath(os.path.join(directory, os.path.expanduser(path)))
        if not os.path.isdir(path):
            return False
        if not any(path == r or path.startswith(r + os.sep) for r in scratch_roots()):
            return False
    return True


def default_branches(directory, remote="origin"):
    names = {"main", "master"}
    prefix = "refs/remotes/%s/" % remote
    head = run_git(directory, "symbolic-ref", "-q", prefix + "HEAD")
    if head and head.startswith(prefix):
        names.add(head[len(prefix):])
    return names


def commit_rule(o, directory, res):
    if "n" in o.short:
        res.no("git commit -n skips Git hooks")


def reset_rule(o, directory, res):
    for opt, minlen in (("--hard", 4), ("--merge", 4), ("--keep", 3)):
        if has_long(o, opt, minlen):
            res.no("git reset %s discards uncommitted work" % opt)


def clean_rule(o, directory, res):
    if "n" not in o.short and not has_long(o, "--dry-run", 4):
        res.no("git clean deletes untracked files")


def stash_rule(o, directory, res):
    if o.pos[:1] and o.pos[0] in ("drop", "clear"):
        res.no("git stash %s destroys stashed work" % o.pos[0])


def worktree_rule(o, directory, res):
    if o.pos[:1] and o.pos[0] == "remove":
        res.no("git worktree remove deletes a worktree")


def checkout_rule(o, directory, res):
    if o.dashdash and o.pos:
        res.no("git checkout -- <path> discards uncommitted changes")
    if "f" in o.short or has_long(o, "--force", 4):
        res.no("git checkout --force discards uncommitted changes")
    if "." in o.pos:
        res.no("git checkout . discards uncommitted changes")


def restore_rule(o, directory, res):
    staged = "S" in o.short or has_long(o, "--staged", 4)
    worktree = "W" in o.short or has_long(o, "--worktree", 4)
    if not staged or worktree:
        res.no("git restore discards uncommitted changes in the working tree")


def switch_rule(o, directory, res):
    if "f" in o.short or has_long(o, "--force", 4) or has_long(o, "--discard-changes", 4):
        res.no("git switch --discard-changes discards uncommitted changes")


def branch_rule(o, directory, res):
    if "d" in o.short or "D" in o.short or has_long(o, "--delete", 5):
        res.no("git branch -d/-D deletes a branch")


def tag_rule(o, directory, res):
    if "d" in o.short or has_long(o, "--delete", 5):
        res.no("git tag -d deletes a tag")


def update_ref_rule(o, directory, res):
    if "d" in o.short:
        res.no("git update-ref -d deletes a ref")
    if has_long(o, "--stdin", 4):
        res.check("git update-ref --stdin can delete or move refs")


def symbolic_ref_rule(o, directory, res):
    if "d" in o.short or has_long(o, "--delete", 4):
        res.no("git symbolic-ref --delete deletes a ref")


def rm_rule(o, directory, res):
    res.no("git rm deletes files (to unstage, use git restore --staged <path>)")


def remote_rule(o, directory, res):
    if o.pos[:1] and o.pos[0] in ("remove", "rm", "set-url"):
        res.no("git remote %s removes or rewrites a remote" % o.pos[0])


def config_rule(o, directory, res):
    verb = o.pos[0] if o.pos[:1] and o.pos[0] in (
        "set", "unset", "get", "list", "rename-section", "remove-section", "edit") else None
    keys = o.pos[1:] if verb else o.pos
    unset = verb in ("unset", "remove-section") or any(
        n in ("--unset", "--unset-all", "--remove-section") for n, _ in o.long)
    write = unset or verb in ("set", "rename-section") or any(
        n in ("--replace-all", "--add", "--rename-section") for n, _ in o.long) or (
        verb is None and len(keys) >= 2)
    if verb == "edit" or "e" in o.short or has_long(o, "--edit", 4):
        res.check("editing the Git config by hand can change hooks or remotes")
    section_op = verb in ("rename-section", "remove-section") or any(
        n in ("--rename-section", "--remove-section") for n, _ in o.long)
    if section_op and keys:
        section = keys[0].lower()
        if section == "core":
            res.no("removing or renaming the core section unsets core.hooksPath")
        elif section.startswith(("remote.", "url.")) or section in ("remote", "url"):
            res.no("removing or renaming a remote or url section rewrites a remote")
        return
    if write and keys:
        value = keys[1] if len(keys) > 1 else ""
        off = value in ("/dev/null", "") and not unset
        git_config_key(keys[0], res, persistent=True, unset=unset or off)


def reflog_rule(o, directory, res):
    if o.pos[:1] and o.pos[0] in ("expire", "delete"):
        res.no("git reflog %s destroys recovery points" % o.pos[0])


def gc_rule(o, directory, res):
    for name, val in o.long:
        if name.startswith("--prune") and val in ("now", "all"):
            res.no("git gc --prune=now deletes unreachable commits")


def history_rule(o, directory, res):
    res.no("filter-branch / filter-repo rewrites history")


def commit_tree_rule(o, directory, res):
    res.no("git commit-tree creates a commit without running Git hooks")


GIT_RULES = {
    "push": push_rule, "commit": commit_rule, "reset": reset_rule,
    "clean": clean_rule, "stash": stash_rule, "worktree": worktree_rule,
    "checkout": checkout_rule, "restore": restore_rule, "switch": switch_rule,
    "branch": branch_rule, "tag": tag_rule, "update-ref": update_ref_rule,
    "symbolic-ref": symbolic_ref_rule, "rm": rm_rule, "remote": remote_rule,
    "config": config_rule, "reflog": reflog_rule, "gc": gc_rule,
    "filter-branch": history_rule, "filter-repo": history_rule,
    "commit-tree": commit_tree_rule,
}


# --- gh -----------------------------------------------------------------------

GRAPHQL_DENY = re.compile(r"\bdelete[A-Z]\w*")
GRAPHQL_ASK = re.compile(
    r"\b(mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|"
    r"closePullRequest|reopenPullRequest|updateRepository|"
    r"createBranchProtectionRule|updateBranchProtectionRule|updateRef)\b")
GRAPHQL_APPROVE = re.compile(r"\b(addPullRequestReview|submitPullRequestReview)\b[\s\S]*APPROVE")
REPO_SETTINGS = re.compile(
    r"^repos/[^/]+/[^/]+(/(protection|rulesets?|collaborators|environments|hooks|keys|"
    r"actions/permissions|transfer|topics|branches/[^/]+/(protection|rename))(/.*)?)?$")


def analyze_gh(args, ctx, res, stdin=()):
    o = parse(args, "RXfFHqtpb", ("--repo", "--method", "--field", "--raw-field",
                                    "--header", "--input", "--jq", "--template",
                                    "--hostname", "--body", "--body-file", "--subject",
                                    "--match-head-commit", "--author-email", "--cache"))
    words = o.pos
    if not words:
        return
    group, action = words[0], words[1] if len(words) > 1 else ""
    if group != "api" and action in ("delete", "delete-asset"):
        res.no("gh %s %s deletes it" % (group, action))
        return
    if group == "pr":
        delete_branch = "d" in o.short or has_long(o, "--delete-branch", 5)
        if action == "merge":
            res.check("gh pr merge merges a pull request")
            if delete_branch:
                res.no("gh pr merge --delete-branch deletes a branch")
        elif action in ("close", "reopen"):
            res.check("gh pr %s changes a shared review" % action)
            if delete_branch:
                res.no("gh pr close --delete-branch deletes a branch")
        elif action == "review" and ("a" in o.short or has_long(o, "--approve", 4)):
            res.check("gh pr review --approve approves a pull request; an agent never approves its own work")
        elif action == "comment":
            body = " ".join(v for n, v in o.long if n in ("--body",) and v) + " " + gh_short_value(args, "-b")
            if re.search(r"(^|\s)(/merge\b|bors r\+|bors merge|@dependabot merge)", body):
                res.check("the comment asks a bot to merge")
    elif group == "release" and action in ("create", "edit", "upload"):
        # A release is published to everyone who watches the repository, and
        # `create` also pushes the tag when it does not exist yet.
        res.check("gh release %s publishes a release, and a release is a checkpoint" % action)
    elif group == "repo" and action in ("edit", "rename", "archive", "unarchive"):
        res.check("gh repo %s changes repository settings" % action)
    elif group == "workflow" and action == "disable":
        res.check("gh workflow disable turns a check off")
    elif group == "api":
        analyze_gh_api(args, o, res, ctx, stdin)


def gh_short_value(args, flag):
    for k, a in enumerate(args):
        if a == flag and k + 1 < len(args):
            return args[k + 1]
    return ""


def analyze_gh_api(args, o, res, ctx, stdin=()):
    method = None
    fields = []
    unread = []
    k = 0
    while k < len(args):
        a = args[k]
        nxt = args[k + 1] if k + 1 < len(args) else ""
        if a in ("-X", "--method"):
            method = nxt
            k += 1
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:]
        elif a.startswith("--method="):
            method = a.split("=", 1)[1]
        elif a in ("-f", "-F", "--field", "--raw-field"):
            fields.append(nxt)
            k += 1
        elif a.startswith(("--field=", "--raw-field=")):
            fields.append(a.split("=", 1)[1])
        elif a == "--input" or a.startswith("--input="):
            path = nxt if a == "--input" else a.split("=", 1)[1]
            k += 1 if a == "--input" else 0
            body = "\n".join(stdin) if path == "-" else read_small(path, ctx.cwd)
            if body is None or (path == "-" and not stdin):
                unread.append(path)
            fields.append(body or "")
        k += 1
    for k, f in enumerate(fields):
        name, eq, value = f.partition("=")
        if eq and value.startswith("@"):
            body = "\n".join(stdin) if value == "@-" else read_small(value[1:], ctx.cwd)
            if body is None:
                unread.append(value[1:])
            fields[k] = name + "=" + (body or "")
    method = (method or ("POST" if fields else "GET")).upper()
    endpoint = o.pos[1] if len(o.pos) > 1 else ""
    endpoint = endpoint.lstrip("/").split("?")[0]
    body = "\n".join(fields)
    if method == "DELETE":
        res.no("a GitHub API DELETE request")
        return
    if unread and (endpoint == "graphql" or method != "GET"):
        res.check("the request body (%s) could not be read, so it was not checked"
                  % ", ".join(unread))
    if endpoint == "graphql":
        if GRAPHQL_DENY.search(body):
            res.no("the GraphQL mutation deletes a ref, repository or protection rule")
        if GRAPHQL_ASK.search(body):
            res.check("the GraphQL mutation merges, closes, or changes repository settings")
        if GRAPHQL_APPROVE.search(body):
            res.check("the GraphQL mutation approves a pull request")
        return
    if method == "GET":
        return
    if re.search(r"pulls/\d+/merge$", endpoint):
        res.check("the API call merges a pull request")
    if re.search(r"pulls/\d+/reviews", endpoint) and "APPROVE" in body.upper():
        res.check("the API call approves a pull request")
    if re.search(r"(pulls|issues)/\d+$", endpoint) and re.search(r"state=(closed|open)", body):
        res.check("the API call closes or reopens a pull request")
    if re.search(r"git/refs/", endpoint) and re.search(r"force=true", body):
        res.no("the API call force-updates a ref")
    if re.search(r"git/refs/heads/(main|master)$", endpoint):
        res.check("the API call updates the default branch directly")
    if re.search(r"(^|/)releases(/|$)", endpoint) or re.search(r"git/refs(/tags)?$", endpoint) and re.search(r"refs/tags/", body):
        res.check("the API call publishes a release or a tag, and either is a checkpoint")
    if REPO_SETTINGS.match(endpoint):
        res.check("the API call changes repository settings or protection")


def read_small(path, cwd=None):
    """The file's text, or None when it cannot be read, is not a regular
    file, or is too large to be a request body: the caller decides what not
    knowing means. A device such as /dev/urandom reports size 0 and never
    ends, so size alone is not a bound."""
    try:
        full = os.path.join(cwd or os.getcwd(), os.path.expanduser(path))
        st = os.stat(full)
        if stat.S_ISREG(st.st_mode) and st.st_size < 262144:
            with open(full, encoding="utf-8", errors="replace") as fh:
                return fh.read()
    except Exception:
        pass
    return None


# --- rm, find -----------------------------------------------------------------

def analyze_rm(args, res):
    o = parse(args)
    if "r" in o.short or "R" in o.short or has_long(o, "--recursive", 5):
        res.no("rm -r deletes a directory tree")


def analyze_find(args, ctx, res, depth, bodies):
    if "-delete" in args:
        res.no("find -delete deletes files")
    k = 0
    while k < len(args):
        if args[k] in ("-exec", "-execdir", "-ok", "-okdir"):
            j = k + 1
            while j < len(args) and args[j] not in (";", "+", "\\;"):
                j += 1
            analyze_argv(args[k + 1:j], ctx, res, depth + 1, bodies)
            k = j
        k += 1


# --- entry point --------------------------------------------------------------

SUSPECT = re.compile(r"\b(git|gh|rm|find|eval|xargs|bash|sh|zsh|python[0-9.]*|node|ruby|perl)\b")


def decide(command, cwd):
    res = Result()
    try:
        analyze_text(command, Ctx(cwd), res)
    except Exception as exc:  # unparseable: fail closed only where it matters
        if SUSPECT.search(command):
            res.no("the guard could not parse the command (%s: %s)" % (type(exc).__name__, exc))
    return res


ANSWERED = False


def emit(decision, reason):
    """Print the answer, at most once: a hook that prints two JSON objects
    gives Codex something it cannot read. In Codex mode the watchdog is
    disarmed first, and SIGALRM ignored, so it cannot land after this point,
    even if it had already tripped and not yet run."""
    global ANSWERED
    if ANSWERED:
        return
    if CODEX:
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        signal.alarm(0)
    ANSWERED = True
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))
    sys.stdout.flush()


def run():
    try:
        data = json.load(sys.stdin)
    except Exception:
        emit("deny", GUARD + ": the hook input was not JSON, so the command was not checked.")
        return
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or os.getcwd()
    res = decide(command, cwd)
    if res.deny:
        emit("deny", GUARD + ": " + "; ".join(res.deny) + ". " + PROHIBITED)
    elif res.ask and CODEX:
        emit("deny", GUARD + ": " + "; ".join(res.ask) + ". " + CODEX_CHECKPOINT)
    elif res.ask:
        emit("ask", GUARD + ": " + "; ".join(res.ask) + ". " + CHECKPOINT)


def main():
    if not CODEX:
        run()
        return 0
    # Codex runs the command when a hook exits non-zero, so a failure has to
    # leave as a deny and an exit status of 0. So does a hang: Codex also runs
    # the command when the hook overruns its 10 s timeout, so a watchdog
    # answers deny at 8 s, past DEADLINE's 6 s budget for git lookups.
    def overrun(signum, frame):
        emit("deny", "%s: the guard did not finish in time, so the command was not checked." % GUARD)
        os._exit(0)  # emit prints nothing if an answer is already out
    signal.signal(signal.SIGALRM, overrun)
    signal.alarm(8)
    try:
        run()
    except Exception as exc:
        emit("deny", "%s: the guard failed (%s: %s), so the command was not checked."
             % (GUARD, type(exc).__name__, exc))
    signal.alarm(0)  # an answer was not needed (or emit has already done this)
    return 0


if __name__ == "__main__":
    sys.exit(main())
