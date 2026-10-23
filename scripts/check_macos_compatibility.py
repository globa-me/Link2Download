#!/usr/bin/env python3
"""Check Mach-O deployment targets and architectures without loading binary bodies.

Examples:
  python3 scripts/check_macos_compatibility.py build/Link2Download.app
  python3 scripts/check_macos_compatibility.py Resources/bin build/link2download
  python3 scripts/check_macos_compatibility.py --arch arm64 /path/to/app

Directories are scanned recursively, including bundled dylibs and Python extensions.
Universal architectures are required for every Mach-O file, not just the launcher.
This checks declared minimum OS versions, not runtime behavior or API availability.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import struct
import sys
from typing import BinaryIO, NamedTuple

THIN = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xcf\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xce": (">", 28), b"\xfe\xed\xfa\xcf": (">", 32)}
FAT = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
       b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}
ARCHITECTURES = {0x01000007: "x86_64", 0x0100000C: "arm64", 7: "i386", 12: "arm"}


class InvalidMachO(ValueError):
    pass


class Slice(NamedTuple):
    architecture: str
    minimum: tuple[int, int, int]


def read_at(stream: BinaryIO, offset: int, size: int, end: int) -> bytes:
    if offset < 0 or size < 0 or offset + size > end:
        raise InvalidMachO("header or load command exceeds its slice")
    stream.seek(offset)
    value = stream.read(size)
    if len(value) != size:
        raise InvalidMachO("truncated Mach-O header")
    return value


def version(raw: int) -> tuple[int, int, int]:
    return raw >> 16, (raw >> 8) & 255, raw & 255


def display(value: tuple[int, int, int]) -> str:
    return ".".join(map(str, value))


def thin_slice(stream: BinaryIO, offset: int, size: int, expected_cpu: int | None = None) -> Slice:
    end = offset + size
    magic = read_at(stream, offset, 4, end)
    if magic not in THIN:
        raise InvalidMachO("fat slice is not a thin Mach-O image")
    endian, header_size = THIN[magic]
    header = read_at(stream, offset, header_size, end)
    cpu, _, _, command_count, command_bytes, _ = struct.unpack_from(endian + "6I", header, 4)
    if expected_cpu is not None and cpu != expected_cpu:
        raise InvalidMachO("fat architecture disagrees with its Mach-O slice")
    if command_count > 100_000 or command_bytes > 16 * 1024 * 1024 or command_count * 8 > command_bytes:
        raise InvalidMachO("invalid load-command count or size")
    command_end = offset + header_size + command_bytes
    if command_end > end:
        raise InvalidMachO("load commands exceed their slice")
    cursor = offset + header_size
    versions = []
    for _ in range(command_count):
        command, command_size = struct.unpack(endian + "II", read_at(stream, cursor, 8, command_end))
        if command_size < 8 or command_size % 4 or cursor + command_size > command_end:
            raise InvalidMachO("invalid load-command length")
        if command == 0x24:  # LC_VERSION_MIN_MACOSX
            if command_size < 16:
                raise InvalidMachO("truncated LC_VERSION_MIN_MACOSX")
            versions.append(version(struct.unpack(endian + "I", read_at(stream, cursor + 8, 4, command_end))[0]))
        elif command == 0x32:  # LC_BUILD_VERSION
            if command_size < 24:
                raise InvalidMachO("truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack(endian + "II", read_at(stream, cursor + 8, 8, command_end))
            if platform != 1:
                raise InvalidMachO(f"LC_BUILD_VERSION platform {platform} is not macOS")
            versions.append(version(minimum))
        cursor += command_size
    if cursor != command_end:
        raise InvalidMachO("load-command byte count does not match header")
    if not versions:
        raise InvalidMachO("no macOS minimum-version load command")
    architecture = ARCHITECTURES.get(cpu, f"cpu_0x{cpu:08x}")
    return Slice(architecture, max(versions))


def inspect(path: Path) -> list[Slice] | None:
    """Return None for ordinary data files; read only headers of Mach-O images."""
    with path.open("rb") as stream:
        file_size = os.fstat(stream.fileno()).st_size
        magic = stream.read(4)
        if magic in THIN:
            return [thin_slice(stream, 0, file_size)]
        if magic not in FAT:
            return None
        endian, entry_size = FAT[magic]
        count = struct.unpack(endian + "I", read_at(stream, 4, 4, file_size))[0]
        if not 1 <= count <= 4096:
            raise InvalidMachO("invalid fat architecture count")
        table_end = 8 + count * entry_size
        if table_end > file_size:
            raise InvalidMachO("truncated fat architecture table")
        slices = []
        extents = []
        for index in range(count):
            entry = read_at(stream, 8 + index * entry_size, entry_size, file_size)
            if entry_size == 20:
                cpu, _, offset, size, alignment = struct.unpack(endian + "5I", entry)
            else:
                cpu, _, offset, size, alignment, _ = struct.unpack(endian + "IIQQII", entry)
            if offset < table_end or size < 4 or offset + size > file_size or alignment > 63 or offset % (1 << alignment):
                raise InvalidMachO("invalid fat slice offset, size or alignment")
            if any(offset < previous_end and previous_start < offset + size for previous_start, previous_end in extents):
                raise InvalidMachO("overlapping fat slices")
            extents.append((offset, offset + size))
            slices.append(thin_slice(stream, offset, size, cpu))
        return slices


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--arch", action="append", choices=["arm64", "x86_64"], help="Required architecture; repeat to require both (default: both)")
    parser.add_argument("--max-macos", default="12.0", help="Maximum permitted deployment target (default: 12.0)")
    parser.add_argument("--verbose", action="store_true", help="Print each checked binary")
    args = parser.parse_args(argv)
    try:
        parts = [int(part) for part in args.max_macos.split(".")]
        if not 1 <= len(parts) <= 3 or any(part < 0 for part in parts):
            raise ValueError()
        maximum = tuple(parts + [0] * (3 - len(parts)))
    except ValueError:
        parser.error("--max-macos must be a version such as 12.0")
    required = set(args.arch or ["arm64", "x86_64"])
    seen = set()
    failures = []
    checked = 0
    floors: dict[str, tuple[int, int, int]] = {}
    for root in args.paths:
        if not root.exists():
            failures.append(f"{root}: path does not exist")
            continue
        if root.is_dir():
            def walk_error(error: OSError) -> None:
                failures.append(f"{error.filename}: {error.strerror}")
            candidates = (Path(base) / name for base, _, names in os.walk(root, onerror=walk_error) for name in names)
            # The app and helper must exist even if the rest of the bundle scans.
            if root.suffix == ".app":
                for name in ["Link2Download", "link2download-cli"]:
                    executable = root / "Contents" / "MacOS" / name
                    if not executable.is_file():
                        failures.append(f"{executable}: required executable is missing")
        else:
            candidates = iter([root])
        for path in candidates:
            try:
                resolved = path.resolve(strict=True)
                if resolved in seen:
                    continue
                seen.add(resolved)
                if not resolved.is_file():
                    continue
                slices = inspect(path)
                if slices is None:
                    if not root.is_dir() or (root.suffix == ".app" and path.parent == root / "Contents" / "MacOS"):
                        failures.append(f"{path}: not a Mach-O image")
                    continue
                checked += 1
                found = {part.architecture for part in slices}
                if required - found:
                    failures.append(f"{path}: missing architectures {', '.join(sorted(required - found))}")
                for part in slices:
                    floors[part.architecture] = max(floors.get(part.architecture, (0, 0, 0)), part.minimum)
                    if part.minimum > maximum:
                        failures.append(f"{path}: {part.architecture} requires macOS {display(part.minimum)} (maximum {display(maximum)})")
                if args.verbose:
                    print(f"{path}: " + ", ".join(f"{part.architecture} macOS {display(part.minimum)}" for part in slices))
            except (OSError, InvalidMachO, struct.error) as error:
                failures.append(f"{path}: {error}")
    if not checked:
        failures.append("No Mach-O images were found")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    summary = ", ".join(f"{arch} <= macOS {display(minimum)}" for arch, minimum in sorted(floors.items()))
    print(f"{'FAIL' if failures else 'PASS'}: {checked} Mach-O images; {summary or 'no architecture metadata'}; required {', '.join(sorted(required))}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
