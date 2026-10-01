"""Exercise the real hook and notification core with isolated dry-run settings."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / "hooks" / "notify.sh"
SEND = HOOK.parents[2] / "lib" / "send.sh"


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

    def run_script(self, script, data, *args):
        result = subprocess.run(
            ["/bin/bash", str(script), *args], input=data,
            text=True, capture_output=True, env=self.env, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def run_hook(self, transcript="", **overrides):
        self.transcript.write_text(transcript)
        event = {
            "hook_event_name": "PermissionRequest", "cwd": "/tmp/project",
            "tool_name": "Bash", "turn_id": "current",
            "transcript_path": str(self.transcript),
        }
        event.update(overrides)
        return self.run_script(HOOK, json.dumps(event))

    def assert_permission_request(self, output):
        header, message = output.splitlines()
        self.assertIn("kind=permission_request", header.split())
        self.assertEqual(
            message,
            "🔔 [project] Codex 发起了操作审批请求（可能由自动审核处理）",
        )
        self.assertNotIn("在等你批准", output)

    def test_transcript_reviewer_does_not_determine_notification(self):
        for reviewer in ("auto_review", "user"):
            for tool in ("Bash", "apply_patch"):
                with self.subTest(reviewer=reviewer, tool=tool):
                    self.assert_permission_request(self.run_hook(
                        context("current", reviewer), tool_name=tool))

    def test_same_turn_switch_to_user_with_stale_transcript_keeps_notification(self):
        # turn/settings/update can switch the live reviewer to user without
        # updating turn_context. The hook input is identical to auto-review,
        # so the initial transcript value cannot justify suppressing this alert.
        initial_context = context("current", "auto_review")
        before_live_switch = self.run_hook(initial_context)
        # Only the in-memory reviewer changes; no fresh context is persisted.
        after_live_switch = self.run_hook(initial_context)
        self.assert_permission_request(after_live_switch)
        self.assertEqual(after_live_switch, before_live_switch)

    def test_mcp_and_unknown_tools_keep_notifications(self):
        for tool in ("mcp__example__write", "mcp__codex_apps__example", "new_tool", "", None):
            with self.subTest(tool=tool):
                self.assert_permission_request(self.run_hook(
                    context("current", "auto_review"), tool_name=tool))

    def test_missing_or_unknown_metadata_keeps_notifications(self):
        for data in ("", "not json\n", context("current", None),
                     context("current", "future_mode"),
                     '{"type":"turn_context","payload":{}}\n'):
            with self.subTest(data=data):
                self.assert_permission_request(self.run_hook(data))
        for override in ({"turn_id": None}, {"transcript_path": None},
                         {"transcript_path": str(self.root / "missing")},
                         {"transcript_path": str(self.root)}):
            with self.subTest(override=override):
                self.assert_permission_request(self.run_hook(
                    context("current", "auto_review"), **override))

    def test_minimal_permission_request_needs_no_reviewer_or_tool_metadata(self):
        self.assert_permission_request(self.run_script(HOOK, json.dumps({
            "hook_event_name": "PermissionRequest", "cwd": "/tmp/project",
        })))

    def test_permission_mode_cannot_identify_reviewer(self):
        for mode in ("default", "bypassPermissions", "future_mode", None):
            with self.subTest(mode=mode):
                self.assert_permission_request(self.run_hook(permission_mode=mode))

    def test_stop_notification_is_unchanged(self):
        output = self.run_hook(context("current", "auto_review"),
                               hook_event_name="Stop", last_assistant_message="completed")
        header, message, body = output.splitlines()
        self.assertIn("kind=stop", header.split())
        self.assertEqual(message, "✅ [project] Codex 任务完成")
        self.assertEqual(body, "completed")

    def test_existing_global_and_scoped_permission_switches_still_apply(self):
        for key in ("NOTIFY_ON_PERMISSION", "CODEX_NOTIFY_ON_PERMISSION"):
            for reviewer in ("auto_review", "user"):
                with self.subTest(key=key, reviewer=reviewer):
                    (self.root / "notify.env").write_text(f"{key}=0\n")
                    self.assertEqual(self.run_hook(context("current", reviewer)), "")

    def test_codex_permission_switch_overrides_global_switch(self):
        (self.root / "notify.env").write_text(
            "NOTIFY_ON_PERMISSION=0\nCODEX_NOTIFY_ON_PERMISSION=1\n")
        self.assert_permission_request(self.run_hook())

    def test_manual_permission_wording_is_unchanged_for_claude(self):
        output = self.run_script(SEND, "", "permission", "project", "Claude")
        header, message = output.splitlines()
        self.assertIn("kind=permission", header.split())
        self.assertEqual(message, "🔔 [project] Claude 在等你批准一个操作")


if __name__ == "__main__":
    unittest.main()
