"""OpenCode notify.ts approval routing. Never starts OpenCode or sends a message."""

import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
HARNESS = REPO / "opencode" / "tests" / "harness.mjs"
SCENARIOS = (
    "event_only",
    "hook_only",
    "hook_then_event",
    "event_then_hook",
    "distinct_ids",
    "no_id_collapses",
    "idle_and_ignore_reply",
    "v2_permission",
    "v2_skips_subagent",
    "v2_still_stops",
    "incomplete_setup_stays_v1",
)


class NotifyTest(unittest.TestCase):
    def test_permission_routing(self):
        node = "node"
        for name in SCENARIOS:
            with self.subTest(scenario=name):
                result = subprocess.run(
                    [
                        node,
                        "--experimental-test-module-mocks",
                        "--experimental-strip-types",
                        str(HARNESS),
                        name,
                    ],
                    text=True,
                    capture_output=True,
                    timeout=20,
                    cwd=str(REPO),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(name + " ok", result.stdout)
