#!/usr/bin/env python3
"""Regression tests for the standalone .tekesplugin packager."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("package-plugin.py")


class PackagePluginTests(unittest.TestCase):
    def test_archive_is_deterministic_and_preserves_executable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Plugin"
            archive = root / "plugin.tekesplugin"
            (source / "bin").mkdir(parents=True)
            (source / "tekes-plugin.json").write_text("{}", encoding="utf-8")
            executable = source / "bin" / "helper"
            executable.write_bytes(b"helper")
            executable.chmod(0o755)

            subprocess.run(
                [sys.executable, str(SCRIPT), str(source), str(archive)], check=True
            )
            first = archive.read_bytes()
            subprocess.run(
                [sys.executable, str(SCRIPT), str(source), str(archive)], check=True
            )
            self.assertEqual(archive.read_bytes(), first)

            payload = json.loads(first)
            self.assertEqual(payload["archiveVersion"], 1)
            entries = {entry["path"]: entry for entry in payload["entries"]}
            self.assertEqual(entries["bin"]["kind"], "directory")
            self.assertTrue(entries["bin/helper"]["executable"])
            self.assertEqual(
                base64.b64decode(entries["bin/helper"]["data"]), b"helper"
            )

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Plugin"
            source.mkdir()
            (source / "target").write_text("target", encoding="utf-8")
            os.symlink(source / "target", source / "alias")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(source),
                    str(root / "plugin.tekesplugin"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
