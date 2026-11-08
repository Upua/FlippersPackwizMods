#!/usr/bin/env python3
"""Offline consistency check of the packwiz packs under environments/*/pack.

For each pack.toml it checks, without any network access:
  * pack.toml's [index] hash matches index.toml;
  * every [[files]] entry in index.toml exists and its hash matches;
  * every file in the pack directory (except pack.toml and index.toml) is
    listed in index.toml;
  * every metafile (*.pw.toml) has a [download] section with a url and a
    hash of the right length for its hash-format.
Mod downloads themselves are not fetched. Exits 1 on any problem.

Usage: tests/check-packwiz.py [pack.toml ...]
"""

import hashlib
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
HEX_LENGTHS = {"sha1": 40, "sha256": 64, "sha512": 128, "md5": 32}
LOCAL_ALGORITHMS = {"sha1", "sha256", "sha512", "md5"}


def file_hash(path: pathlib.Path, algorithm: str) -> str:
    return hashlib.new(algorithm, path.read_bytes()).hexdigest()


def check_pack(pack_toml: pathlib.Path) -> list[str]:
    problems: list[str] = []
    pack_dir = pack_toml.parent
    rel = lambda p: p.relative_to(ROOT) if p.is_relative_to(ROOT) else p  # noqa: E731

    pack = tomllib.loads(pack_toml.read_text(encoding="utf-8"))
    index_info = pack.get("index", {})
    index_path = pack_dir / index_info.get("file", "index.toml")
    algorithm = index_info.get("hash-format", "")
    if algorithm not in LOCAL_ALGORITHMS:
        return [f"{rel(pack_toml)}: unsupported index hash-format {algorithm!r}"]
    if not index_path.is_file():
        return [f"{rel(pack_toml)}: index file missing: {rel(index_path)}"]
    if file_hash(index_path, algorithm) != index_info.get("hash", "").lower():
        problems.append(f"{rel(pack_toml)}: index hash does not match {rel(index_path)}")

    index = tomllib.loads(index_path.read_text(encoding="utf-8"))
    default_algorithm = index.get("hash-format", "")
    listed: set[pathlib.Path] = set()
    for entry in index.get("files", []):
        name = entry.get("file", "")
        path = (pack_dir / name).resolve()
        if not name or not path.is_relative_to(pack_dir.resolve()):
            problems.append(f"{rel(index_path)}: invalid file entry {name!r}")
            continue
        listed.add(path)
        if not path.is_file():
            problems.append(f"{rel(index_path)}: listed file missing: {name}")
            continue
        entry_algorithm = entry.get("hash-format", default_algorithm)
        if entry_algorithm not in LOCAL_ALGORITHMS:
            problems.append(f"{rel(index_path)}: {name}: unsupported hash-format {entry_algorithm!r}")
        elif file_hash(path, entry_algorithm) != entry.get("hash", "").lower():
            problems.append(f"{rel(index_path)}: hash mismatch for {name}")

        if entry.get("metafile") or name.endswith(".pw.toml"):
            try:
                meta = tomllib.loads(path.read_text(encoding="utf-8"))
            except tomllib.TOMLDecodeError as error:
                problems.append(f"{rel(path)}: invalid TOML: {error}")
                continue
            download = meta.get("download", {})
            meta_algorithm = download.get("hash-format", "")
            meta_hash = download.get("hash", "")
            if not download.get("url"):
                problems.append(f"{rel(path)}: no download url")
            if meta_algorithm not in HEX_LENGTHS:
                problems.append(f"{rel(path)}: unknown download hash-format {meta_algorithm!r}")
            elif not re.fullmatch(rf"[0-9a-fA-F]{{{HEX_LENGTHS[meta_algorithm]}}}", meta_hash):
                problems.append(f"{rel(path)}: download hash is not a {meta_algorithm} hex digest")
            if not meta.get("filename"):
                problems.append(f"{rel(path)}: no filename")

    ignored = {pack_toml.resolve(), index_path.resolve()}
    for path in sorted(pack_dir.rglob("*")):
        if path.is_file() and path.resolve() not in ignored and path.resolve() not in listed:
            problems.append(f"{rel(path)}: not listed in {rel(index_path)}")

    print(f"{rel(pack_toml)}: {len(listed)} indexed files, {len(problems)} problems")
    return problems


def main() -> int:
    packs = [pathlib.Path(arg).resolve() for arg in sys.argv[1:]] or sorted(
        ROOT.glob("environments/*/pack/pack.toml")
    )
    if not packs:
        print("check-packwiz: no pack.toml found", file=sys.stderr)
        return 1
    problems: list[str] = []
    for pack_toml in packs:
        problems.extend(check_pack(pack_toml))
    for problem in problems:
        print(f"PROBLEM: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
