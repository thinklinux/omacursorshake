#!/usr/bin/env python3
"""Secure I/O for omacursorshake state files.

Every path component is opened with O_NOFOLLOW|O_DIRECTORY from `/`.
The final directory descriptor from that walk is kept and used for
reads, writes, ring captures, copies, existence checks, and recursive
removal. Full pathnames are never reopened after the walk. Every walked
component must also be a non-symlink directory that is owned by the
current user (or root) and is not group/other writable without the
sticky bit, so no other account can swap a component under us. Files are
opened with O_NOFOLLOW|O_NONBLOCK via dir_fd and fstat'd. Writes use an
O_EXCL temporary in the already-opened directory, held open through
write, fsync, and rename. Removal unlinks with dir_fd, is depth-bounded,
and refuses mount or identity changes.
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
MAX_REMOVE_DEPTH = 64
GROUP_OTHER_WRITE = stat.S_IWGRP | stat.S_IWOTH


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


def split_leaf(path: str) -> tuple[str, str]:
    path = os.path.abspath(path)
    parent, name = os.path.dirname(path), os.path.basename(path)
    if not name or name in (".", ".."):
        fail(f"invalid path: {path}")
    return parent, name


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


def openat_dir(dirfd: int, name: str, label: str, *, missing_ok: bool = False) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC
    try:
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
    try:
        validate_component_fd(fd, label)
    except SystemExit:
        os.close(fd)
        raise
    return fd


def validate_component_fd(fd: int, label: str) -> os.stat_result:
    """A walked component must not be swappable by another account."""
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        fail(f"not a directory: {label}")
    if st.st_uid not in (os.getuid(), 0):
        fail(f"path component not owned by the current user or root: {label}")
    if (st.st_mode & GROUP_OTHER_WRITE) and not (st.st_mode & stat.S_ISVTX):
        fail(
            "refusing group/other-writable path component "
            f"(mode {st.st_mode & 0o7777:04o}; chmod go-w it): {label}"
        )
    return st


def mkdirat_nofollow(dirfd: int, name: str, label: str) -> None:
    try:
        os.mkdir(name, 0o700, dir_fd=dirfd)
    except FileExistsError:
        pass
    except OSError as exc:
        fail(f"mkdir failed ({exc.strerror}): {label}")


def walk_dir(path: str, *, create: bool = False) -> int:
    """Open path component-by-component with O_NOFOLLOW. Caller owns the fd."""
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
                if not create:
                    raise
                mkdirat_nofollow(dirfd, name, walked)
                nextfd = openat_dir(dirfd, name, walked)
            os.close(dirfd)
            dirfd = nextfd
        st = os.fstat(dirfd)
        if not stat.S_ISDIR(st.st_mode):
            fail(f"not a directory: {path}")
        if st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {path}")
        if create:
            os.fchmod(dirfd, 0o700)
            st2 = os.fstat(dirfd)
            if not stat.S_ISDIR(st2.st_mode) or st2.st_uid != os.getuid():
                fail(f"directory mutated during setup: {path}")
            if (st2.st_mode & 0o777) != 0o700:
                fail(f"directory mode mutated during setup: {path}")
        return dirfd
    except Exception:
        os.close(dirfd)
        raise


def open_dir_walk(path: str) -> int:
    return walk_dir(path, create=False)


def ensure_dir_fd(path: str) -> int:
    return walk_dir(path, create=True)


def ensure_dir(path: str) -> None:
    os.close(ensure_dir_fd(path))


def validate_reg_fd(fd: int, path: str) -> os.stat_result:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        fail(f"not a regular file: {path}")
    if st.st_uid != os.getuid():
        fail(f"file not owned by current user: {path}")
    return st


def valid_dirent_name(name: str) -> None:
    if not name or name in (".", "..") or "/" in name or name in (os.sep, os.pardir):
        fail(f"invalid directory entry: {name}")


def open_reg_at(dirfd: int, name: str, label: str) -> int:
    valid_dirent_name(name)
    flags = os.O_RDONLY | NOFOLLOW | NONBLOCK | CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=dirfd)
    except FileNotFoundError:
        raise
    except OSError as exc:
        map_open_error(exc, label)
    try:
        validate_reg_fd(fd, label)
    except SystemExit:
        os.close(fd)
        raise
    return fd


def read_fd(fd: int, max_bytes: int) -> bytes:
    data = b""
    while len(data) < max_bytes:
        chunk = os.read(fd, min(8192, max_bytes - len(data)))
        if not chunk:
            break
        data += chunk
    return data


def read_file(path: str, max_bytes: int) -> bytes:
    parent, name = split_leaf(path)
    try:
        dirfd = walk_dir(parent, create=False)
    except FileNotFoundError:
        return b""
    try:
        try:
            fd = open_reg_at(dirfd, name, path)
        except FileNotFoundError:
            return b""
        try:
            return read_fd(fd, max_bytes)
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def read_tail(path: str, max_bytes: int) -> bytes:
    """Last max_bytes of a state file, through the held walk descriptor."""
    parent, name = split_leaf(path)
    try:
        dirfd = walk_dir(parent, create=False)
    except FileNotFoundError:
        return b""
    try:
        try:
            fd = open_reg_at(dirfd, name, path)
        except FileNotFoundError:
            return b""
        try:
            size = os.fstat(fd).st_size
            if size > max_bytes:
                os.lseek(fd, size - max_bytes, os.SEEK_SET)
            return read_fd(fd, max_bytes)
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


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


def write_through_dirfd(dirfd: int, dest_name: str, dest: str, data: bytes, mode: int) -> None:
    st = os.fstat(dirfd)
    if st.st_uid != os.getuid():
        fail(f"directory not owned by current user: {dest}")
    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = mkstemp_in_dir(dirfd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.ftruncate(fd, len(data))
        publish_held_fd(dirfd, fd, tmp_name, dest_name, dest)
        tmp_name = ""
    except OSError as exc:
        fail(f"write failed ({exc.strerror}): {dest}")
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


def write_file(path: str, data: bytes, mode: int = 0o600) -> None:
    parent, dest_name = split_leaf(path)
    dirfd = ensure_dir_fd(parent)
    try:
        write_through_dirfd(dirfd, dest_name, path, data, mode)
    finally:
        os.close(dirfd)


def write_ring_from_stdin(path: str, budget: int) -> int:
    parent, dest_name = split_leaf(path)
    dirfd = ensure_dir_fd(parent)
    fd = -1
    tmp_name = ""
    exceeded = False
    try:
        st = os.fstat(dirfd)
        if st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {parent}")
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
    src_parent, src_name = split_leaf(src)
    try:
        src_dirfd = walk_dir(src_parent, create=False)
    except FileNotFoundError:
        fail(f"missing file: {src}")
    try:
        try:
            fd = open_reg_at(src_dirfd, src_name, src)
        except FileNotFoundError:
            fail(f"missing file: {src}")
        try:
            data = read_fd(fd, MAX_COPY + 1)
        finally:
            os.close(fd)
    finally:
        os.close(src_dirfd)
    if len(data) > MAX_COPY:
        fail(f"file exceeds {MAX_COPY}-byte copy limit: {src}")
    write_file(dest, data, mode)


def exists_reg(path: str) -> bool:
    parent, name = split_leaf(path)
    try:
        dirfd = walk_dir(parent, create=False)
    except FileNotFoundError:
        return False
    try:
        st = os.lstat(name, dir_fd=dirfd)
    except FileNotFoundError:
        return False
    finally:
        os.close(dirfd)
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid()


def exists_dir(path: str) -> bool:
    parent, name = split_leaf(path)
    try:
        dirfd = walk_dir(parent, create=False)
    except FileNotFoundError:
        return False
    try:
        st = os.lstat(name, dir_fd=dirfd)
    except FileNotFoundError:
        return False
    finally:
        os.close(dirfd)
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid()


def dir_ident(st: os.stat_result) -> tuple[int, int, int]:
    return (st.st_dev, st.st_ino, st.st_uid)


def assert_dir_ident(fd: int, expected: tuple[int, int, int], label: str) -> os.stat_result:
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode):
        fail(f"not a directory: {label}")
    if dir_ident(st) != expected:
        fail(f"directory identity changed during removal: {label}")
    return st


def remove_dir_contents(
    dirfd: int,
    dir_expected: tuple[int, int, int],
    rootfd: int,
    root_expected: tuple[int, int, int],
    root_dev: int,
    label: str,
    depth: int,
) -> None:
    if depth > MAX_REMOVE_DEPTH:
        fail(f"refusing to recurse past {MAX_REMOVE_DEPTH} levels: {label}")
    assert_dir_ident(rootfd, root_expected, "state directory")
    assert_dir_ident(dirfd, dir_expected, label)
    for name in os.listdir(dirfd):
        valid_dirent_name(name)
        remove_entry(
            dirfd, name, dir_expected, rootfd, root_expected, root_dev, f"{label}/{name}", depth
        )
        assert_dir_ident(rootfd, root_expected, "state directory")
        assert_dir_ident(dirfd, dir_expected, label)


def remove_entry(
    parentfd: int,
    name: str,
    parent_expected: tuple[int, int, int],
    rootfd: int,
    root_expected: tuple[int, int, int],
    root_dev: int,
    label: str,
    depth: int = 0,
) -> None:
    if depth > MAX_REMOVE_DEPTH:
        fail(f"refusing to recurse past {MAX_REMOVE_DEPTH} levels: {label}")
    valid_dirent_name(name)
    assert_dir_ident(rootfd, root_expected, "state directory")
    assert_dir_ident(parentfd, parent_expected, os.path.dirname(label) or ".")

    try:
        lst = os.lstat(name, dir_fd=parentfd)
    except FileNotFoundError:
        return

    if lst.st_dev != root_dev:
        fail(f"refusing to cross mount boundary: {label}")

    dir_flags = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW | CLOEXEC
    file_flags = os.O_RDONLY | NOFOLLOW | NONBLOCK | CLOEXEC

    if stat.S_ISLNK(lst.st_mode):
        os.unlink(name, dir_fd=parentfd)
        return

    if stat.S_ISDIR(lst.st_mode):
        try:
            childfd = os.open(name, dir_flags, dir_fd=parentfd)
        except OSError as exc:
            if exc.errno in (errno.ELOOP, errno.EMLINK, errno.ENOTDIR):
                fail(f"directory entry mutated during removal: {label}")
            map_open_error(exc, label)
        try:
            cst = os.fstat(childfd)
            if not stat.S_ISDIR(cst.st_mode):
                fail(f"not a directory: {label}")
            if cst.st_uid != os.getuid():
                fail(f"directory not owned by current user: {label}")
            if cst.st_dev != root_dev:
                fail(f"refusing to cross mount boundary: {label}")
            if cst.st_ino != lst.st_ino or cst.st_dev != lst.st_dev:
                fail(f"entry identity changed during removal: {label}")
            child_expected = dir_ident(cst)
            remove_dir_contents(
                childfd, child_expected, rootfd, root_expected, root_dev, label, depth + 1
            )
            assert_dir_ident(childfd, child_expected, label)
        finally:
            os.close(childfd)
        try:
            os.rmdir(name, dir_fd=parentfd)
        except OSError as exc:
            fail(f"rmdir failed ({exc.strerror}): {label}")
        return

    try:
        fd = os.open(name, file_flags, dir_fd=parentfd)
    except FileNotFoundError:
        return
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            fail(f"entry mutated into a symlink during removal: {label}")
        map_open_error(exc, label)
    try:
        fst = os.fstat(fd)
        if stat.S_ISDIR(fst.st_mode):
            fail(f"entry identity changed during removal: {label}")
        if fst.st_uid != os.getuid():
            fail(f"file not owned by current user: {label}")
        if fst.st_dev != root_dev:
            fail(f"refusing to cross mount boundary: {label}")
        if fst.st_ino != lst.st_ino or fst.st_dev != lst.st_dev:
            fail(f"entry identity changed during removal: {label}")
    finally:
        os.close(fd)
    try:
        os.unlink(name, dir_fd=parentfd)
    except OSError as exc:
        fail(f"unlink failed ({exc.strerror}): {label}")


def remove_tree_in(root: str, name: str) -> None:
    valid_dirent_name(name)
    try:
        rootfd = walk_dir(root, create=False)
    except FileNotFoundError:
        return
    try:
        root_st = os.fstat(rootfd)
        if not stat.S_ISDIR(root_st.st_mode):
            fail(f"not a directory: {root}")
        if root_st.st_uid != os.getuid():
            fail(f"directory not owned by current user: {root}")
        root_expected = dir_ident(root_st)
        remove_entry(rootfd, name, root_expected, rootfd, root_expected, root_st.st_dev, name)
        assert_dir_ident(rootfd, root_expected, root)
    except OSError as exc:
        fail(f"remove failed ({exc.strerror}): {root}/{name}")
    finally:
        os.close(rootfd)


def remove_tree(path: str) -> None:
    path = os.path.abspath(path)
    remove_tree_in(os.path.dirname(path), os.path.basename(path))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        fail(
            "stateio: usage: ensure-dir|read|read-tail|write|write-ring|copy|exists"
            "|is-dir|rm-tree ..."
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
    if cmd == "read-tail":
        if len(argv) not in (3, 4):
            fail("stateio read-tail <path> [max-bytes]")
        max_bytes = int(argv[3]) if len(argv) == 4 else 65536
        sys.stdout.buffer.write(read_tail(argv[2], max_bytes))
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
        if len(argv) == 3:
            remove_tree(argv[2])
            return 0
        if len(argv) == 4:
            remove_tree_in(argv[2], argv[3])
            return 0
        fail("stateio rm-tree <path> | rm-tree <state-dir> <name>")
    fail(f"stateio: unknown command {cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
