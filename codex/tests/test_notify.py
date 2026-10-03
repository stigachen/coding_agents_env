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

    def run_hook(self, transcript, *, omit=(), **overrides):
        self.transcript.write_text(transcript)
        event = {
            "hook_event_name": "PermissionRequest", "cwd": "/tmp/project",
            "tool_name": "Bash", "turn_id": "current",
            "transcript_path": str(self.transcript),
        }
        event.update(overrides)
        for key in omit:
            event.pop(key, None)
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

    def test_explicit_null_transcript_stop_is_silent_by_default(self):
        for body in ("completed", '{"suggestions":[]}'):
            with self.subTest(body=body):
                self.assertEqual(self.run_hook(
                    "", hook_event_name="Stop", transcript_path=None,
                    last_assistant_message=body), "")

    def test_transcriptless_stop_can_be_enabled_in_config(self):
        (self.root / "notify.env").write_text("CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT=1\n")
        output = self.run_hook(
            "", hook_event_name="Stop", transcript_path=None,
            last_assistant_message="completed")
        self.assertIn("agent=Codex kind=stop_without_transcript ", output)
        self.assertIn("completed", output)

    def test_transcriptless_stop_still_obeys_stop_switches(self):
        for settings, enabled in (
                ("NOTIFY_ON_STOP=0\n", False),
                ("CODEX_NOTIFY_ON_STOP=0\n", False),
                ("NOTIFY_ON_STOP=1\nCODEX_NOTIFY_ON_STOP=0\n", False),
                ("NOTIFY_ON_STOP=0\nCODEX_NOTIFY_ON_STOP=1\n", True)):
            with self.subTest(settings=settings):
                (self.root / "notify.env").write_text(
                    "CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT=1\n" + settings)
                output = self.run_hook("", hook_event_name="Stop", transcript_path=None)
                if enabled:
                    self.assertIn("kind=stop_without_transcript ", output)
                else:
                    self.assertEqual(output, "")

    def test_transcriptless_stop_environment_overrides_config(self):
        for file_value, env_value in (("0", "1"), ("1", "0")):
            with self.subTest(file_value=file_value, env_value=env_value):
                (self.root / "notify.env").write_text(
                    "CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT=" + file_value + "\n")
                self.env["CODEX_NOTIFY_ON_STOP_WITHOUT_TRANSCRIPT"] = env_value
                output = self.run_hook("", hook_event_name="Stop", transcript_path=None)
                if env_value == "1":
                    self.assertIn("kind=stop_without_transcript ", output)
                else:
                    self.assertEqual(output, "")

    def test_ordinary_stop_does_not_filter_message_content(self):
        body = '{"suggestions":[]}'
        output = self.run_hook(
            "", hook_event_name="Stop", last_assistant_message=body)
        self.assertIn("agent=Codex kind=stop ", output)
        self.assertIn(body, output)

    def test_missing_transcript_field_keeps_stop_notification(self):
        output = self.run_hook("", hook_event_name="Stop", omit=("transcript_path",))
        self.assertIn("agent=Codex kind=stop ", output)

    def test_empty_unavailable_and_invalid_transcript_values_keep_stop_notifications(self):
        for value in ("", " ", "null", str(self.root / "missing"), str(self.root),
                      False, True, 0, 42, [], {}, [str(self.transcript)]):
            with self.subTest(value=value):
                output = self.run_hook("", hook_event_name="Stop", transcript_path=value)
                self.assertIn("agent=Codex kind=stop ", output)

    def test_human_permission_with_null_transcript_is_preserved(self):
        output = self.run_hook(context("current", "user"), transcript_path=None)
        self.assertIn("agent=Codex kind=permission ", output)

    def test_existing_switch_still_controls_human_notifications(self):
        (self.root / "notify.env").write_text("CODEX_NOTIFY_ON_PERMISSION=0\n")
        self.assertEqual(self.run_hook(context("current", "user")), "")


if __name__ == "__main__":
    unittest.main()
