#!/usr/bin/env python3
"""Check every hypr-dynamic-cursors pin against upstream. Needs network.

For each pinned commit this:

  1. resolves it in VirtCode/hypr-dynamic-cursors (a pin that no longer exists
     upstream is a reproducibility failure, not a build-time surprise),
  2. checks it out and recomputes the SHA-256 source digest with the same
     `stateio.py tree-digest` the build path uses, and
  3. compares that digest to the table in backend.sh.

It also diffs our Hyprland -> plugin map against upstream's own hyprpm.toml
on main, so silent drift in either direction shows up here rather than on a
user's machine.

  bin/verify_pins.py            verify; exit non-zero on any mismatch
  bin/verify_pins.py --print    emit the plugin_digest_for case block
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BACKEND = HERE / "backend.sh"
STATEIO = HERE / "stateio.py"
REPO = "https://github.com/VirtCode/hypr-dynamic-cursors.git"
CASE = re.compile(r'^\s*([0-9a-f]{40})\) echo "([0-9a-f]{40,64})" ;;(?: # (.*))?$', re.M)


def section(name: str) -> str:
    text = BACKEND.read_text()
    start = text.index(f"{name}() {{")
    return text[start : text.index("\n}\n", start)]


def parse(name: str) -> list[tuple[str, str, str]]:
    return [(k, v, (c or "").strip()) for k, v, c in CASE.findall(section(name))]


def git(*args: str, cwd: Path | None = None) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {proc.stderr.decode().strip()}")
    return proc.stdout.decode()


def digest(path: Path) -> str:
    return subprocess.run(
        [sys.executable, str(STATEIO), "tree-digest", str(path)],
        stdout=subprocess.PIPE, check=True,
    ).stdout.decode().strip()


def main(argv: list[str]) -> int:
    rev_map = parse("plugin_rev_for")
    digest_map = {rev: d for rev, d, _ in parse("plugin_digest_for")}

    # Distinct plugin revs, in the order they appear, with the Hyprland
    # versions each one serves.
    serves: dict[str, list[str]] = {}
    for _, rev, comment in rev_map:
        serves.setdefault(rev, []).append(comment)

    failures: list[str] = []
    lines: list[str] = []

    with tempfile.TemporaryDirectory(prefix="verify-pins-") as td:
        work = Path(td) / "src"
        print(f"cloning {REPO} ...", file=sys.stderr)
        git("clone", "--quiet", REPO, str(work))

        upstream = git("show", "origin/main:hyprpm.toml", cwd=work)
        upstream_pins = dict(
            re.findall(r'\["([0-9a-f]{40})",\s*"([0-9a-f]{40})"\]', upstream)
        )
        ours = {hl: rev for hl, rev, _ in rev_map}
        for hl, rev in ours.items():
            if upstream_pins.get(hl) != rev:
                failures.append(
                    f"map drift for Hyprland {hl}: ours {rev}, "
                    f"upstream hyprpm.toml {upstream_pins.get(hl, 'absent')}"
                )
        for hl, rev in upstream_pins.items():
            if hl not in ours:
                failures.append(f"upstream pins Hyprland {hl} -> {rev}; we do not map it")

        for rev, versions in serves.items():
            label = versions[0] if len(versions) == 1 else f"{versions[0]}-{versions[-1]}"
            try:
                git("cat-file", "-e", f"{rev}^{{commit}}", cwd=work)
            except RuntimeError:
                failures.append(f"{rev} ({label}): NOT RESOLVABLE upstream")
                continue
            refs = git("branch", "-r", "--contains", rev, cwd=work).split()
            if not refs:
                failures.append(f"{rev} ({label}): unreachable from any remote branch")
            git("checkout", "--quiet", "--detach", rev, cwd=work)
            git("clean", "-qfdx", cwd=work)
            got = digest(work)
            want = digest_map.get(rev)
            state = "OK" if got == want else ("MISSING" if want is None else "MISMATCH")
            if state != "OK":
                failures.append(f"{rev} ({label}): digest {state} (computed {got}, table {want})")
            lines.append(f'  {rev}) echo "{got}" ;; # Hyprland {label}')
            print(f"{state:8} {rev}  {got}  {label}")

    if "--print" in argv:
        print("\n".join(lines))

    missing = set(digest_map) - set(serves)
    for rev in missing:
        failures.append(f"{rev}: digest recorded but no Hyprland version maps to it")

    if failures:
        print("\n" + "\n".join(f"FAIL {f}" for f in failures), file=sys.stderr)
        return 1
    print(f"\nOK: {len(serves)} pins resolvable, reachable, and digest-matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
