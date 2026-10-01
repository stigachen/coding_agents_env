"""Exercise the real hook and notification core with isolated dry-run settings."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / "hooks" / "notify.sh"


def context(turn, reviewer):
    return json.dumps({"type": "turn_context", "payload": {
        "turn_id": turn, "approvals_reviewer": reviewer,
    }}) + "\n"


class NotifyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.transcript = self.root / "session with spaces.jsonl"
        (self.root / "notify.env").write_text("NOTIFY_DEBUG=0\n")
        self.env = {
            "PATH": os.environ["PATH"],
            "CLAUDE_CONFIG_DIR": str(self.root),
            "CODING_AGENTS_ENV_DIR": str(self.root),
            "NOTIFY_DRY_RUN": "1",
            "NOTIFY_SKIP_WHEN_FOCUSED": "0",
            "NOTIFY_SHOW_HOST": "0",
        }

    def run_hook(self, transcript, **overrides):
        self.transcript.write_text(transcript)
        event = {
            "hook_event_name": "PermissionRequest", "cwd": "/tmp/project",
            "tool_name": "Bash", "turn_id": "current",
            "transcript_path": str(self.transcript),
        }
        event.update(overrides)
        result = subprocess.run(
            ["/bin/bash", str(HOOK)], input=json.dumps(event),
            text=True, capture_output=True, env=self.env, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_auto_review_shell_and_patch_are_silent(self):
        for tool in ("Bash", "apply_patch"):
            with self.subTest(tool=tool):
                self.assertEqual(self.run_hook(context("current", "auto_review"),
                                               tool_name=tool), "")

    def test_human_approval_is_preserved(self):
        self.assertIn("kind=permission", self.run_hook(context("current", "user")))

    def test_previous_turn_cannot_suppress_current(self):
        self.assertIn("kind=permission", self.run_hook(context("old", "auto_review")))
        self.assertIn("kind=permission", self.run_hook(
            context("old", "auto_review") + context("current", "user")))

    def test_last_context_for_same_turn_wins(self):
        self.assertIn("kind=permission", self.run_hook(
            context("current", "auto_review") + context("current", "user")))
        self.assertEqual(self.run_hook(
            context("current", "user") + context("current", "auto_review")), "")

    def test_mcp_and_unknown_tools_keep_notifications(self):
        for tool in ("mcp__example__write", "mcp__codex_apps__example", "new_tool", ""):
            with self.subTest(tool=tool):
                self.assertIn("kind=permission", self.run_hook(
                    context("current", "auto_review"), tool_name=tool))

    def test_missing_or_unknown_metadata_keeps_notifications(self):
        for data in ("", "not json\n", context("current", None),
                     context("current", "future_mode"),
                     '{"type":"turn_context","payload":{}}\n'):
            with self.subTest(data=data):
                self.assertIn("kind=permission", self.run_hook(data))
        for override in ({"turn_id": None}, {"transcript_path": None},
                         {"transcript_path": str(self.root / "missing")},
                         {"transcript_path": str(self.root)}):
            with self.subTest(override=override):
                self.assertIn("kind=permission", self.run_hook(
                    context("current", "auto_review"), **override))

    def test_bad_and_partial_lines_do_not_hide_valid_context(self):
        data = 'broken\nnull\n[]\n42\n' + context("current", "auto_review") + '{"partial":'
        self.assertEqual(self.run_hook(data), "")

    def test_bounded_read(self):
        padding = json.dumps({"type": "response_item", "data": "x" * 2100000}) + "\n"
        self.assertEqual(self.run_hook(padding + context("current", "auto_review")), "")
        self.assertIn("kind=permission", self.run_hook(context("current", "auto_review") + padding))

    def test_stop_notification_is_unchanged(self):
        output = self.run_hook(context("current", "auto_review"),
                               hook_event_name="Stop", last_assistant_message="completed")
        self.assertIn("kind=stop", output)
        self.assertIn("completed", output)

    def test_existing_switch_still_controls_human_notifications(self):
        (self.root / "notify.env").write_text("CODEX_NOTIFY_ON_PERMISSION=0\n")
        self.assertEqual(self.run_hook(context("current", "user")), "")


if __name__ == "__main__":
    unittest.main()
