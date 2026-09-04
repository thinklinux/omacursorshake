#!/usr/bin/env python3
"""Tests for descriptor-relative state I/O."""

from __future__ import annotations

import mmap
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATEIO = HERE / "stateio.py"
BACKEND = HERE / "backend.sh"

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


def test_read_tail_returns_end_of_file(tmp: Path) -> None:
    state = tmp / "state"
    state.mkdir(mode=0o700)
    log = state / "build.log"
    log.write_bytes(b"H" * 4096 + b"LAST-LINE\n")
    proc = run(["read-tail", str(log), "16"])
    assert_true(proc.stdout == b"HHHHHHLAST-LINE\n", f"tail: {proc.stdout!r}")
    # A short file comes back whole, and a missing one is empty, not an error.
    short = state / "built-for"
    short.write_bytes(b"abc\n")
    assert_true(run(["read-tail", str(short), "64"]).stdout == b"abc\n", "short tail")
    assert_true(run(["read-tail", str(state / "nope"), "64"]).stdout == b"", "missing tail")


def test_writable_path_component_refused(tmp: Path) -> None:
    for mode, kind in ((0o775, "group"), (0o777, "other")):
        base = tmp / f"base-{kind}"
        (base / "omarchy").mkdir(parents=True)
        os.chmod(base, mode)
        dest = base / "omarchy" / "omacursorshake" / "settings.json"
        proc = run(["write", str(dest)], stdin=b"{}\n", check=False)
        assert_true(proc.returncode != 0, f"{kind}-writable component accepted")
        assert_true(b"writable path component" in proc.stderr, f"err: {proc.stderr!r}")
        proc = run(["read", str(dest), "64"], check=False)
        assert_true(proc.returncode != 0, f"{kind}-writable component read accepted")
        # Sticky (like /tmp) is safe: entries can only be replaced by their owner.
        os.chmod(base, mode | stat.S_ISVTX)
        proc = run(["write", str(dest)], stdin=b"{}\n", check=False)
        assert_true(proc.returncode == 0, f"sticky {kind}-writable refused: {proc.stderr!r}")


def test_foreign_owned_component_refused(tmp: Path) -> None:
    # /home is root-owned and must stay walkable; a non-root, non-self owner
    # cannot be produced without privileges, so assert the rule directly.
    fd = os.open("/home", os.O_RDONLY | os.O_DIRECTORY)
    try:
        stateio.validate_component_fd(fd, "/home")
    finally:
        os.close(fd)
    src = STATEIO.read_text()
    assert_true("st.st_uid not in (os.getuid(), 0)" in src, "component owner rule missing")


def test_remove_depth_bounded(tmp: Path) -> None:
    state = tmp / "state"
    state.mkdir(mode=0o700)
    deep = state / "src"
    cur = deep
    for _ in range(stateio.MAX_REMOVE_DEPTH + 4):
        cur = cur / "d"
    cur.mkdir(parents=True)
    proc = run(["rm-tree", str(state), "src"], check=False)
    assert_true(proc.returncode != 0, "unbounded recursion accepted")
    assert_true(b"recurse past" in proc.stderr, f"err: {proc.stderr!r}")
    assert_true(deep.exists(), "partial removal left no root")


def test_backend_refuses_unsafe_state_path(tmp: Path) -> None:
    env = dict(os.environ)
    for bad in (str(tmp / "st]ate"), str(tmp / "st[ate")):
        env["XDG_STATE_HOME"] = bad
        proc = subprocess.run(
            ["bash", str(BACKEND), "status"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        assert_true(proc.returncode != 0, f"accepted bracket path {bad}")
        assert_true(b"square brackets" in proc.stderr, f"err: {proc.stderr!r}")
    src = BACKEND.read_text()
    # apply.lua must never be interpolated into a plain [[...]] long bracket.
    assert_true("dofile([[" not in src, "unbracketed dofile still present")
    assert_true("dofile([==[" in src, "safe dofile bracket missing")


def test_concurrent_publish_no_inode_mismatch(tmp: Path) -> None:
    """Our own concurrent writers must queue, not trip the publish check."""
    state = tmp / "state"
    state.mkdir(mode=0o700)
    dest = state / "settings.json"
    results: list[subprocess.CompletedProcess[bytes]] = []
    lock = threading.Lock()

    def writer(n: int) -> None:
        payload = ('{"enabled":false,"threshold":%d}\n' % n).encode()
        proc = run(["write", str(dest)], stdin=payload, check=False)
        with lock:
            results.append(proc)

    threads = [threading.Thread(target=writer, args=(i,)) for i in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for proc in results:
        assert_true(b"inode mismatch" not in proc.stderr, f"raced publish: {proc.stderr!r}")
        assert_true(proc.returncode == 0, f"write failed: {proc.stderr!r}")
    text = dest.read_text()
    assert_true(text.startswith('{"enabled":false,') and text.endswith("}\n"), f"torn: {text!r}")


def test_publish_lock_times_out(tmp: Path) -> None:
    """A held lock fails closed with a clear message instead of racing."""
    state = tmp / "state"
    state.mkdir(mode=0o700)
    dest = state / "settings.json"
    held = open(state / (stateio.LOCK_PREFIX + "settings.json"), "wb")
    original = stateio.LOCK_WAIT_SECONDS
    stateio.LOCK_WAIT_SECONDS = 0.2
    try:
        import fcntl

        fcntl.flock(held.fileno(), fcntl.LOCK_EX)
        start = time.monotonic()
        try:
            stateio.write_file(str(dest), b"{}\n")
            raise Fail("write published while the lock was held")
        except SystemExit:
            pass
        assert_true(time.monotonic() - start < 5, "did not honour the shortened wait")
        assert_true(not dest.exists(), "published despite the held lock")
    finally:
        stateio.LOCK_WAIT_SECONDS = original
        held.close()


def test_settings_has_one_writer(tmp: Path) -> None:
    """updateSettings must not spawn a detached save beside the queued job."""
    qml = (HERE.parent / "Service.qml").read_text()
    assert_true("persistSettings" not in qml, "detached settings writer still present")
    assert_true('backend, "save"' not in qml, "save job still raced beside apply/disable")


STUB_TOOLS = {
    "uname": "#!/bin/sh\nprintf 'x86_64\\n'\n",
    "pkg-config": "#!/bin/sh\nexit 0\n",
    "g++": "#!/bin/sh\nexit 0\n",
    "hyprctl": (
        "#!/bin/sh\n"
        "case \"$*\" in\n"
        "  *version*) printf '{\"commit\":\"%s\",\"version\":\"0.56.2\"}\\n' "
        "efb50993780079460b0cbed1363e2166a2de1d9f ;;\n"
        "  *'plugin list'*) printf '[]\\n' ;;\n"
        "  *) printf 'ok\\n' ;;\n"
        "esac\n"
    ),
    "git": (
        "#!/bin/sh\n"
        "echo \"git $*\" >&2\n"
        "while [ \"$1\" = \"-c\" ]; do shift 2; done\n"
        "dir=\"\"\n"
        "if [ \"$1\" = \"-C\" ]; then dir=$2; shift 2; fi\n"
        "case \"$1\" in\n"
        "  clone) shift; for a in \"$@\"; do last=$a; done; mkdir -p \"$last/.git\" ;;\n"
        "  checkout) [ -n \"${STUB_SRC:-}\" ] && printf '%s' \"$STUB_SRC\" > \"$dir/source.cpp\" ;;\n"
        "  rev-parse) printf '%s\\n' \"${STUB_HEAD:-5a224284872208b5324759d535d65061043725de}\" ;;\n"
        "  status) printf '%s' \"${STUB_DIRTY:-}\" ;;\n"
        "esac\n"
        "exit 0\n"
    ),
    "make": (
        "#!/bin/sh\n"
        "echo \"make $*\" >&2\n"
        "[ -n \"${STUB_ARGV_LOG:-}\" ] && echo \"make $*\" >> \"$STUB_ARGV_LOG\"\n"
        "while [ $# -gt 0 ]; do\n"
        "  case \"$1\" in -C) dir=$2; shift 2 ;; *) shift ;; esac\n"
        "done\n"
        "${NOISE_CMD:-true}\n"
        "mkdir -p \"$dir/out\"\n"
        "printf 'ELF-STUB\\n' > \"$dir/out/dynamic-cursors.so\"\n"
        "exit 0\n"
    ),
}


def stub_path(tmp: Path) -> str:
    stubs = tmp / "stubs"
    stubs.mkdir(parents=True, exist_ok=True)
    for name, body in STUB_TOOLS.items():
        f = stubs / name
        f.write_text(body)
        f.chmod(0o755)
    return f"{stubs}:{os.environ.get('PATH', '')}"


PIN_0562 = "5a224284872208b5324759d535d65061043725de"


def tree_digest(path: Path) -> str:
    return run(["tree-digest", str(path)]).stdout.decode().strip()


def patched_backend(tmp: Path, expected_digest: str) -> Path:
    """A copy of backend.sh whose 0.56.2 source digest is the stub tree's.

    The stub build pipeline cannot produce upstream's real source, so the
    recorded digest is swapped for the stub tree's. Only that one hex string
    changes: the gate itself is the shipped code, running for real.
    """
    bindir = tmp / "patched-bin"
    bindir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(STATEIO, bindir / "stateio.py")
    text = BACKEND.read_text()
    head = text.index("plugin_digest_for()")
    marker = f'  {PIN_0562}) echo "'
    i = text.index(marker, head) + len(marker)
    j = text.index('"', i)
    dest = bindir / "backend.sh"
    dest.write_text(text[:i] + expected_digest + text[j:])
    dest.chmod(0o755)
    return dest


def empty_tree_digest(tmp: Path) -> str:
    """Digest of a tree holding nothing but .git -- what the git stub leaves."""
    d = tmp / "empty-tree"
    (d / ".git").mkdir(parents=True, exist_ok=True)
    return tree_digest(d)


def backend_env(tmp: Path, state: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = stub_path(tmp)
    env["XDG_STATE_HOME"] = str(state)
    return env


def test_backend_build_pipeline(tmp: Path) -> None:
    """run_timed must read both pipeline stages; a stale PIPESTATUS broke every build."""
    state = tmp / "state"
    env = backend_env(tmp, state)
    backend = patched_backend(tmp, empty_tree_digest(tmp))
    proc = subprocess.run(
        ["bash", str(backend), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    assert_true(proc.returncode == 0, f"ensure failed: {proc.stderr!r}")
    assert_true(b"PIPESTATUS" not in proc.stderr, f"PIPESTATUS leak: {proc.stderr!r}")
    sdir = state / "omarchy" / "omacursorshake"
    so = sdir / "dynamic-cursors.so"
    assert_true(so.is_file(), "no .so installed")
    assert_true(so.stat().st_mode & 0o777 == 0o755, f"so mode {so.stat().st_mode:o}")
    assert_true(
        (sdir / "built-for").read_text().strip() == "efb50993780079460b0cbed1363e2166a2de1d9f",
        "stamp not written",
    )
    status = proc.stdout.decode()
    assert_true('"needsRebuild": false' in status, f"status: {status}")
    log = sdir / "build.log"
    assert_true(log.is_file() and log.stat().st_size <= 65536, "build log unbounded")


def test_backend_build_log_budget(tmp: Path) -> None:
    """A noisy phase must fail closed and keep build.log inside the budget."""
    state = tmp / "state"
    env = backend_env(tmp, state)
    env["NOISE_CMD"] = "head -c 400000 /dev/zero | tr '\\0' 'n'"
    backend = patched_backend(tmp, empty_tree_digest(tmp))
    proc = subprocess.run(
        ["bash", str(backend), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    assert_true(proc.returncode != 0, "noisy build accepted")
    assert_true(b"budget" in proc.stderr, f"err: {proc.stderr!r}")
    # The failure message survives; the log tail must never crowd it out.
    assert_true(b"omacursorshake: output exceeded" in proc.stderr, f"err: {proc.stderr!r}")
    log = state / "omarchy" / "omacursorshake" / "build.log"
    assert_true(log.stat().st_size <= 65536, f"log grew to {log.stat().st_size}")


def _hyprctl_stub(tmp: Path, body: str) -> dict[str, str]:
    tmp.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PATH"] = stub_path(tmp)
    stub = tmp / "stubs" / "hyprctl"
    stub.write_text(body)
    stub.chmod(0o755)
    env["XDG_STATE_HOME"] = str(tmp / "state")
    return env


def test_hyprctl_calls_are_time_bounded(tmp: Path) -> None:
    """A wedged compositor must not hang the backend, even via a grandchild.

    timeout without --foreground runs the child in its own process group and
    signals the group, so a forked grandchild cannot hold the capture pipe
    open past the deadline.
    """
    cases = {
        "direct": "#!/bin/sh\nsleep 600\n",
        "grandchild": "#!/bin/sh\nsleep 600 &\nwait\n",
        "slow-drip": "#!/bin/sh\nwhile :; do printf x; sleep 0.3; done\n",
    }
    for name, body in cases.items():
        env = _hyprctl_stub(tmp / name, body)
        start = time.monotonic()
        proc = subprocess.run(
            ["bash", str(BACKEND), "status"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        elapsed = time.monotonic() - start
        assert_true(proc.returncode == 0, f"{name}: rc={proc.returncode} {proc.stderr!r}")
        assert_true(elapsed < 60, f"{name}: took {elapsed:.0f}s, not bounded")
        assert_true(b'"loaded": false' in proc.stdout, f"{name}: {proc.stdout!r}")

    src = BACKEND.read_text()
    code = [ln for ln in src.splitlines() if not ln.strip().startswith("#")]
    assert_true(
        not any("--foreground" in ln for ln in code),
        "--foreground signals only the direct child, so a grandchild defeats the timeout",
    )
    assert_true("timeout --signal=TERM" in src, "phase timeout missing")


def test_hyprctl_output_is_byte_bounded(tmp: Path) -> None:
    """An endless response must be cut at the stream, not buffered whole."""
    body = (
        "#!/bin/sh\n"
        "case \"$*\" in\n"
        "  *version*) printf '{\"commit\":\"%s\",\"version\":\"0.56.2\"}\\n' "
        "efb50993780079460b0cbed1363e2166a2de1d9f ;;\n"
        "  *) yes '{\"name\":\"flood-dynamic-cursors\"}' ;;\n"
        "esac\n"
    )
    env = _hyprctl_stub(tmp / "flood", body)
    start = time.monotonic()
    proc = subprocess.run(
        ["bash", str(BACKEND), "status"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode == 0, f"rc={proc.returncode}: {proc.stderr!r}")
    assert_true(time.monotonic() - start < 30, "flood was not cut off promptly")
    assert_true(len(proc.stdout) < 65536, f"status grew to {len(proc.stdout)} bytes")

    src = BACKEND.read_text()
    # No raw hyprctl capture may land in a shell variable un-truncated.
    bare = re.compile(r"\$\(\s*hyprctl(?![_a-zA-Z0-9])")
    for line in src.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        assert_true(not bare.search(stripped), f"unbounded hyprctl capture: {stripped}")


def test_gnumakefile_precedence_is_defeated(tmp: Path) -> None:
    """The real mechanism: GNU make prefers GNUmakefile unless -f is given."""
    proj = tmp / "proj"
    proj.mkdir()
    (proj / "Makefile").write_text("all:\n\t@touch %s\n" % (proj / "ok"))
    (proj / "GNUmakefile").write_text("all:\n\t@touch %s\n" % (proj / "bad"))

    subprocess.run(["make", "-C", str(proj), "all"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert_true((proj / "bad").exists(), "precondition: make should prefer GNUmakefile")

    (proj / "bad").unlink()
    subprocess.run(["make", "-f", "Makefile", "-C", str(proj), "all"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert_true((proj / "ok").exists(), "-f Makefile did not run the intended file")
    assert_true(not (proj / "bad").exists(), "-f Makefile still ran GNUmakefile")

    assert_true("make -f Makefile -C" in BACKEND.read_text(), "backend does not pin -f Makefile")


def test_planted_source_tree_is_destroyed(tmp: Path) -> None:
    """A pre-planted src tree must never survive into checkout or make."""
    state = tmp / "state"
    sdir = state / "omarchy" / "omacursorshake"
    src = sdir / "src"
    (src / ".git" / "hooks").mkdir(parents=True)
    marker = tmp / "HOOK-RAN"
    hook = src / ".git" / "hooks" / "post-checkout"
    hook.write_text(f"#!/bin/sh\ntouch {marker}\n")
    hook.chmod(0o755)
    (src / ".git" / "config").write_text("[core]\n\tfsmonitor = touch %s\n" % (tmp / "FSMON-RAN"))
    (src / "GNUmakefile").write_text("all:\n\t@touch %s\n" % (tmp / "GNUMAKE-RAN"))
    planted = src / "planted-marker"
    planted.write_text("x")

    env = backend_env(tmp, state)
    argv_log = tmp / "make-argv.log"
    env["STUB_ARGV_LOG"] = str(argv_log)
    backend = patched_backend(tmp, empty_tree_digest(tmp))
    proc = subprocess.run(
        ["bash", str(backend), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode == 0, f"ensure failed: {proc.stderr!r}")
    for m in ("HOOK-RAN", "FSMON-RAN", "GNUMAKE-RAN"):
        assert_true(not (tmp / m).exists(), f"{m}: planted code executed")
    assert_true(not planted.exists(), "planted file survived into the build tree")
    assert_true("-f Makefile" in argv_log.read_text(), "make was not pinned to Makefile")

    src_txt = BACKEND.read_text()
    assert_true("need_clone" not in src_txt, "source-tree reuse branch is back")
    assert_true("core.hooksPath=/dev/null" in src_txt, "git hook neutralisation missing")


def test_checkout_must_match_the_pin(tmp: Path) -> None:
    """A tree that is not the pinned commit, or is dirty, must not be built."""
    env = backend_env(tmp / "wrong", tmp / "wrong" / "state")
    env["STUB_HEAD"] = "0" * 40
    proc = subprocess.run(
        ["bash", str(BACKEND), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode != 0, "built from the wrong commit")
    assert_true(b"expected the pinned" in proc.stderr, f"err: {proc.stderr!r}")

    env = backend_env(tmp / "dirty", tmp / "dirty" / "state")
    env["STUB_DIRTY"] = "?? injected.cpp\n"
    proc = subprocess.run(
        ["bash", str(BACKEND), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode != 0, "built from a dirty tree")
    assert_true(b"not clean" in proc.stderr, f"err: {proc.stderr!r}")


def _load_stub(tmp: Path, listed_after: str, load_exit: int) -> dict[str, str]:
    """hyprctl stub whose plugin list changes once a load has been attempted.

    That transition is the whole point: the old code re-checked the listing
    after a failed load, saw a name match appear, and called it success.
    """
    body = (
        "#!/bin/sh\n"
        "case \"$*\" in\n"
        "  *version*) printf '{\"commit\":\"efb50993780079460b0cbed1363e2166a2de1d9f\"}\\n' ;;\n"
        "  *'plugin list'*)\n"
        "    if [ -f \"$STUB_LOADED\" ]; then printf '%s\\n' \"$STUB_LISTED_AFTER\"\n"
        "    else printf '[]\\n'; fi ;;\n"
        f"  *'plugin load'*) touch \"$STUB_LOADED\"; exit {load_exit} ;;\n"
        "  *) printf 'ok\\n' ;;\n"
        "esac\n"
    )
    env = _hyprctl_stub(tmp, body)
    env["STUB_LOADED"] = str(tmp / "loaded-flag")
    env["STUB_LISTED_AFTER"] = listed_after
    state = Path(env["XDG_STATE_HOME"]) / "omarchy" / "omacursorshake"
    state.mkdir(parents=True)
    (state / "dynamic-cursors.so").write_bytes(b"ELF-STUB\n")
    return env


def _run_load(env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["bash", str(BACKEND), "load", '{"enabled":true}'],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )


def test_load_requires_hyprctl_exit_status(tmp: Path) -> None:
    """A failed load must fail even when a name match appears afterwards.

    Hyprland 0.56 reports no plugin path, so the listing can only ever be a
    name match. It must never stand in for hyprctl's own exit status.
    """
    env = _load_stub(tmp / "rc", '[{"name":"dynamic-cursors"}]', load_exit=1)
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "test_instance"
    proc = _run_load(env)
    assert_true(proc.returncode != 0, "load succeeded despite hyprctl failing")
    assert_true(b"plugin load failed" in proc.stderr, f"err: {proc.stderr!r}")
    assert_true(
        b'"loaded": true' not in proc.stdout,
        f"reported loaded after a failed load: {proc.stdout!r}",
    )


def test_foreign_plugin_is_not_claimed_as_ours(tmp: Path) -> None:
    """A name match we did not load must not gate, or stand in for, our load."""
    env = _load_stub(tmp / "foreign", "[]", load_exit=0)
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "test_instance"
    # Something matching is already loaded before we do anything, and no
    # record of our own load exists for this instance.
    Path(env["STUB_LOADED"]).touch()
    env["STUB_LISTED_AFTER"] = '[{"name":"dynamic-cursors"}]'
    proc = _run_load(env)
    assert_true(proc.returncode != 0, "a foreign plugin was claimed as ours")
    assert_true(b"cannot prove is ours" in proc.stderr, f"err: {proc.stderr!r}")


def test_maps_has_matches_exact_pathname(tmp: Path) -> None:
    """A maps line counts only when the pathname is exactly our .so."""
    so = tmp / "omarchy" / "omacursorshake" / "dynamic-cursors.so"
    so.parent.mkdir(parents=True)
    so.write_bytes(b"ELF-STUB\n")
    other = tmp / "hyprpm" / "dynamic-cursors.so"
    other.parent.mkdir(parents=True)
    other.write_bytes(b"OTHER\n")
    maps = tmp / "maps"
    maps.write_text(
        "00400000-00401000 r-xp 00000000 00:00 1                          /usr/bin/Hyprland\n"
        f"7f0000000000-7f0000001000 r-xp 00000000 00:1d 2                  {other}\n"
        f"7f0000001000-7f0000002000 r-xp 00000000 00:1d 3                  {so} (deleted)\n"
        f"7f0000002000-7f0000003000 r-xp 00000000 00:1d 4                  {so}.bak\n"
        f"7f0000003000-7f0000004000 r-xp 00000000 00:1d 5                  {so}\n"
    )
    proc = run(["maps-has", str(maps), str(so)], check=False)
    assert_true(proc.returncode == 0, f"exact path missed: {proc.stderr!r}")

    maps.write_text(
        "00400000-00401000 r-xp 00000000 00:00 1                          /usr/bin/Hyprland\n"
        f"7f0000000000-7f0000001000 r-xp 00000000 00:1d 2                  {other}\n"
        f"7f0000001000-7f0000002000 r-xp 00000000 00:1d 3                  {so} (deleted)\n"
        f"7f0000002000-7f0000003000 r-xp 00000000 00:1d 4                  {so}.bak\n"
    )
    proc = run(["maps-has", str(maps), str(so)], check=False)
    assert_true(proc.returncode != 0, "substring or (deleted) mapping was accepted")

    proc = run(["maps-has", str(maps), str(other)], check=False)
    assert_true(proc.returncode == 0, "foreign path should match itself")


def test_mapped_so_is_claimed_as_ours(tmp: Path) -> None:
    """A name-only listing is ours when this instance has our .so mapped.

    Hyprland 0.56 omits plugin paths. After a shell restart the loaded-in
    record can be missing even though our .so is still mapped; that must
    not look like a foreign hyprpm copy.
    """
    env = _load_stub(tmp, "[]", load_exit=1)
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "test_instance"
    so = Path(env["XDG_STATE_HOME"]) / "omarchy" / "omacursorshake" / "dynamic-cursors.so"
    fd = os.open(so, os.O_RDONLY)
    mapping = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
    load_log = tmp / "hyprctl-load.log"
    body = (
        "#!/bin/sh\n"
        f"echo \"$*\" >> {load_log}\n"
        "case \"$*\" in\n"
        "  *version*) printf '{\"commit\":\"efb50993780079460b0cbed1363e2166a2de1d9f\"}\\n' ;;\n"
        f"  *instances*) printf '[{{\"instance\":\"test_instance\",\"pid\":{os.getpid()}}}]\\n' ;;\n"
        "  *'plugin list'*) printf '[{\"name\":\"dynamic-cursors\"}]\\n' ;;\n"
        "  *'plugin load'*) echo LOAD_ATTEMPTED >> \"$0.log\"; exit 1 ;;\n"
        "  *) printf 'ok\\n' ;;\n"
        "esac\n"
    )
    (tmp / "stubs" / "hyprctl").write_text(body)
    try:
        proc = _run_load(env)
    finally:
        mapping.close()
        os.close(fd)
    assert_true(proc.returncode == 0, f"mapped .so was not claimed: {proc.stderr!r}")
    assert_true(b'"loaded": true' in proc.stdout, f"status: {proc.stdout!r}")
    logged = load_log.read_text() if load_log.exists() else ""
    assert_true("plugin load" not in logged, f"tried to load a second copy: {logged!r}")
    state = Path(env["XDG_STATE_HOME"]) / "omarchy" / "omacursorshake"
    assert_true(
        (state / "loaded-in").read_text().strip() == "test_instance",
        "maps proof was not recorded for this instance",
    )


def test_confirmed_load_is_recorded_per_instance(tmp: Path) -> None:
    """The happy path still works, and the proof is scoped to one instance."""
    env = _load_stub(tmp / "ok", '[{"name":"dynamic-cursors"}]', load_exit=0)
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "test_instance"
    proc = _run_load(env)
    assert_true(proc.returncode == 0, f"load failed: {proc.stderr!r}")
    assert_true(b'"loaded": true' in proc.stdout, f"status: {proc.stdout!r}")

    state = Path(env["XDG_STATE_HOME"]) / "omarchy" / "omacursorshake"
    assert_true(
        (state / "loaded-in").read_text().strip() == "test_instance",
        "load was not recorded against the compositor instance",
    )

    # A compositor restart changes the signature, so the record stops being
    # evidence and the same listing is no longer proof of our load.
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "other_instance"
    proc = subprocess.run(
        ["bash", str(BACKEND), "status"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode == 0, f"status failed: {proc.stderr!r}")
    assert_true(
        b'"loaded": false' in proc.stdout,
        f"stale record survived a compositor restart: {proc.stdout!r}",
    )


def test_cursor_theme_option_injection_refused(tmp: Path) -> None:
    argv_log = tmp / "hyprctl-argv.log"
    body = (
        "#!/bin/sh\n"
        f"echo \"$*\" >> {argv_log}\n"
        "case \"$*\" in\n"
        "  *version*) printf '{\"commit\":\"efb50993780079460b0cbed1363e2166a2de1d9f\"}\\n' ;;\n"
        "  *'plugin list'*) printf '[{\"name\":\"dynamic-cursors\"}]\\n' ;;\n"
        "  *) printf 'ok\\n' ;;\n"
        "esac\n"
    )
    env = _hyprctl_stub(tmp / "theme", body)
    env["HYPRCURSOR_THEME"] = "--evil-option"
    # apply only evals into a plugin it can prove is ours, and the listing
    # carries no path, so record a load for this instance first. Without it
    # the run stops at write_apply_lua and never reaches setcursor.
    env["HYPRLAND_INSTANCE_SIGNATURE"] = "test_instance"
    state = Path(env["XDG_STATE_HOME"]) / "omarchy" / "omacursorshake"
    state.mkdir(parents=True, exist_ok=True)
    (state / "loaded-in").write_text("test_instance\n")
    proc = subprocess.run(
        ["bash", str(BACKEND), "apply", '{"enabled":true}'],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode == 0, f"apply failed: {proc.stderr!r}")
    logged = argv_log.read_text()
    assert_true("setcursor Adwaita" in logged, f"theme not sanitised: {logged!r}")
    assert_true("--evil-option" not in logged, f"option reached hyprctl: {logged!r}")


def test_tree_digest_is_canonical(tmp: Path) -> None:
    """Same bytes -> same digest; any byte, mode, or name change -> different."""
    def build(root: Path, order: list[str], body: bytes = b"int main(){}\n") -> Path:
        root.mkdir(parents=True)
        (root / ".git").mkdir()
        (root / ".git" / "config").write_bytes(b"[core]\n")
        (root / "src").mkdir()
        for name in order:
            (root / "src" / name).write_bytes(body)
        (root / "Makefile").write_bytes(b"all:\n")
        return root

    a = build(tmp / "a", ["a.cpp", "b.cpp", "c.cpp"])
    b = build(tmp / "deeper" / "path" / "b", ["c.cpp", "a.cpp", "b.cpp"])
    da, db = tree_digest(a), tree_digest(b)
    assert_true(da == db, "digest depends on creation order or on the tree's own path")
    assert_true(len(da) == 64, f"not a sha256: {da}")

    # .git differs between clones and is not compiled; it must not be hashed.
    (a / ".git" / "config").write_bytes(b"[core]\n\tfsmonitor = evil\n")
    assert_true(tree_digest(a) == da, ".git is being hashed")

    (a / "src" / "a.cpp").write_bytes(b"int main(){ }\n")
    assert_true(tree_digest(a) != da, "content change did not move the digest")

    c = build(tmp / "c", ["a.cpp", "b.cpp", "c.cpp"])
    (c / "Makefile").chmod(0o755)
    assert_true(tree_digest(c) != da, "executable bit did not move the digest")

    d = build(tmp / "d", ["a.cpp", "b.cpp", "c.cpp"])
    (d / "src" / "c.cpp").rename(d / "src" / "d.cpp")
    assert_true(tree_digest(d) != da, "renaming a file did not move the digest")

    e = build(tmp / "e", ["a.cpp", "b.cpp"])
    (e / "src" / "c.cpp").parent.mkdir(exist_ok=True)
    (e / "src" / "c.cpp").write_bytes(b"")
    f = build(tmp / "f", ["a.cpp", "b.cpp"])
    (f / "src" / "c.cpp").write_bytes(b"")
    (f / "src" / "c.cpp").write_bytes(b"")
    assert_true(tree_digest(e) == tree_digest(f), "empty files hash inconsistently")


def test_tree_digest_refuses_links_and_specials(tmp: Path) -> None:
    """A link or special file in the tree is refused, never followed or skipped."""
    root = tmp / "src"
    (root / "sub").mkdir(parents=True)
    (root / "Makefile").write_bytes(b"all:\n")
    secret = tmp / "outside.txt"
    secret.write_bytes(b"not part of the tree\n")

    (root / "sub" / "link.cpp").symlink_to(secret)
    proc = run(["tree-digest", str(root)], check=False)
    assert_true(proc.returncode != 0, "symlinked file was digested")
    assert_true(b"symlink in source tree" in proc.stderr, f"err: {proc.stderr!r}")
    (root / "sub" / "link.cpp").unlink()

    (root / "sub" / "dirlink").symlink_to(tmp)
    proc = run(["tree-digest", str(root)], check=False)
    assert_true(proc.returncode != 0, "symlinked directory was digested")
    assert_true(b"symlink in source tree" in proc.stderr, f"err: {proc.stderr!r}")
    (root / "sub" / "dirlink").unlink()

    os.mkfifo(root / "sub" / "pipe")
    proc = run(["tree-digest", str(root)], check=False)
    assert_true(proc.returncode != 0, "fifo was digested")
    assert_true(b"not a regular file" in proc.stderr, f"err: {proc.stderr!r}")


def test_source_digest_gate_runs_before_make(tmp: Path) -> None:
    """A tree that is not the reviewed source must not reach the compiler."""
    good = b"// the reviewed source\n"
    reference = tmp / "reference"
    reference.mkdir()
    (reference / ".git").mkdir()
    (reference / "source.cpp").write_bytes(good)
    expected = tree_digest(reference)
    backend = patched_backend(tmp, expected)

    env = backend_env(tmp, tmp / "ok" / "state")
    env["STUB_SRC"] = good.decode()
    env["STUB_ARGV_LOG"] = str(tmp / "make-ok.log")
    proc = subprocess.run(
        ["bash", str(backend), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode == 0, f"matching tree refused: {proc.stderr!r}")
    assert_true((tmp / "make-ok.log").exists(), "make never ran on the matching tree")

    # One byte different: the commit SHA and the clean-tree check still pass,
    # because the stub git reports what it is told to. Only the digest reads
    # the bytes.
    env = backend_env(tmp, tmp / "bad" / "state")
    env["STUB_SRC"] = "// the reviewed sourc3\n"
    argv_log = tmp / "make-bad.log"
    env["STUB_ARGV_LOG"] = str(argv_log)
    proc = subprocess.run(
        ["bash", str(backend), "ensure"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
    )
    assert_true(proc.returncode != 0, "tampered tree was built")
    assert_true(b"digest is" in proc.stderr, f"err: {proc.stderr!r}")
    assert_true(not argv_log.exists(), "make ran before the digest gate refused the tree")
    assert_true(
        not (tmp / "bad" / "state" / "omarchy" / "omacursorshake" / "dynamic-cursors.so").exists(),
        "a .so was installed from a tampered tree",
    )


def test_every_pin_has_a_source_digest() -> None:
    """No Hyprland version may map to a plugin commit we have not attested."""
    text = BACKEND.read_text()

    def case_body(name: str) -> str:
        start = text.index(f"{name}() {{")
        return text[start : text.index("\n}\n", start)]

    entry = re.compile(r'^\s*([0-9a-f]{40})\) echo "([0-9a-f]{40,64})" ;;', re.M)
    revs = {v for _, v in entry.findall(case_body("plugin_rev_for"))}
    digests = {k: v for k, v in entry.findall(case_body("plugin_digest_for"))}
    assert_true(bool(revs), "no pinned plugin commits found")
    missing = sorted(revs - set(digests))
    assert_true(not missing, f"pins without a source digest: {missing}")
    stale = sorted(set(digests) - revs)
    assert_true(not stale, f"digests for commits nothing maps to: {stale}")
    for rev, d in digests.items():
        assert_true(len(d) == 64, f"{rev}: digest is not sha256: {d}")

    assert_true("plugin_digest_for" in case_body("verify_source_tree"),
                "verify_source_tree does not consult the digest table")
    assert_true("tree-digest" in case_body("verify_source_tree"),
                "verify_source_tree does not digest the checked-out tree")


def test_watchdog_and_installer_guards() -> None:
    qml = (HERE.parent / "Service.qml").read_text()
    assert_true("jobWatchdog" in qml and "job.running = false" in qml, "no Process watchdog")
    assert_true("running: job.running" in qml, "watchdog is not armed by the job")
    installer = (HERE.parent / "install.sh").read_text()
    assert_true("A-Za-z0-9._-" in installer, "installer does not validate the manifest id")


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
        test_read_tail_returns_end_of_file,
        test_writable_path_component_refused,
        test_foreign_owned_component_refused,
        test_remove_depth_bounded,
        test_backend_refuses_unsafe_state_path,
        test_backend_build_pipeline,
        test_backend_build_log_budget,
        test_concurrent_publish_no_inode_mismatch,
        test_publish_lock_times_out,
        test_settings_has_one_writer,
        test_hyprctl_calls_are_time_bounded,
        test_hyprctl_output_is_byte_bounded,
        test_gnumakefile_precedence_is_defeated,
        test_planted_source_tree_is_destroyed,
        test_checkout_must_match_the_pin,
        test_load_requires_hyprctl_exit_status,
        test_foreign_plugin_is_not_claimed_as_ours,
        test_maps_has_matches_exact_pathname,
        test_mapped_so_is_claimed_as_ours,
        test_confirmed_load_is_recorded_per_instance,
        test_cursor_theme_option_injection_refused,
        test_tree_digest_is_canonical,
        test_tree_digest_refuses_links_and_specials,
        test_source_digest_gate_runs_before_make,
        test_every_pin_has_a_source_digest,
        test_watchdog_and_installer_guards,
    ]
    failed = 0
    for test in tests:
        tmp = Path(tempfile.mkdtemp(prefix="stateio-test-"))
        try:
            if test in (test_source_never_reopens_full_path, test_watchdog_and_installer_guards,
                        test_every_pin_has_a_source_digest):
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
