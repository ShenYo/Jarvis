#!/usr/bin/env python3
"""Claude Code PreToolUse guard for the Bash tool.

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

Compatible with Python 3.9, the version macOS ships at /usr/bin/python3.
"""
import json
import os
import re
import shlex
import subprocess
import sys

MAX_DEPTH = 6

PROHIBITED = (
    "This is permanently prohibited for agents, even when the user asks. "
    "State the exact command and its target, and ask the user to run it "
    "themselves."
)
CHECKPOINT = "This is a human-review checkpoint: a person decides it."


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
    def __init__(self, cwd):
        self.cwd = cwd


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


SEPARATORS = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")", "{", "}", "!"}
REDIRECTS = {">", ">>", "<", "<>", ">&", "<&", "&>", "&>>", ">|"}
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "time", "!"}


def segments(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    seg, segs = [], []
    tokens = list(lex)
    k = 0
    while k < len(tokens):
        t = tokens[k]
        if t in SEPARATORS:
            if seg:
                segs.append(seg)
            seg = []
        elif t in REDIRECTS:
            k += 1  # its target
        elif t == "<<<":
            if k + 1 < len(tokens):
                seg.append("__HERESTRING__")
                seg.append(tokens[k + 1])
            k += 1
        else:
            seg.append(t)
        k += 1
    if seg:
        segs.append(seg)
    return segs


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
        analyze_text(sub, ctx, res, depth + 1, bodies)
    for seg in segments(text):
        analyze_argv(seg, ctx, res, depth, bodies)


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
        if a == "__HERESTRING__":
            skip = True
            continue
        if re.match(r"^__HEREDOC_\d+__$", a):
            continue
        out.append(a)
    return out


def unwrap(argv, res):
    """Strip assignments and wrapper commands; return the real argv."""
    while argv:
        m = ASSIGN.match(argv[0])
        if m:
            check_assignment(m.group(1), m.group(2), res)
            argv = argv[1:]
            continue
        name = os.path.basename(argv[0])
        if name in ("command", "builtin", "exec", "nohup", "noglob", "time", "sudo", "doas"):
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                if name in ("sudo", "doas") and argv[0] in ("-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t"):
                    argv = argv[1:]
                argv = argv[1:]
            continue
        if name == "env":
            argv = argv[1:]
            while argv:
                a = argv[0]
                if a in ("-u", "--unset", "-C", "--chdir"):
                    argv = argv[2:]
                elif a in ("-S", "--split-string") and len(argv) > 1:
                    return shlex.split(argv[1]) + argv[2:]
                elif a.startswith("-"):
                    argv = argv[1:]
                elif ASSIGN.match(a):
                    mm = ASSIGN.match(a)
                    check_assignment(mm.group(1), mm.group(2), res)
                    argv = argv[1:]
                else:
                    break
            continue
        if name == "nice":
            argv = argv[1:]
            if argv and argv[0] == "-n":
                argv = argv[2:]
            elif argv and re.match(r"^-\d+$", argv[0]):
                argv = argv[1:]
            continue
        if name == "timeout":
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[2:] if argv[0] in ("-s", "--signal", "-k", "--kill-after") else argv[1:]
            argv = argv[1:]  # the duration
            continue
        if name == "stdbuf":
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[2:] if argv[0] in ("-i", "-o", "-e") else argv[1:]
            continue
        if name == "xargs":
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                takes = argv[0] in ("-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a")
                argv = argv[2:] if takes else argv[1:]
            continue
        return argv
    return argv


def analyze_argv(argv, ctx, res, depth, bodies):
    while argv and argv[0] in KEYWORDS:
        argv = argv[1:]
    if not argv or argv[0] in ("for", "case", "select", "function"):
        return
    attached = heredoc_bodies(argv, bodies)
    argv = unwrap(plain_args(argv), res)
    if not argv:
        return
    name = os.path.basename(argv[0])
    args = argv[1:]

    if name == "cd":
        target = args[0] if args else os.path.expanduser("~")
        if target != "-":
            ctx.cwd = os.path.normpath(os.path.join(ctx.cwd, os.path.expanduser(target)))
        return
    if name in SHELLS:
        code = shell_c(args)
        for text in ([code] if code is not None else []) + (attached if code is None else []):
            analyze_text(text, ctx, res, depth + 1)
        return
    if name in ("eval", "trap"):
        analyze_text(args[0] if name == "trap" and args else " ".join(args), ctx, res, depth + 1)
        return
    if name in ("export", "declare", "typeset", "local", "readonly"):
        for a in args:
            m = ASSIGN.match(a)
            if m:
                check_assignment(m.group(1), m.group(2), res)
        return
    if INTERPRETERS.match(name):
        for code in interpreter_code(args) + attached:
            analyze_code(code, ctx, res, depth + 1)
        return
    if name == "git":
        analyze_git(args, ctx, res, depth)
    elif name == "gh":
        analyze_gh(args, ctx, res)
    elif name == "rm":
        analyze_rm(args, res)
    elif name == "find":
        analyze_find(args, ctx, res, depth, bodies)


def shell_c(args):
    for k, a in enumerate(args):
        if a == "--":
            return None
        if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a):
            rest = [x for x in args[k + 1:] if not x.startswith("-")]
            return rest[0] if rest else None
        if not a.startswith(("-", "+")):
            return None
    return None


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
    try:
        p = subprocess.run(["git", "-C", directory] + list(args),
                           capture_output=True, text=True, timeout=3)
        return p.stdout.strip() if p.returncode == 0 else None
    except Exception:
        return None


def analyze_git(args, ctx, res, depth, alias_depth=0):
    directory = ctx.cwd
    k = 0
    while k < len(args) and args[k].startswith("-"):
        a = args[k]
        name, eq, val = a.partition("=")
        if name in GIT_GLOBAL_VALUE and not eq:
            val = args[k + 1] if k + 1 < len(args) else ""
            k += 1
        if name == "-C":
            directory = os.path.normpath(os.path.join(directory, os.path.expanduser(val)))
        elif name == "-c":
            git_config_key(val.partition("=")[0], res)
        elif name == "--config-env":
            git_config_key(val.partition("=")[0], res)
        k += 1
    if k >= len(args):
        return
    sub, rest = args[k], args[k + 1:]

    if sub not in GIT_BUILTINS:
        alias = run_git(directory, "config", "--get", "alias." + sub)
        if alias and alias_depth < 4:
            if alias.startswith("!"):
                analyze_text(alias[1:] + " " + " ".join(shlex.quote(r) for r in rest),
                             Ctx(directory), res, depth + 1)
            else:
                analyze_git(shlex.split(alias) + rest, Ctx(directory), res, depth, alias_depth + 1)
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
    refspecs = o.pos[1:]
    if has_long(o, "--dry-run", 4) or "n" in o.short:
        return  # a dry run sends nothing
    for spec in refspecs:
        if spec.startswith("+"):
            res.no("a +refspec force-pushes")
        if spec.startswith(":"):
            res.no("pushing an empty source deletes the remote ref %s" % spec[1:])
    if local_remote(directory, o.pos[0] if o.pos else None):
        return  # the checkpoint guards a shared remote, not a sandbox on this disk
    defaults = default_branches(directory)
    if has_long(o, "--all", len("--al")) or has_long(o, "--branches", len("--br")):
        res.check("git push --all pushes the default branch too")
    if not refspecs:
        current = run_git(directory, "symbolic-ref", "--short", "-q", "HEAD")
        if current is None or current in defaults:
            res.check("a bare git push from %s pushes the default branch"
                      % (current or "an unknown branch"))
        return
    for spec in refspecs:
        dest = spec.lstrip("+").split(":")[-1]
        if dest == "HEAD":
            dest = run_git(directory, "symbolic-ref", "--short", "-q", "HEAD") or "HEAD"
        dest = re.sub(r"^refs/heads/", "", dest)
        if dest in defaults:
            res.check("git push to the default branch %s bypasses the pull request" % dest)


def local_remote(directory, remote):
    """True when the push goes to a repository on this machine."""
    if remote is None:
        branch = run_git(directory, "symbolic-ref", "--short", "-q", "HEAD")
        remote = (branch and run_git(directory, "config", "--get", "branch.%s.remote" % branch)) or "origin"
    url = run_git(directory, "config", "--get", "remote.%s.url" % remote) or remote
    if url.startswith("file://"):
        return True
    if re.match(r"^[\w.+-]+://", url) or re.match(r"^[^/]*@[^/]*:", url):
        return False
    path = os.path.join(directory, os.path.expanduser(url))
    return os.path.isdir(path)


def default_branches(directory):
    names = {"main", "master"}
    head = run_git(directory, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    if head:
        names.add(head.split("/")[-1])
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

GRAPHQL_DENY = re.compile(r"\b(deleteRef|deleteRepository|deleteBranchProtectionRule)\b")
GRAPHQL_ASK = re.compile(
    r"\b(mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|"
    r"closePullRequest|reopenPullRequest|updateRepository|"
    r"createBranchProtectionRule|updateBranchProtectionRule|updateRef)\b")
GRAPHQL_APPROVE = re.compile(r"\b(addPullRequestReview|submitPullRequestReview)\b[\s\S]*APPROVE")
REPO_SETTINGS = re.compile(
    r"^repos/[^/]+/[^/]+(/(protection|rulesets?|collaborators|environments|hooks|keys|"
    r"actions/permissions|transfer|topics|branches/[^/]+/(protection|rename))(/.*)?)?$")


def analyze_gh(args, ctx, res):
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
    elif group == "repo" and action in ("edit", "rename", "archive", "unarchive"):
        res.check("gh repo %s changes repository settings" % action)
    elif group == "workflow" and action == "disable":
        res.check("gh workflow disable turns a check off")
    elif group == "api":
        analyze_gh_api(args, o, res)


def gh_short_value(args, flag):
    for k, a in enumerate(args):
        if a == flag and k + 1 < len(args):
            return args[k + 1]
    return ""


def analyze_gh_api(args, o, res):
    method = None
    fields = []
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
        elif a == "--input":
            fields.append(read_small(nxt))
            k += 1
        k += 1
    method = (method or ("POST" if fields else "GET")).upper()
    endpoint = o.pos[1] if len(o.pos) > 1 else ""
    endpoint = endpoint.lstrip("/").split("?")[0]
    body = "\n".join(f if not f.startswith("query=@") else read_small(f[7:]) for f in fields)
    if method == "DELETE":
        res.no("a GitHub API DELETE request")
        return
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
    if REPO_SETTINGS.match(endpoint):
        res.check("the API call changes repository settings or protection")


def read_small(path):
    try:
        if os.path.getsize(path) < 262144:
            with open(path, encoding="utf-8", errors="replace") as fh:
                return fh.read()
    except Exception:
        pass
    return ""


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


def emit(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        emit("deny", "Claude guard: the hook input was not JSON, so the command was not checked.")
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or os.getcwd()
    res = decide(command, cwd)
    if res.deny:
        emit("deny", "Claude guard: " + "; ".join(res.deny) + ". " + PROHIBITED)
    elif res.ask:
        emit("ask", "Claude guard: " + "; ".join(res.ask) + ". " + CHECKPOINT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
