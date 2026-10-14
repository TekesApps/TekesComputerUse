#!/usr/bin/env python3
"""Create a deterministic Kernel format-1 .tekesplugin archive."""

from __future__ import annotations

import argparse
import base64
import json
import os
import stat
import tempfile
from pathlib import Path


MAX_ARCHIVE_BYTES = 384 * 1_024 * 1_024
MAX_EXPANDED_BYTES = 256 * 1_024 * 1_024
MAX_ENTRY_BYTES = 128 * 1_024 * 1_024
MAX_ENTRIES = 4_096


def collect_entries(root: Path) -> list[dict[str, object]]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("plugin source must be a non-symlink directory")

    entries: list[dict[str, object]] = []
    expanded_bytes = 0

    def visit(directory: Path) -> None:
        nonlocal expanded_bytes
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            metadata = path.lstat()
            relative = path.relative_to(root).as_posix()
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"plugin source contains a symlink: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                entries.append({"path": relative, "kind": "directory"})
                visit(path)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_size > MAX_ENTRY_BYTES:
                    raise ValueError(f"plugin entry exceeds size limit: {relative}")
                expanded_bytes += metadata.st_size
                if expanded_bytes > MAX_EXPANDED_BYTES:
                    raise ValueError("expanded plugin exceeds size limit")
                entries.append(
                    {
                        "path": relative,
                        "kind": "file",
                        "executable": bool(metadata.st_mode & 0o111),
                        "data": base64.b64encode(path.read_bytes()).decode("ascii"),
                    }
                )
            else:
                raise ValueError(f"plugin source contains a special file: {relative}")
            if len(entries) > MAX_ENTRIES:
                raise ValueError("plugin contains too many entries")

    visit(root)
    if not entries:
        raise ValueError("plugin source is empty")
    entries.sort(key=lambda entry: str(entry["path"]))
    return entries


def package(source: Path, archive: Path) -> None:
    payload = json.dumps(
        {"archiveVersion": 1, "entries": collect_entries(source)},
        separators=(",", ":"),
    ).encode("utf-8")
    if not payload or len(payload) > MAX_ARCHIVE_BYTES:
        raise ValueError("plugin archive exceeds size limit")

    archive.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{archive.name}.", dir=archive.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    package(arguments.source, arguments.archive)
    print(f"Packaged {arguments.archive}")


if __name__ == "__main__":
    main()
