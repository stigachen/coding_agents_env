"""Render the Claude status line from mock stdin. No Claude process and no network."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests"))
from support import bash_exe  # noqa: E402


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "claude" / "statusline" / "statusline.sh"


class StatuslineTest(unittest.TestCase):
    def test_windows_backslash_directory_uses_basename(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        env = {
            "HOME": str(root),
            "PATH": os.environ["PATH"],
            "CODING_AGENTS_ENV_DIR": str(root),
            "CLAUDE_CONFIG_DIR": str(root),
            "TMPDIR": str(root),
        }
        payload = {
            "model": {"display_name": "Test"},
            "effort": {"level": "high"},
            "workspace": {"current_dir": "C:\\Users\\Person\\Project Folder"},
        }
        result = subprocess.run(
            [bash_exe(), str(SCRIPT)],
            input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(" | Project Folder", result.stdout)
        self.assertNotIn("Users", result.stdout)
        self.assertNotIn("\\", result.stdout)


if __name__ == "__main__":
    unittest.main()
