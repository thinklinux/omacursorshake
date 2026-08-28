#!/usr/bin/env python3
"""Secure I/O for omacursorshake state files.

Every path component is lstat'd; directories are opened with
O_NOFOLLOW|O_DIRECTORY. Predictable files are read with
O_NOFOLLOW|O_NONBLOCK and the descriptor is fstat'd. Writes use an
O_EXCL temporary created in the already-opened destination directory,
held open through write, fsync, and rename, then the directory is
fsynced.
"""

from __future__ import annotations

import errno
import os
import secrets
import stat
import sys

CLOEXEC = getattr(os, "O_CLOEXEC", 0)
NOFOLLOW = os.O_NOFOLLOW
NONBLOCK = os.O_NONBLOCK
MAX_COPY = 32 * 1024 * 1024


def fail(msg: str, code: int = 1) -> None:
    sys.stderr.write(f"omacursorshake: {msg}\n")
    raise SystemExit(code)


def dir_names(path: str) -> list[str]:
    path = os.path.abspath(path)
    names: list[str] = []
    while True:
        parent, name = os.path.split(path)
        if not name:
            break
        names.append(name)
        path = parent
    names.reverse()
    return names


def map_open_error(exc: OSError, path: str) -> None:
    if exc.errno in (errno.ELOOP, errno.EMLINK):
        fail(f"refusing to follow symlink: {path}")
    if exc.errno in (errno.ENXIO, errno.EAGAIN, errno.EWOULDBLOCK):
        fail(f"refusing to block on special file: {path}")
    fail(f"open failed ({exc.strerror}): {path}")


def lstat_at(dirfd: int | None, name: str) -> os.stat_result:
    if dirfd is None:
        return os.lstat(name)
    return os.lstat(name, dir_fd=dirfd)


def openat_dir(dirfd: int | None, name: str, label: str, *, missing_ok: bool = False) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC
    try:
        if dirfd is None:
            fd = os.open(name, flags)
        else:
            fd = os.open(name, flags, dir_fd=dirfd)
    except FileNotFoundError:
        if missing_ok:
            raise
        fail(f"missing directory: {label}")
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK, errno.ENOTDIR):
            try:
                if stat.S_ISLNK(lstat_at(dirfd, name).st_mode):
                    fail(f"refusing symlink directory: {label}")
            except FileNotFoundError:
                pass
        map_open_error(exc, label)
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        os.close(fd)
        fail(f"not a directory: {label}")
    return fd


def open_dir_nofollow(path: str) -> int:
    return openat_dir(None, os.path.abspath(path), path)


def mkdirat_nofollow(dirfd: int, name: str, label: str) -> None:
    try:
        os.mkdir(name, 0o700, dir_fd=dirfd)
    except FileExistsError:
        pass
    except OSError as exc:
        fail(f"mkdir failed ({exc.strerror}): {label}")


def ensure_dir(path: str) -> None:
    path = os.path.abspath(path)
    names = dir_names(path)
    if not names:
        fail(f"invalid directory: {path}")
    dirfd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | CLOEXEC)
    walked = ""
    try:
        for name in names:
            walked = walked + "/" + name
            try:
                nextfd = openat_dir(dirfd, name, walked, missing_ok=True)
            except FileNotFoundError:
                mkdirat_nofollow(dirfd, name, walked)
                nextfd = openat_dir(dirfd, name, walked)
            os.close(dirfd)
            dirfd = nextfd
        st = os.fstat(dirfd)
        if st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {path}")
        os.fchmod(dirfd, 0o700)
        st2 = os.fstat(dirfd)
        if not stat.S_ISDIR(st2.st_mode) or st2.st_uid != os.getuid():
            fail(f"directory mutated during setup: {path}")
        if (st2.st_mode & 0o777) != 0o700:
            fail(f"directory mode mutated during setup: {path}")
    finally:
        os.close(dirfd)


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
        map_open_error(exc, path)
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


def mkstemp_in_dir(dirfd: int, mode: int) -> tuple[int, str]:
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC
    for _ in range(128):
        name = ".tmp." + secrets.token_hex(12)
        try:
            fd = os.open(name, flags, 0o600, dir_fd=dirfd)
        except FileExistsError:
            continue
        except OSError as exc:
            if exc.errno in (errno.ELOOP, errno.EMLINK):
                fail("refusing to follow symlink temporary")
            raise
        try:
            os.fchmod(fd, mode)
        except OSError:
            os.close(fd)
            try:
                os.unlink(name, dir_fd=dirfd)
            except FileNotFoundError:
                pass
            raise
        return fd, name
    fail("could not create temporary file")
    raise AssertionError("unreachable")


def publish_held_fd(dirfd: int, fd: int, tmp_name: str, dest_name: str, dest: str) -> None:
    os.fsync(fd)
    os.rename(tmp_name, dest_name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
    os.fsync(dirfd)
    published = os.fstat(fd)
    dest_st = os.stat(dest_name, dir_fd=dirfd, follow_symlinks=False)
    if dest_st.st_ino != published.st_ino or dest_st.st_dev != published.st_dev:
        fail(f"publish inode mismatch: {dest}")
    if not stat.S_ISREG(published.st_mode) or published.st_uid != os.getuid():
        fail(f"published file invalid: {dest}")


def write_file(path: str, data: bytes, mode: int = 0o600) -> None:
    path = os.path.abspath(path)
    dir_path = os.path.dirname(path)
    dest_name = os.path.basename(path)
    if not dest_name or dest_name in (".", ".."):
        fail(f"invalid destination: {path}")
    ensure_dir(dir_path)
    dirfd = open_dir_nofollow(dir_path)
    fd = -1
    tmp_name = ""
    try:
        st = os.fstat(dirfd)
        if st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {dir_path}")
        fd, tmp_name = mkstemp_in_dir(dirfd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.ftruncate(fd, len(data))
        publish_held_fd(dirfd, fd, tmp_name, dest_name, path)
        tmp_name = ""
    except OSError as exc:
        fail(f"write failed ({exc.strerror}): {path}")
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        os.close(dirfd)


def write_ring_from_stdin(path: str, budget: int) -> int:
    path = os.path.abspath(path)
    dir_path = os.path.dirname(path)
    dest_name = os.path.basename(path)
    if not dest_name or dest_name in (".", ".."):
        fail(f"invalid destination: {path}")
    ensure_dir(dir_path)
    dirfd = open_dir_nofollow(dir_path)
    fd = -1
    tmp_name = ""
    exceeded = False
    try:
        st = os.fstat(dirfd)
        if st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {dir_path}")
        fd, tmp_name = mkstemp_in_dir(dirfd, 0o600)
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
        publish_held_fd(dirfd, fd, tmp_name, dest_name, path)
        tmp_name = ""
    except OSError as exc:
        fail(f"write failed ({exc.strerror}): {path}")
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        os.close(dirfd)
    return 2 if exceeded else 0


def copy_file(src: str, dest: str, mode: int) -> None:
    try:
        fd = secure_open_read(src)
    except FileNotFoundError:
        fail(f"missing file: {src}")
    try:
        data = b""
        while True:
            chunk = os.read(fd, 8192)
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_COPY:
                fail(f"file exceeds {MAX_COPY}-byte copy limit: {src}")
    finally:
        os.close(fd)
    write_file(dest, data, mode)


def exists_reg(path: str) -> bool:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid()


def exists_dir(path: str) -> bool:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid()


def remove_tree(path: str) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode) or stat.S_ISREG(st.st_mode):
        os.unlink(path)
        return
    if not stat.S_ISDIR(st.st_mode):
        fail(f"refusing to remove special file: {path}")
    if st.st_uid != os.getuid():
        fail(f"refusing to remove directory not owned by current user: {path}")
    for name in os.listdir(path):
        remove_tree(os.path.join(path, name))
    os.rmdir(path)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        fail(
            "stateio: usage: ensure-dir|read|write|write-ring|copy|exists|is-dir|rm-tree ..."
        )
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
    if cmd == "copy":
        if len(argv) not in (4, 5):
            fail("stateio copy <src> <dest> [mode]")
        mode = int(argv[4], 8) if len(argv) == 5 else 0o600
        copy_file(argv[2], argv[3], mode)
        return 0
    if cmd == "exists":
        if len(argv) != 3:
            fail("stateio exists <path>")
        return 0 if exists_reg(argv[2]) else 1
    if cmd == "is-dir":
        if len(argv) != 3:
            fail("stateio is-dir <path>")
        return 0 if exists_dir(argv[2]) else 1
    if cmd == "rm-tree":
        if len(argv) != 3:
            fail("stateio rm-tree <path>")
        remove_tree(argv[2])
        return 0
    fail(f"stateio: unknown command {cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
