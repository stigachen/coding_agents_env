"""Render the Grok status line from mock stdin. No Grok process and no network."""

import json
from pathlib import Path
import re
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "grok" / "statusline" / "statusline.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


class StatuslineTest(unittest.TestCase):
    def render(self, payload, *, raw="{}"):
        if payload is not None:
            raw = json.dumps(payload)
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            input=raw, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def visible(self, output):
        return ANSI.sub("", output).splitlines()

    def test_full_row_uses_payload_fields(self):
        output = self.render({
            "model": {"display_name": "Grok 4.7"},
            "effort": {"level": "high"},
            "workspace": {
                "current_dir": "/tmp/coding_agents_env",
                "branch": "main",
                "git_worktree": "linked",
            },
            "worktree": {"name": "ignored-when-workspace-name-exists"},
            "context_window": {"used_percentage": 42, "auto_compact_threshold_percent": 80},
            "cost": {"total_cost_usd": 1.234},
        })
        self.assertEqual(self.visible(output), [
            "Grok 4.7 (effort:high) | coding_agents_env | git:main@linked",
            "ctx " + ("█" * 4) + ("░" * 6) + " 42% | $1.23",
        ])
        self.assertIn("\x1b[2m", output)
        self.assertIn("\x1b[0;32m", output)
        self.assertNotIn("\x1b[0;31m", output)
        self.assertNotIn("\x1b[0;33m", output)

    def test_zero_percent_is_shown_and_missing_percent_is_not(self):
        zero = self.render({"context_window": {"used_percentage": 0}})
        self.assertEqual(self.visible(zero), ["ctx " + ("░" * 10) + " 0%"])
        self.assertIn("\x1b[0;32m", zero)
        self.assertEqual(self.render({"context_window": {}}), "")
        self.assertEqual(self.render({}), "")

    def test_context_color_follows_threshold(self):
        yellow = self.render({"context_window": {"used_percentage": 70}})
        self.assertIn("\x1b[0;33m", yellow)
        self.assertIn(" 70%", self.visible(yellow)[0])
        red_default = self.render({"context_window": {"used_percentage": 80}})
        self.assertIn("\x1b[0;31m", red_default)
        red_early = self.render({
            "context_window": {"used_percentage": 70, "auto_compact_threshold_percent": 65},
        })
        self.assertIn("\x1b[0;31m", red_early)
        self.assertNotIn("\x1b[0;33m", red_early)

    def test_small_or_missing_cost_is_omitted(self):
        self.assertEqual(self.render({"cost": {"total_cost_usd": 0.004}}), "")
        self.assertEqual(self.render({"cost": {"total_cost_usd": 0}}), "")
        self.assertEqual(self.render({"cost": {}}), "")
        shown = self.visible(self.render({"cost": {"total_cost_usd": 1.2}}))
        self.assertEqual(shown, ["$1.20"])

    def test_partial_fields_and_fallbacks(self):
        self.assertEqual(
            self.visible(self.render({"model": {"display_name": "Grok 4.7"}})),
            ["Grok 4.7"],
        )
        self.assertEqual(
            self.visible(self.render({
                "cwd": "/tmp/from-cwd",
                "workspace": {"current_dir": ""},
                "worktree": {"name": "only-wt"},
            })),
            ["from-cwd | wt:only-wt"],
        )
        self.assertEqual(
            self.visible(self.render({"workspace": {"branch": "main"}})),
            ["git:main"],
        )

    def test_invalid_json_prints_nothing(self):
        self.assertEqual(self.render(None, raw="{"), "")

    def test_windows_backslash_directory_uses_basename(self):
        output = self.render({
            "workspace": {"current_dir": "C:\\Users\\Person\\Project Folder"},
        })
        self.assertEqual(self.visible(output), ["Project Folder"])


if __name__ == "__main__":
    unittest.main()
