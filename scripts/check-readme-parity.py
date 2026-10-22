#!/usr/bin/env python3
"""Check that two language versions of a document stayed in step.

Bilingual docs double the surface a mistake can live on, and the mistakes are
quiet: a section added to one file, a count corrected in one file, a link that
rots in one file. This repository and Friday have both shipped exactly that.

What this refuses, and why each check exists:

  structure   `##` / `###` / fenced-block counts must match. Catches a section
              added or dropped on one side.
  numbers     the set of numbers appearing must match. Catches a count
              corrected in one file only -- Jarvis's inventory is 36/36/36/35
              and has been wrong in one language before.
  links       the set of relative links must match, and every one must
              resolve. Catches a path renamed on one side, and dead links on
              both.
  stale       a term listed in the stale-terms file must appear in NEITHER
              file. This is the one that comes from a real failure: the
              managed core grew from eleven files to fourteen, the lists were
              updated, and four sentences were not -- in BOTH languages, so it
              was not a translation drift. The check that missed it looked for
              the English word in the English file and the Chinese word in the
              Chinese file, and never saw the Chinese summary block sitting
              inside the English file. An asymmetric check cannot see its own
              blind spot, so every term is checked against every file.
"""
import re
import sys
from pathlib import Path


def sections(text, level):
    return len(re.findall(rf"^{'#' * level} ", text, re.M))


def fences(text):
    return len(re.findall(r"^```", text, re.M))


def numbers(text):
    # Standalone numbers only: 36, 14. Not the 2 in `h2`, not a version's parts.
    return sorted(set(re.findall(r"(?<![\w.])\d+(?![\w.])", text)))


def rel_links(text):
    return sorted(set(re.findall(r"\]\((\./[^)#\s]+|[^):#\s/][^)#\s]*\.(?:md|sh|json|txt))\)", text)))


def main():
    if len(sys.argv) < 3:
        print("usage: check-readme-parity.py <file-a> <file-b> [stale-terms-file]", file=sys.stderr)
        return 2
    a_path, b_path = Path(sys.argv[1]), Path(sys.argv[2])
    stale_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    root = a_path.resolve().parent

    for p in (a_path, b_path):
        if not p.is_file():
            print(f"missing: {p}", file=sys.stderr)
            return 2

    a, b = a_path.read_text(encoding="utf-8"), b_path.read_text(encoding="utf-8")
    problems = []

    for name, fn in (("## sections", lambda t: sections(t, 2)),
                     ("### sections", lambda t: sections(t, 3)),
                     ("code fences", fences)):
        va, vb = fn(a), fn(b)
        if va != vb:
            problems.append(f"{name}: {a_path.name} has {va}, {b_path.name} has {vb}")

    na, nb = numbers(a), numbers(b)
    if na != nb:
        only_a = [n for n in na if n not in nb]
        only_b = [n for n in nb if n not in na]
        detail = []
        if only_a:
            detail.append(f"only in {a_path.name}: {', '.join(only_a)}")
        if only_b:
            detail.append(f"only in {b_path.name}: {', '.join(only_b)}")
        problems.append("numbers differ -- " + "; ".join(detail))

    # The two files link to each other -- that is the language switcher, and it
    # is correct that each names the other. Compare the rest.
    counterpart = {f"./{b_path.name}", b_path.name, f"./{a_path.name}", a_path.name}
    la_all, lb_all = rel_links(a), rel_links(b)
    la = [x for x in la_all if x not in counterpart]
    lb = [x for x in lb_all if x not in counterpart]
    if la != lb:
        only_a = [x for x in la if x not in lb]
        only_b = [x for x in lb if x not in la]
        detail = []
        if only_a:
            detail.append(f"only in {a_path.name}: {', '.join(only_a)}")
        if only_b:
            detail.append(f"only in {b_path.name}: {', '.join(only_b)}")
        problems.append("relative links differ -- " + "; ".join(detail))

    # Every link still has to resolve, the switcher included.
    for path, links in ((a_path, la_all), (b_path, lb_all)):
        for link in links:
            if not (root / link).exists():
                problems.append(f"{path.name}: link does not resolve: {link}")

    if stale_path and stale_path.is_file():
        terms = [t.split("#", 1)[0].strip() for t in stale_path.read_text(encoding="utf-8").splitlines()]
        for term in [t for t in terms if t]:
            # Every term against every file. The point of the check.
            for path, text in ((a_path, a), (b_path, b)):
                if term in text:
                    problems.append(f"{path.name}: stale term present: {term!r}")

    if problems:
        print(f"README parity failed ({a_path.name} vs {b_path.name}):")
        for p in problems:
            print(f"  {p}")
        return 1

    print(f"README parity ok: {a_path.name} and {b_path.name} agree on "
          f"{sections(a, 2)} sections, {len(na)} numbers, {len(la)} links")
    return 0


if __name__ == "__main__":
    sys.exit(main())
