#!/usr/bin/env python3
"""Regression fixtures for deployment-target inspection; no macOS tools required."""
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest

import check_macos_compatibility as checker


def thin(cpu=0x0100000C, minimum=(12, 0, 0), endian="<", modern=True, platform=1):
    packed = minimum[0] << 16 | minimum[1] << 8 | minimum[2]
    command = struct.pack(endian + "6I", 0x32, 24, platform, packed, packed, 0) if modern else struct.pack(endian + "4I", 0x24, 16, packed, packed)
    return struct.pack(endian + "8I", 0xFEEDFACF, cpu, 0, 2, 1, len(command), 0, 0) + command


def fat(endian=">", wide=False):
    images = [thin(), thin(cpu=0x01000007, modern=False)]
    result = bytearray(struct.pack(endian + "II", 0xCAFEBABF if wide else 0xCAFEBABE, 2))
    for index, image in enumerate(images):
        cpu = [0x0100000C, 0x01000007][index]
        offset = (index + 1) * 4096
        result += struct.pack(endian + ("IIQQII" if wide else "5I"), *([cpu, 0, offset, len(image), 12, 0] if wide else [cpu, 0, offset, len(image), 12]))
    for index, image in enumerate(images):
        offset = (index + 1) * 4096
        result += bytes(offset - len(result)) + image
    return result


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "image"

    def inspect(self, image):
        self.path.write_bytes(image)
        return checker.inspect(self.path)

    def test_thin_modern_legacy_and_endianness(self):
        for endian in ["<", ">"]:
            for modern in [False, True]:
                with self.subTest(endian=endian, modern=modern):
                    self.assertEqual(self.inspect(thin(endian=endian, modern=modern)), [checker.Slice("arm64", (12, 0, 0))])

    def test_thin32_headers(self):
        for endian in ["<", ">"]:
            command = struct.pack(endian + "4I", 0x24, 16, 0x000C0000, 0x000C0000)
            image = struct.pack(endian + "7I", 0xFEEDFACE, 7, 0, 2, 1, len(command), 0) + command
            self.assertEqual(self.inspect(image), [checker.Slice("i386", (12, 0, 0))])

    def test_fat32_and_fat64_both_endiannesses(self):
        for endian in ["<", ">"]:
            for wide in [False, True]:
                with self.subTest(endian=endian, wide=wide):
                    self.assertEqual({item.architecture for item in self.inspect(fat(endian, wide))}, {"arm64", "x86_64"})

    def test_reject_truncated_commands_and_wrong_platform(self):
        for image in [thin()[:-1], thin(platform=2), fat()[:-1], thin()[:16]]:
            with self.subTest(length=len(image)):
                with self.assertRaises(checker.InvalidMachO):
                    self.inspect(image)

    def test_reject_bad_fat_offsets(self):
        image = bytearray(fat())
        struct.pack_into(">I", image, 16, 0)  # first arch's offset overlaps header
        with self.assertRaises(checker.InvalidMachO):
            self.inspect(image)

    def test_versions_and_required_architectures(self):
        self.path.write_bytes(thin(minimum=(13, 0, 0)))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(checker.main([str(self.path)]), 1)
        self.assertIn("requires macOS 13.0.0", errors.getvalue())
        self.assertIn("missing architectures x86_64", errors.getvalue())
        self.path.write_bytes(thin())
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(checker.main(["--arch", "arm64", str(self.path)]), 0)

    def test_ignore_data_and_reject_empty_directory(self):
        self.assertIsNone(self.inspect(b"ordinary resource data"))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(checker.main([self.temp.name]), 1)

    def test_streams_headers_of_sparse_binary(self):
        self.path.write_bytes(thin())
        with self.path.open("r+b") as stream:
            stream.truncate(512 * 1024 * 1024)
        self.assertEqual(checker.inspect(self.path)[0].minimum, (12, 0, 0))


if __name__ == "__main__":
    unittest.main()
