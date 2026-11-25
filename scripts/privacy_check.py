#!/usr/bin/env python3
"""Keep personal content out of the repository (git hooks and CI).

Adapted from the same check in Bema and Didja. What it blocks, in lines being added (and in commit messages):
  * private names: a list kept outside the repository, on the maintainer's Mac only. It is
    Didja's own private-terms list when Didja is installed, plus the hand-kept lists of Bema and CIBar
    (~/Library/Application Support/{Bema,CIBar}/private-terms-extra.txt). CI has no such list.
  * email addresses outside a short allowed list of made-up and company domains
  * phone numbers
and in files being added: screenshots and videos (outside Resources/, brand/, docs/images/ and
site/), and any database file. Secrets are gitleaks' job; the hooks run it too.

    privacy_check.py staged             the pre-commit hook: what is about to be committed
    privacy_check.py message <file>     the commit-msg hook: the commit message
    privacy_check.py range <from> <to>  the pre-push hook / CI: every commit being pushed
    privacy_check.py tree               report on everything tracked now (never blocks)
    privacy_check.py terms              print how many private terms are known

Nothing here sends anything anywhere. A match is reported by file and line with the name masked.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

# The repository being checked (the one the hook runs in; tests point it elsewhere).
ROOT = Path(os.environ.get("CIBAR_REPO", Path(__file__).resolve().parent.parent))
SUPPORT = Path.home() / "Library" / "Application Support" / "CIBar"
BEMA_EXTRA = Path.home() / "Library" / "Application Support" / "Bema" / "private-terms-extra.txt"
# Didja keeps the maintainer's private names list here; reused when present (read only).
DIDJA_TERMS = Path.home() / "Library" / "Application Support" / "Didja" / "private-terms.txt"
TERMS_FILE = Path(os.environ.get("CIBAR_PRIVATE_TERMS", SUPPORT / "private-terms.txt"))
# Names you add by hand, one per line: family, clients, colleagues.
EXTRA_FILE = SUPPORT / "private-terms-extra.txt"
# Words that are never personal on their own, and the made-up names the fixtures use.
ALLOW_FILE = Path(__file__).resolve().parent / "privacy-allow.txt"

ALLOWED_EMAIL_DOMAIN = re.compile(
    r"(^|\.)(example\.(com|org|net)|example|test|invalid|localhost|anthropic\.com|"
    r"users\.noreply\.github\.com|acme\.com|"
    r"(github|google|apple|microsoft)\.(com|app|net))$", re.I)
# Generated files that only list packages: never personal, and full of "name@version".
SKIPPED = ("bun.lock", "package-lock.json", "Package.resolved", "yarn.lock")
# The domain must end in a word of letters: "pkg@1.2.3" and Teams' "@thread.v2" are not addresses.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})(?![\w.])")
PHONE = re.compile(r"(?<![\w.])(?:\+\d{1,3}[ \-]?\(?\d{1,4}\)?(?:[ \-]?\d{2,4}){2,4}|05\d-?\d{3}-?\d{4})(?![\w.])")
RETINA_ASSET = re.compile(r"^\d+x\.(png|jpe?g|gif|webp|pdf|svg)$", re.I)
MEDIA = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".tiff", ".bmp", ".mov", ".mp4", ".m4v"}
DATABASES = {".db", ".sqlite", ".sqlite3", ".db-wal", ".db-shm"}
MEDIA_ALLOWED = ("Resources/", "brand/", "docs/images/", "site/")
HEBREW = re.compile(r"[֐-׿]")
HEBREW_PREFIX = "והבכלמש"


# --- the private list ---------------------------------------------------------------------

def load_allow() -> set[str]:
    if not ALLOW_FILE.exists():
        return set()
    return {l.strip().lower() for l in ALLOW_FILE.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")}


def _read_lines(path: Path) -> set[str]:
    try:
        return {l.strip() for l in path.read_text(encoding="utf-8").splitlines() if l.strip()}
    except OSError:
        return set()


def build_terms(names: set[str], allow: set[str]) -> list[str]:
    """Whole names, and the first word of each name when it is long enough to mean something."""
    terms: set[str] = set()
    for name in names:
        if len(name) >= 3 and name.lower() not in allow and not name.isdigit():
            terms.add(name)
        first = name.split()[0] if name.split() else ""
        if len(first) >= 3 and first.lower() not in allow and not first.isdigit() and "@" not in first:
            terms.add(first)
    return sorted(terms, key=lambda t: (-len(t), t))


def private_terms(refresh: bool = False) -> list[str]:
    if "CIBAR_PRIVATE_TERMS" in os.environ:  # tests, or a list kept somewhere else
        return sorted(_read_lines(TERMS_FILE), key=lambda t: (-len(t), t))
    return build_terms(_read_lines(DIDJA_TERMS) | _read_lines(EXTRA_FILE) | _read_lines(BEMA_EXTRA), load_allow())


def term_pattern(term: str) -> re.Pattern[str]:
    prefix = f"[{HEBREW_PREFIX}]{{0,2}}" if HEBREW.search(term) else ""
    return re.compile(rf"(?<![\w]){prefix}{re.escape(term)}(?![\w])", re.I)


def mask(term: str) -> str:
    return f"{term[0]}{'•' * (len(term) - 1)} ({len(term)} letters)"


# --- checking -----------------------------------------------------------------------------

class Findings:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, where: str, what: str) -> None:
        self.items.append(f"  {where}: {what}")


def check_text(where: str, text: str, patterns: list[tuple[str, re.Pattern[str]]], found: Findings) -> None:
    for term, pat in patterns:
        if pat.search(text):
            found.add(where, f"private name {mask(term)}")
    for m in EMAIL.finditer(text):
        if RETINA_ASSET.match(m.group(1)):  # "icon@2x.png" is a file name, not an address
            continue
        if not ALLOWED_EMAIL_DOMAIN.search(m.group(1)):
            found.add(where, f"email address at {m.group(1)} (use example.com)")
    for m in PHONE.finditer(text):
        if not re.search(r"0{6,}", re.sub(r"\D", "", m.group(0))):  # +972500000000 is a placeholder
            found.add(where, "phone number")


def added_lines(diff: str):
    """(file, line number, text) for every added line of a unified diff."""
    path, line = None, 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else None
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line = int(m.group(1)) if m else 0
        elif path and raw.startswith("+") and not raw.startswith("+++"):
            yield path, line, raw[1:]
            line += 1
        elif path and not raw.startswith("-"):
            line += 1


def check_files(names_status: str, found: Findings) -> None:
    for row in names_status.splitlines():
        parts = row.split("\t")
        if len(parts) < 2 or parts[0][0] not in "AR":
            continue
        path = parts[-1]
        ext = Path(path).suffix.lower()
        if ext in DATABASES or path.endswith((".db-wal", ".db-shm")):
            found.add(path, "a database file")
        elif ext in MEDIA and not path.startswith(MEDIA_ALLOWED):
            found.add(path, "an image or video (never commit screenshots; renders from made-up data go in docs/images)")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def run_gitleaks(args: list[str], found: Findings) -> None:
    if os.environ.get("CIBAR_SKIP_GITLEAKS"):
        return
    try:
        r = subprocess.run(["gitleaks", *args, "--redact", "--no-banner", "--exit-code", "1"],
                           cwd=ROOT, capture_output=True, text=True)
    except FileNotFoundError:
        found.add("gitleaks", "not installed (brew install gitleaks)")
        return
    if r.returncode != 0:
        found.add("gitleaks", "found a possible secret:\n" + (r.stdout + r.stderr).strip())


def patterns(local: bool) -> list[tuple[str, re.Pattern[str]]]:
    return [(t, term_pattern(t)) for t in private_terms()] if local else []


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else "staged"
    # On CI there is no private list, unless one is given explicitly (the checker's own tests).
    local = not os.environ.get("CI") or "CIBAR_PRIVATE_TERMS" in os.environ
    found = Findings()
    pats = patterns(local) if mode != "terms" else []

    if mode == "terms":
        print(f"{len(private_terms())} private terms known (kept outside the repository)")
        return 0
    if mode == "staged":
        for path, n, text in added_lines(git("diff", "--cached", "-U0", "--no-color")):
            if path.endswith(SKIPPED):
                continue
            check_text(f"{path}:{n}", text, pats, found)
        check_files(git("diff", "--cached", "--name-status"), found)
        run_gitleaks(["git", "--pre-commit", "--staged"], found)
    elif mode == "message":
        text = Path(argv[1]).read_text(encoding="utf-8")
        text = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
        check_text("commit message", text, pats, found)
    elif mode == "range":
        base, head = argv[1], argv[2]
        span = head if set(base) == {"0"} else f"{base}..{head}"
        diff = git("log", "-p", "-U0", "--no-color", "--format=", span) if set(base) == {"0"} else git("diff", "-U0", "--no-color", base, head)
        for path, n, text in added_lines(diff):
            if path.endswith(SKIPPED):
                continue
            check_text(f"{path}:{n}", text, pats, found)
        check_files(git("log", "--name-status", "--format=", span), found)
        for sha in git("rev-list", span).split():
            check_text(f"message of {sha[:7]}", git("log", "-1", "--format=%B", sha), pats, found)
        run_gitleaks(["git", f"--log-opts={span}"], found)
    elif mode == "tree":
        for path in git("ls-files").splitlines():
            p = ROOT / path
            if p.suffix.lower() in MEDIA | DATABASES or not p.is_file() or path.endswith(SKIPPED):
                continue
            try:
                for n, text in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                    check_text(f"{path}:{n}", text, pats, found)
            except UnicodeDecodeError:
                continue
        print("\n".join(found.items) or "nothing found")
        return 0
    else:
        print(__doc__)
        return 2

    if found.items:
        print("CIBar privacy check: blocked. Replace these with made-up names, example.com addresses\n"
              "or rendered images (CLAUDE.md, \"Personal content\"):", file=sys.stderr)
        print("\n".join(found.items), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
