#!/usr/bin/env python3
"""Secure I/O for omacursorshake state files.

Predictable paths under the state directory are never opened through a
symlink or FIFO. Writes go to an O_EXCL temporary in the same directory,
are fsynced, then renamed into place.
"""

from __future__ import annotations

import errno
import os
import stat
import sys
import tempfile

CLOEXEC = getattr(os, "O_CLOEXEC", 0)
NOFOLLOW = os.O_NOFOLLOW
NONBLOCK = os.O_NONBLOCK


def fail(msg: str, code: int = 1) -> None:
    sys.stderr.write(f"omacursorshake: {msg}\n")
    raise SystemExit(code)


def lstat_dir(path: str) -> os.stat_result:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        fail(f"missing directory: {path}")
    if stat.S_ISLNK(st.st_mode):
        fail(f"refusing symlink directory: {path}")
    if not stat.S_ISDIR(st.st_mode):
        fail(f"not a directory: {path}")
    if st.st_uid != os.getuid():
        fail(f"directory not owned by current user: {path}")
    return st


def ensure_dir(path: str) -> None:
    path = os.path.abspath(path)
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    try:
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            fail(f"refusing symlink directory: {path}")
        if not stat.S_ISDIR(st.st_mode):
            fail(f"not a directory: {path}")
    except FileNotFoundError:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                fail(f"refusing symlink directory: {path}")
            if not stat.S_ISDIR(st.st_mode):
                fail(f"not a directory: {path}")
        else:
            st = os.lstat(path)
    if st.st_uid != os.getuid():
        fail(f"directory not owned by current user: {path}")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        fail(f"directory check failed: {path}")
    os.chmod(path, 0o700)
    st2 = os.lstat(path)
    if stat.S_ISLNK(st2.st_mode) or not stat.S_ISDIR(st2.st_mode) or st2.st_uid != os.getuid():
        fail(f"directory mutated during setup: {path}")


def validate_reg_fd(fd: int, path: str) -> os.stat_result:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        fail(f"not a regular file: {path}")
    if st.st_uid != os.getuid():
        fail(f"file not owned by current user: {path}")
    return st


def secure_open_read(path: str) -> int:
    flags = os.O_RDONLY | NOFOLLOW | NONBLOCK | CLOEXEC
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        raise
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            fail(f"refusing to follow symlink: {path}")
        if exc.errno in (errno.ENXIO, errno.EAGAIN, errno.EWOULDBLOCK):
            fail(f"refusing to block on special file: {path}")
        fail(f"open failed ({exc.strerror}): {path}")
    try:
        validate_reg_fd(fd, path)
    except SystemExit:
        os.close(fd)
        raise
    return fd


def read_file(path: str, max_bytes: int) -> bytes:
    try:
        fd = secure_open_read(path)
    except FileNotFoundError:
        return b""
    try:
        data = b""
        while len(data) < max_bytes:
            chunk = os.read(fd, min(8192, max_bytes - len(data)))
            if not chunk:
                break
            data += chunk
        return data
    finally:
        os.close(fd)


def atomic_publish(dir_path: str, dest: str, fd: int, tmp_name: str) -> None:
    os.fsync(fd)
    os.close(fd)
    os.rename(tmp_name, dest)
    dfd = os.open(dir_path, os.O_RDONLY | os.O_DIRECTORY | CLOEXEC)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def write_file(path: str, data: bytes, mode: int = 0o600) -> None:
    path = os.path.abspath(path)
    dir_path = os.path.dirname(path)
    ensure_dir(dir_path)
    lstat_dir(dir_path)
    fd, tmp_name = tempfile.mkstemp(prefix=".tmp.", dir=dir_path)
    try:
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.ftruncate(fd, len(data))
        atomic_publish(dir_path, path, fd, tmp_name)
        fd = -1
        tmp_name = ""
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


def write_ring_from_stdin(path: str, budget: int) -> int:
    path = os.path.abspath(path)
    dir_path = os.path.dirname(path)
    ensure_dir(dir_path)
    lstat_dir(dir_path)
    fd, tmp_name = tempfile.mkstemp(prefix=".tmp.", dir=dir_path)
    exceeded = False
    try:
        os.fchmod(fd, 0o600)
        buf = bytearray()
        total = 0
        while True:
            chunk = os.read(0, 8192)
            if not chunk:
                break
            total += len(chunk)
            buf.extend(chunk)
            if len(buf) > budget:
                del buf[: len(buf) - budget]
            os.lseek(fd, 0, os.SEEK_SET)
            written = 0
            while written < len(buf):
                written += os.write(fd, buf[written:])
            os.ftruncate(fd, len(buf))
            os.fsync(fd)
            if total > budget:
                exceeded = True
                break
        atomic_publish(dir_path, path, fd, tmp_name)
        fd = -1
        tmp_name = ""
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
    return 2 if exceeded else 0


def exists_reg(path: str) -> bool:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and not stat.S_ISLNK(st.st_mode)


def remove_tree(path: str) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        fail(f"refusing to remove symlink: {path}")
    if stat.S_ISDIR(st.st_mode):
        for name in os.listdir(path):
            remove_tree(os.path.join(path, name))
        os.rmdir(path)
        return
    os.unlink(path)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        fail("stateio: usage: ensure-dir|read|write|write-ring|exists|rm-tree ...")
    cmd = argv[1]
    if cmd == "ensure-dir":
        if len(argv) != 3:
            fail("stateio ensure-dir <dir>")
        ensure_dir(argv[2])
        return 0
    if cmd == "read":
        if len(argv) not in (3, 4):
            fail("stateio read <path> [max-bytes]")
        max_bytes = int(argv[3]) if len(argv) == 4 else 65536
        sys.stdout.buffer.write(read_file(argv[2], max_bytes))
        return 0
    if cmd == "write":
        if len(argv) not in (3, 4):
            fail("stateio write <path> [mode]")
        mode = int(argv[3], 8) if len(argv) == 4 else 0o600
        write_file(argv[2], sys.stdin.buffer.read(), mode)
        return 0
    if cmd == "write-ring":
        if len(argv) != 4:
            fail("stateio write-ring <path> <budget>")
        return write_ring_from_stdin(argv[2], int(argv[3]))
    if cmd == "exists":
        if len(argv) != 3:
            fail("stateio exists <path>")
        return 0 if exists_reg(argv[2]) else 1
    if cmd == "rm-tree":
        if len(argv) != 3:
            fail("stateio rm-tree <path>")
        remove_tree(argv[2])
        return 0
    fail(f"stateio: unknown command {cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
