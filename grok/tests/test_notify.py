"""Exercise Grok and the shared notification core without real user settings or pushes."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HOOK = REPO / "grok" / "hooks" / "notify.sh"
CLAUDE_HOOK = REPO / "claude" / "hooks" / "notify.sh"


class NotifyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        config = self.root / "config"
        config.mkdir()
        self.config = config / "notify.env"
        self.config.write_text("NOTIFY_DEBUG=0\n")
        self.env = {
            "HOME": str(self.home),
            "PATH": os.environ["PATH"],
            "CODING_AGENTS_ENV_DIR": str(config),
            "NOTIFY_DRY_RUN": "1",
            "NOTIFY_SKIP_WHEN_FOCUSED": "0",
            "NOTIFY_SHOW_HOST": "0",
        }

    def run_hook(self, *, hook=HOOK, omit=(), env=None, **overrides):
        payload = {
            "hook_event_name": "Stop",
            "reason": "end_turn",
            "cwd": "/tmp/project with spaces",
            "lastAssistantMessage": "完成测试",
        }
        payload.update(overrides)
        for key in omit:
            payload.pop(key, None)
        result = subprocess.run(
            ["/bin/bash", str(hook)], input=json.dumps(payload), text=True,
            capture_output=True, env={**self.env, **(env or {})}, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_native_stop_works_by_default_without_claude_installed(self):
        output = self.run_hook()
        self.assertIn("agent=Grok kind=stop ", output)
        self.assertIn("[project with spaces] Grok", output)
        self.assertIn("完成测试", output)
        self.assertFalse((self.home / ".claude").exists())

    def test_only_end_turn_stop_is_notified(self):
        for reason in (None, "", "shutdown", "channel_closed", "session_end"):
            with self.subTest(reason=reason):
                self.assertEqual(self.run_hook(reason=reason), "")
        self.assertEqual(self.run_hook(omit=("reason",)), "")

    def test_subagent_stops_are_silent(self):
        for metadata in ({"subagentType": "explore"}, {"subagent_type": "explore"},
                         {"hook_event_name": "SubagentStop"}):
            with self.subTest(metadata=metadata):
                self.assertEqual(self.run_hook(**metadata), "")

    def test_subagent_human_approval_is_preserved_but_idle_is_silent(self):
        for field in ("subagentType", "subagent_type"):
            with self.subTest(field=field):
                output = self.run_hook(hook_event_name="Notification",
                                       notificationType="permission_prompt", **{field: "explore"})
                self.assertIn("agent=Grok kind=permission ", output)
                self.assertEqual(self.run_hook(hook_event_name="Notification",
                                               notificationType="idle_prompt", **{field: "explore"}), "")

    def test_notification_types_map_to_permission_and_idle(self):
        for field in ("notificationType", "notification_type"):
            for notification_type, kind in (("permission_prompt", "permission"),
                                             ("idle_prompt", "idle")):
                with self.subTest(field=field, notification_type=notification_type):
                    output = self.run_hook(hook_event_name="Notification",
                                           **{field: notification_type})
                    self.assertIn("agent=Grok kind=" + kind + " ", output)

    def test_actual_permission_prompt_is_preserved_in_auto_mode(self):
        output = self.run_hook(hook_event_name="Notification",
                               notificationType="permission_prompt", permissionMode="auto")
        self.assertIn("agent=Grok kind=permission ", output)

    def test_task_complete_does_not_duplicate_stop(self):
        for field in ("notificationType", "notification_type"):
            with self.subTest(field=field):
                self.assertEqual(self.run_hook(hook_event_name="Notification",
                                               **{field: "task_complete"}), "")

    def test_unknown_notification_types_are_silent(self):
        for notification_type in (None, "", "future_type"):
            with self.subTest(notification_type=notification_type):
                self.assertEqual(self.run_hook(hook_event_name="Notification",
                                               notificationType=notification_type), "")

    def test_windows_workspace_path_uses_project_name(self):
        output = self.run_hook(cwd=r"C:\Users\Person\Project Folder")
        self.assertIn("[Project Folder] Grok", output)

    def test_snake_case_assistant_message_is_supported(self):
        output = self.run_hook(omit=("lastAssistantMessage",),
                               last_assistant_message="snake case summary")
        self.assertIn("agent=Grok kind=stop ", output)
        self.assertIn("snake case summary", output)

    def test_native_camel_case_fields_take_precedence_over_compat_aliases(self):
        output = self.run_hook(last_assistant_message="stale summary")
        self.assertIn("完成测试", output)
        self.assertNotIn("stale summary", output)
        output = self.run_hook(hook_event_name="Notification",
                               notificationType="permission_prompt",
                               notification_type="task_complete")
        self.assertIn("agent=Grok kind=permission ", output)

    def test_event_field_precedence(self):
        output = self.run_hook(hookEventName="notification",
                               notificationType="permission_prompt",
                               env={"GROK_HOOK_EVENT": "notification"})
        self.assertIn("agent=Grok kind=stop ", output)
        output = self.run_hook(omit=("hook_event_name",), hookEventName="notification",
                               notificationType="permission_prompt",
                               env={"GROK_HOOK_EVENT": "stop"})
        self.assertIn("agent=Grok kind=permission ", output)

    def test_camel_case_event_and_runner_environment_fallbacks(self):
        for event, kind in (("stop", "stop"), ("notification", "permission")):
            for source in ("payload", "environment"):
                with self.subTest(event=event, source=source):
                    override = {"hookEventName": event} if source == "payload" else {}
                    environment = {"GROK_HOOK_EVENT": event} if source == "environment" else {}
                    output = self.run_hook(omit=("hook_event_name",), env=environment,
                                           notificationType="permission_prompt", **override)
                    self.assertIn("agent=Grok kind=" + kind + " ", output)

    def test_new_total_switch_wins_over_legacy_switches(self):
        for new, old in (("0", "1"), ("1", "0")):
            with self.subTest(new=new, old=old):
                self.config.write_text(
                    "GROK_NOTIFY_ENABLED=" + new + "\n"
                    "GROK_NOTIFY_FROM_GROK=" + old + "\nNOTIFY_FROM_GROK=" + old + "\n")
                for event in ("Stop", "Notification"):
                    with self.subTest(event=event):
                        output = self.run_hook(hook_event_name=event,
                                               notificationType="permission_prompt")
                        if new == "1":
                            self.assertIn("agent=Grok kind=", output)
                        else:
                            self.assertEqual(output, "")

    def test_legacy_switches_remain_fallbacks_with_agent_precedence(self):
        for settings, enabled in (
                ("NOTIFY_FROM_GROK=0\n", False),
                ("NOTIFY_FROM_GROK=1\n", True),
                ("GROK_NOTIFY_FROM_GROK=0\nNOTIFY_FROM_GROK=1\n", False),
                ("GROK_NOTIFY_FROM_GROK=1\nNOTIFY_FROM_GROK=0\n", True)):
            with self.subTest(settings=settings):
                self.config.write_text(settings)
                output = self.run_hook()
                if enabled:
                    self.assertIn("agent=Grok kind=stop ", output)
                else:
                    self.assertEqual(output, "")

    def test_new_total_switch_environment_overrides_file(self):
        for file_value, env_value in (("0", "1"), ("1", "0")):
            with self.subTest(file_value=file_value, env_value=env_value):
                self.config.write_text("GROK_NOTIFY_ENABLED=" + file_value + "\n")
                output = self.run_hook(env={"GROK_NOTIFY_ENABLED": env_value})
                if env_value == "1":
                    self.assertIn("agent=Grok kind=stop ", output)
                else:
                    self.assertEqual(output, "")

    def test_event_switches_still_apply_to_grok(self):
        for event, notification_type, key in (
                ("Stop", "", "NOTIFY_ON_STOP"),
                ("Notification", "permission_prompt", "NOTIFY_ON_PERMISSION"),
                ("Notification", "idle_prompt", "NOTIFY_ON_IDLE")):
            for prefix in ("", "GROK_"):
                with self.subTest(event=event, key=prefix + key):
                    self.config.write_text("GROK_NOTIFY_ENABLED=1\n" + prefix + key + "=0\n")
                    self.assertEqual(self.run_hook(hook_event_name=event,
                                                   notificationType=notification_type), "")

    def test_claude_compatibility_hook_is_silent_for_grok(self):
        self.config.write_text("GROK_NOTIFY_ENABLED=1\nNOTIFY_FROM_GROK=1\n")
        for event, runner_event in (("Stop", "stop"), ("Notification", "notification")):
            with self.subTest(event=event):
                self.assertEqual(self.run_hook(
                    hook=CLAUDE_HOOK, hook_event_name=event,
                    notification_type="permission_prompt",
                    env={"GROK_HOOK_EVENT": runner_event}), "")

    def test_normal_claude_notifications_are_unaffected_by_grok_switch(self):
        self.config.write_text("GROK_NOTIFY_ENABLED=0\n")
        for event, kind in (("Stop", "stop"), ("Notification", "permission")):
            for environment in ({}, {"GROK_HOOK_EVENT": ""}):
                with self.subTest(event=event, environment=environment):
                    output = self.run_hook(hook=CLAUDE_HOOK, hook_event_name=event,
                                           notification_type="permission_prompt", env=environment)
                    self.assertIn("agent=Claude kind=" + kind + " ", output)

    def test_debug_log_uses_shared_config_directory_without_claude(self):
        # No channels are configured, and all delivery routes are explicitly off.
        # Disable dry-run only to reach logging; this cannot send a notification.
        environment = {
            **self.env, "NOTIFY_DRY_RUN": "0", "NOTIFY_DEBUG": "1",
            "TELEGRAM_BOT_TOKEN": "", "TELEGRAM_CHAT_ID": "", "DISCORD_WEBHOOK_URL": "",
            "GROK_TELEGRAM_BOT_TOKEN": "", "GROK_TELEGRAM_CHAT_ID": "",
            "GROK_DISCORD_WEBHOOK_URL": "", "GROK_DESKTOP_NOTIFY": "0",
        }
        result = subprocess.run(
            ["/bin/bash", str(REPO / "lib/send.sh"), "stop", "test-project", "Grok"],
            input="debug-test", text=True, capture_output=True, env=environment, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("agent=Grok kind=stop", (self.config.parent / "notify-debug.log").read_text())
        self.assertFalse((self.home / ".claude").exists())


if __name__ == "__main__":
    unittest.main()
