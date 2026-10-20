"""Exercise Grok and the shared notification core without real user settings or pushes."""

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
            [bash_exe(), str(hook)], input=json.dumps(payload), text=True,
            capture_output=True, env={**self.env, **(env or {})}, timeout=20,
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
        self.assertNotIn("Person", output)

    def test_claude_windows_workspace_path_uses_project_name(self):
        output = self.run_hook(hook=CLAUDE_HOOK, cwd=r"C:\Users\Person\Project Folder")
        self.assertIn("[Project Folder] Claude", output)
        self.assertNotIn("Person", output)

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

    def test_obsolete_grok_gates_in_config_are_ignored(self):
        for key in ("GROK_NOTIFY_ENABLED", "GROK_NOTIFY_FROM_GROK", "NOTIFY_FROM_GROK"):
            for value in ("0", "1", ""):
                with self.subTest(key=key, value=value):
                    self.config.write_text(key + "=" + value + "\n")
                    self.assertIn("agent=Grok kind=stop ", self.run_hook())

    def test_obsolete_grok_gates_in_environment_are_ignored_for_all_events(self):
        for value in ("0", "1", ""):
            environment = {key: value for key in (
                "GROK_NOTIFY_ENABLED", "GROK_NOTIFY_FROM_GROK", "NOTIFY_FROM_GROK")}
            for event, notification_type, kind in (
                    ("Stop", "", "stop"),
                    ("Notification", "permission_prompt", "permission"),
                    ("Notification", "idle_prompt", "idle")):
                with self.subTest(value=value, event=event, kind=kind):
                    output = self.run_hook(hook_event_name=event, env=environment,
                                           notificationType=notification_type)
                    self.assertIn("agent=Grok kind=" + kind + " ", output)

    def test_standard_event_switches_inherit_and_allow_grok_overrides(self):
        for event, notification_type, key, kind in (
                ("Stop", "", "NOTIFY_ON_STOP", "stop"),
                ("Notification", "permission_prompt", "NOTIFY_ON_PERMISSION", "permission"),
                ("Notification", "idle_prompt", "NOTIFY_ON_IDLE", "idle")):
            for generic, scoped, enabled in (("0", None, False), ("1", None, True),
                                             ("0", "1", True), ("1", "0", False)):
                with self.subTest(key=key, generic=generic, scoped=scoped):
                    settings = key + "=" + generic + "\n"
                    if scoped is not None:
                        settings += "GROK_" + key + "=" + scoped + "\n"
                    self.config.write_text(settings)
                    output = self.run_hook(hook_event_name=event, notificationType=notification_type)
                    if enabled:
                        self.assertIn("agent=Grok kind=" + kind + " ", output)
                    else:
                        self.assertEqual(output, "")

    def test_standard_event_switch_environment_overrides_same_key_in_file(self):
        for event, notification_type, key, kind in (
                ("Stop", "", "NOTIFY_ON_STOP", "stop"),
                ("Notification", "permission_prompt", "NOTIFY_ON_PERMISSION", "permission"),
                ("Notification", "idle_prompt", "NOTIFY_ON_IDLE", "idle")):
            for prefix in ("", "GROK_"):
                for file_value, env_value in (("0", "1"), ("1", "0")):
                    with self.subTest(key=prefix + key, file_value=file_value, env_value=env_value):
                        self.config.write_text(prefix + key + "=" + file_value + "\n")
                        output = self.run_hook(hook_event_name=event, notificationType=notification_type,
                                               env={prefix + key: env_value})
                        if env_value == "1":
                            self.assertIn("agent=Grok kind=" + kind + " ", output)
                        else:
                            self.assertEqual(output, "")

    def test_claude_compatibility_ignores_grok_with_or_without_native_hooks(self):
        self.config.write_text("GROK_NOTIFY_ENABLED=1\nNOTIFY_FROM_GROK=1\n")
        native_hooks = self.home / ".grok/hooks/coding_agents_env.json"
        for installed in (False, True):
            if installed:
                native_hooks.parent.mkdir(parents=True)
                native_hooks.write_text(json.dumps({"hooks": {
                    event: [{"hooks": [{"type": "command", "command": 'bash "' + str(HOOK) + '"'}]}]
                    for event in ("Stop", "Notification")
                }}))
            for event, runner_event in (("Stop", "stop"), ("Notification", "notification")):
                with self.subTest(installed=installed, event=event):
                    self.assertEqual(self.run_hook(
                        hook=CLAUDE_HOOK, hook_event_name=event,
                        notification_type="permission_prompt",
                        env={"GROK_HOOK_EVENT": runner_event}), "")

    def test_normal_claude_notifications_are_unaffected_by_grok_settings(self):
        self.config.write_text("GROK_NOTIFY_ON_STOP=0\nGROK_NOTIFY_ON_PERMISSION=0\n")
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
            [bash_exe(), str(REPO / "lib/send.sh"), "stop", "test-project", "Grok"],
            input="debug-test", text=True, capture_output=True, env=environment, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("agent=Grok kind=stop", (self.config.parent / "notify-debug.log").read_text())
        self.assertFalse((self.home / ".claude").exists())


if __name__ == "__main__":
    unittest.main()
