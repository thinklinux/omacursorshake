#!/usr/bin/env python3
"""Tests for descriptor-relative state I/O."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATEIO = HERE / "stateio.py"

sys.path.insert(0, str(HERE))
import stateio  # noqa: E402


class Fail(Exception):
    pass


def run(args: list[str], stdin: bytes = b"", check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(STATEIO), *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise Fail(msg)


def test_source_never_reopens_full_path() -> None:
    src = STATEIO.read_text()
    assert_true("def open_dir_nofollow" not in src, "open_dir_nofollow still present")
    assert_true("def secure_open_read" not in src, "secure_open_read still present")
    # Writes must keep the walk fd; they must not reopen the parent pathname.
    write = src[src.index("def write_file") : src.index("def write_ring_from_stdin")]
    ring = src[src.index("def write_ring_from_stdin") : src.index("def copy_file")]
    read = src[src.index("def read_file") : src.index("def mkstemp_in_dir")]
    copy = src[src.index("def copy_file") : src.index("def exists_reg")]
    for name, block in ("write", write), ("ring", ring), ("read", read), ("copy", copy):
        assert_true("open_dir_nofollow" not in block, f"{name} reopens via open_dir_nofollow")
        assert_true("ensure_dir(" not in block or "ensure_dir_fd(" in block, f"{name} uses closing ensure_dir")
        assert_true("os.open(path" not in block, f"{name} opens a pathname")
        assert_true("walk_dir(" in block or "ensure_dir_fd(" in block, f"{name} does not walk")


def test_intermediate_symlink_refused(tmp: Path) -> None:
    outside = tmp / "outside"
    base = tmp / "base"
    outside.mkdir()
    base.mkdir()
    (base / "omarchy").symlink_to(outside)
    dest = base / "omarchy" / "omacursorshake" / "settings.json"
    proc = run(["write", str(dest)], stdin=b'{"enabled":true}\n', check=False)
    assert_true(proc.returncode != 0, "write followed intermediate symlink")
    assert_true(b"symlink" in proc.stderr, f"write err: {proc.stderr!r}")
    assert_true(not (outside / "omacursorshake").exists(), "created dir through intermediate symlink")

    proc = run(["read", str(dest), "64"], check=False)
    assert_true(proc.returncode != 0, "read followed intermediate symlink")
    assert_true(b"symlink" in proc.stderr, f"read err: {proc.stderr!r}")

    src = tmp / "real" / "built.so"
    src.parent.mkdir()
    src.write_bytes(b"plugin")
    proc = run(["copy", str(src), str(base / "omarchy" / "omacursorshake" / "dynamic-cursors.so")], check=False)
    assert_true(proc.returncode != 0, "copy dest followed intermediate symlink")


def test_verification_to_use_swap_held_fd(tmp: Path) -> None:
    real_parent = tmp / "state" / "omarchy"
    leaf = real_parent / "omacursorshake"
    leaf.mkdir(parents=True)
    evil = tmp / "evil" / "omacursorshake"
    evil.mkdir(parents=True)

    dirfd = stateio.walk_dir(str(leaf), create=False)
    ident = (os.fstat(dirfd).st_dev, os.fstat(dirfd).st_ino)
    try:
        os.rename(real_parent, tmp / "state" / "omarchy.real")
        (tmp / "state" / "omarchy").symlink_to(tmp / "evil")
        stateio.write_through_dirfd(dirfd, "settings.json", "settings.json", b'{"held":true}\n', 0o600)
    finally:
        os.close(dirfd)

    written = tmp / "state" / "omarchy.real" / "omacursorshake" / "settings.json"
    leaked = evil / "settings.json"
    assert_true(written.is_file(), "write via held fd missed original directory")
    assert_true(written.read_bytes() == b'{"held":true}\n', "held-fd payload mismatch")
    assert_true(not leaked.exists(), "held-fd write leaked through swapped intermediate")
    st = os.stat(written)
    assert_true((st.st_dev, os.stat(written).st_dev) == (ident[0], ident[0]), "wrote to a different device")


def test_write_file_survives_intermediate_swap(tmp: Path) -> None:
    real_parent = tmp / "state" / "omarchy"
    leaf = real_parent / "omacursorshake"
    leaf.mkdir(parents=True)
    evil = tmp / "evil" / "omacursorshake"
    evil.mkdir(parents=True)
    dest = leaf / "build.log"
    stop = threading.Event()
    errors: list[str] = []

    def swapper() -> None:
        parked = tmp / "state" / "omarchy.parked"
        link = tmp / "state" / "omarchy"
        while not stop.is_set():
            try:
                if link.is_symlink():
                    link.unlink()
                    os.rename(parked, link)
                elif link.is_dir() and not link.is_symlink():
                    os.rename(link, parked)
                    link.symlink_to(tmp / "evil")
            except OSError:
                pass
            time.sleep(0)

    thr = threading.Thread(target=swapper, daemon=True)
    thr.start()
    try:
        for i in range(40):
            try:
                stateio.write_file(str(dest), f"round-{i}\n".encode(), 0o600)
            except SystemExit as exc:
                errors.append(str(exc))
            except Exception as exc:
                errors.append(repr(exc))
    finally:
        stop.set()
        thr.join(timeout=2)
        # Restore a real directory so later assertions are stable.
        link = tmp / "state" / "omarchy"
        parked = tmp / "state" / "omarchy.parked"
        try:
            if link.is_symlink():
                link.unlink()
            if parked.exists() and not link.exists():
                os.rename(parked, link)
        except OSError:
            pass

    leaked = evil / "build.log"
    assert_true(not leaked.exists(), f"swap redirected a write into evil: {leaked}")
    # Either the original leaf still has the file, or writes failed closed.
    original = (tmp / "state" / "omarchy" / "omacursorshake" / "build.log")
    parked_file = (tmp / "state" / "omarchy.parked" / "omacursorshake" / "build.log")
    present = original.is_file() or parked_file.is_file()
    assert_true(present or errors, "writes neither landed in original tree nor failed closed")


def test_read_does_not_follow_intermediate_after_walk(tmp: Path) -> None:
    real_parent = tmp / "state" / "omarchy"
    leaf = real_parent / "omacursorshake"
    leaf.mkdir(parents=True)
    target = leaf / "settings.json"
    target.write_bytes(b"SECRET\n")
    evil = tmp / "evil" / "omacursorshake"
    evil.mkdir(parents=True)
    (evil / "settings.json").write_bytes(b"LEAK\n")

    dirfd = stateio.walk_dir(str(leaf), create=False)
    try:
        os.rename(real_parent, tmp / "state" / "omarchy.real")
        (tmp / "state" / "omarchy").symlink_to(tmp / "evil")
        fd = stateio.open_reg_at(dirfd, "settings.json", "settings.json")
        try:
            data = stateio.read_fd(fd, 64)
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)
    assert_true(data == b"SECRET\n", f"read after swap got {data!r}")


def test_fifo_and_symlink_dest(tmp: Path) -> None:
    state = tmp / "omarchy" / "omacursorshake"
    run(["ensure-dir", str(state)])
    victim = tmp / "victim"
    victim.write_bytes(b"VICTIM\n")
    settings = state / "settings.json"
    settings.symlink_to(victim)
    proc = run(["write", str(settings)], stdin=b'{"ok":true}\n')
    assert_true(proc.returncode == 0, proc.stderr.decode())
    assert_true(settings.is_file() and not settings.is_symlink(), "did not replace symlink dest")
    assert_true(victim.read_bytes() == b"VICTIM\n", "write followed dest symlink")

    settings.unlink()
    os.mkfifo(settings)
    proc = run(["read", str(settings), "64"], check=False)
    assert_true(proc.returncode != 0, "FIFO read succeeded")
    assert_true(b"regular file" in proc.stderr or b"special file" in proc.stderr, proc.stderr.decode())


def test_copy_source_symlink(tmp: Path) -> None:
    state = tmp / "omarchy" / "omacursorshake"
    run(["ensure-dir", str(state)])
    evil = tmp / "evil.so"
    evil.write_bytes(b"EVIL")
    src = state / "src.so"
    src.symlink_to(evil)
    proc = run(["copy", str(src), str(state / "dest.so")], check=False)
    assert_true(proc.returncode != 0, "copy followed source symlink")
    assert_true(not (state / "dest.so").exists(), "copy produced dest from symlink src")


def test_rm_tree_still_dirfd(tmp: Path) -> None:
    state = tmp / "omarchy" / "omacursorshake"
    run(["ensure-dir", str(state)])
    src = state / "src"
    src.mkdir()
    (src / "file").write_bytes(b"x")
    victim = tmp / "victim"
    victim.mkdir()
    (victim / "keep").write_bytes(b"keep")
    (src / "link").symlink_to(victim)
    proc = run(["rm-tree", str(state), "src"])
    assert_true(proc.returncode == 0, proc.stderr.decode())
    assert_true(not src.exists(), "src remains")
    assert_true((victim / "keep").is_file(), "rm-tree followed child symlink")


def main() -> int:
    tests = [
        test_source_never_reopens_full_path,
        test_intermediate_symlink_refused,
        test_verification_to_use_swap_held_fd,
        test_write_file_survives_intermediate_swap,
        test_read_does_not_follow_intermediate_after_walk,
        test_fifo_and_symlink_dest,
        test_copy_source_symlink,
        test_rm_tree_still_dirfd,
    ]
    failed = 0
    for test in tests:
        tmp = Path(tempfile.mkdtemp(prefix="stateio-test-"))
        try:
            if test is test_source_never_reopens_full_path:
                test()
            else:
                test(tmp)
            print(f"PASS {test.__name__}")
        except Exception as exc:
            failed += 1
            print(f"FAIL {test.__name__}: {exc}")
        finally:
            subprocess.run(["rm", "-rf", str(tmp)], check=False)
    if failed:
        print(f"{failed} test(s) failed")
        return 1
    print("ALL_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
