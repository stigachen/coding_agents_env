"""Run installers against copied sources and temporary homes; never invoke an agent."""

import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class InstallTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "repository's path with spaces"
        shutil.copytree(REPO, self.repo, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Keep real coding agents out of PATH, including during automatic detection.
        for name in ("bash", "jq", "curl", "chmod", "dirname", "basename", "printenv", "mkdir", "tr", "grep",
                     "sed", "tail", "head", "mktemp", "mv", "rm", "uname", "ln", "cat",
                     "cp", "stat", "awk", "sort", "cut", "readlink", "realpath", "date"):
            executable = shutil.which(name)
            if executable:
                (self.bin / name).symlink_to(executable)
        self.env = {"HOME": str(self.home), "PATH": str(self.bin), "NOTIFY_DRY_RUN": "1"}
        self.grok_home = self.home / ".grok"
        self.hooks = self.grok_home / "hooks" / "coding_agents_env.json"
        self.config = self.home / ".config" / "coding_agents_env" / "notify.env"

    def run_install(self, *, root=False, detect=False, success=True, env=None):
        script = self.repo / ("install.sh" if root else "grok/install.sh")
        command = ["/bin/bash", str(script)]
        if root and not detect:
            command.append("grok")
        result = subprocess.run(command, env={**self.env, **(env or {})}, text=True,
                                capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_native_hooks(self, path=None):
        data = json.loads((path or self.hooks).read_text())
        for event in ("Stop", "Notification"):
            found = []
            for group in data["hooks"][event]:
                for handler in group.get("hooks", []):
                    if "/grok/hooks/notify.sh" in handler.get("command", ""):
                        found.append(handler)
                        self.assertNotIn("matcher", group)
                        command = shlex.split(handler["command"])
                        self.assertIn(command[0], ("bash", "/bin/bash"))
                        self.assertEqual(command[1:], [str(self.repo / "grok/hooks/notify.sh")])
                        self.assertEqual(handler["type"], "command")
            self.assertEqual(len(found), 1, (event, found))
        return data

    def write_config(self, contents):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(contents)

    def test_native_install_is_idempotent_and_needs_no_claude_directory(self):
        self.run_install()
        first = self.assert_native_hooks()
        self.run_install()
        self.assertEqual(self.assert_native_hooks(), first)
        self.assertFalse((self.home / ".claude").exists())

    def test_custom_grok_home_is_respected(self):
        custom = self.root / "custom grok home"
        self.run_install(env={"GROK_HOME": str(custom)})
        self.assert_native_hooks(custom / "hooks/coding_agents_env.json")
        self.assertFalse(self.grok_home.exists())

    def test_installed_command_runs_from_path_with_spaces_and_apostrophe(self):
        self.run_install()
        data = self.assert_native_hooks()
        command = data["hooks"]["Stop"][0]["hooks"][0]["command"]
        result = subprocess.run(
            ["/bin/bash", "-c", command],
            input=json.dumps({"hook_event_name": "Stop", "reason": "end_turn", "cwd": "/tmp/project"}),
            text=True, capture_output=True, timeout=5,
            env={**self.env, "NOTIFY_SKIP_WHEN_FOCUSED": "0", "NOTIFY_SHOW_HOST": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("agent=Grok kind=stop ", result.stdout)

    def test_windows_hook_command_quotes_apostrophe_for_powershell(self):
        # Simulate Windows path generation only; do not execute PowerShell.
        uname = self.bin / "uname"
        uname.unlink()  # Replace our symlink, never write through it to the system binary.
        uname.write_text("#!/bin/sh\nprintf '%s\\n' MINGW64_NT\n")
        uname.chmod(0o755)
        cygpath = self.bin / "cygpath"
        cygpath.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"C:/Users/O'Brien/project/grok/hooks/notify.sh\"\n")
        cygpath.chmod(0o755)
        self.run_install()
        data = json.loads(self.hooks.read_text())
        expected = "bash 'C:/Users/O''Brien/project/grok/hooks/notify.sh'"
        for event in ("Stop", "Notification"):
            with self.subTest(event=event):
                self.assertEqual(data["hooks"][event][0]["hooks"][0]["command"], expected)
                self.assertNotIn("matcher", data["hooks"][event][0])

    def test_third_party_files_and_mixed_handlers_are_preserved(self):
        self.hooks.parent.mkdir(parents=True)
        other_file = self.hooks.parent / "vendor.json"
        other_bytes = b'{"hooks":{"Stop":[]},"vendor":"unchanged"}\n'
        other_file.write_bytes(other_bytes)
        third_party = {"type": "command", "command": "bash /opt/vendor/hooks/notify.sh", "timeout": 7}
        mixed = {
            "matcher": "vendor matcher", "custom_group_field": "preserve",
            "hooks": [
                {"type": "command", "command": "bash /old/coding_agents_env/grok/hooks/notify.sh"},
                third_party,
            ],
        }
        unrelated = {"hooks": [{"type": "command", "command": "echo third-party-start"}]}
        self.hooks.write_text(json.dumps({
            "custom_top_level": {"keep": True},
            "hooks": {"Stop": [mixed], "SessionStart": [unrelated]},
        }))
        self.run_install()
        data = self.assert_native_hooks()
        self.assertEqual(data["custom_top_level"], {"keep": True})
        self.assertEqual(data["hooks"]["SessionStart"], [unrelated])
        expected_group = {**mixed, "hooks": [third_party]}
        self.assertIn(expected_group, data["hooks"]["Stop"])
        self.assertEqual(other_file.read_bytes(), other_bytes)
        self.run_install()
        self.assertEqual(self.assert_native_hooks(), data)
        self.assertEqual(other_file.read_bytes(), other_bytes)

    def test_invalid_json_fails_without_overwriting_original(self):
        self.hooks.parent.mkdir(parents=True)
        for invalid in (b'{"hooks":{"Stop":[\n', b'', b'{}\n{}\n', b'[]\n'):
            with self.subTest(invalid=invalid):
                self.hooks.write_bytes(invalid)
                self.run_install(success=False)
                self.assertEqual(self.hooks.read_bytes(), invalid)

    def test_root_installer_supports_explicit_grok_and_new_default(self):
        self.run_install(root=True)
        self.assert_native_hooks()
        self.assertIn("GROK_NOTIFY_ENABLED=1", self.config.read_text().splitlines())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.home / ".claude").exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_root_installer_detects_grok_directory(self):
        self.grok_home.mkdir()
        self.run_install(root=True, detect=True)
        self.assert_native_hooks()

    def test_root_installer_detects_grok_on_path_without_running_it(self):
        marker = self.root / "grok-was-run"
        binary = self.bin / "grok"
        binary.write_text("#!/bin/sh\nprintf 'unexpected' > " + shlex.quote(str(marker)) + "\nexit 97\n")
        binary.chmod(0o755)
        self.run_install(root=True, detect=True)
        self.assert_native_hooks()
        self.assertFalse(marker.exists())

    def test_root_installer_migrates_legacy_switches_without_changing_existing_choice(self):
        for settings, expected in (
                ("NOTIFY_FROM_GROK=0\n", "0"),
                ("NOTIFY_FROM_GROK=1\n", "1"),
                ("GROK_NOTIFY_FROM_GROK=0\nNOTIFY_FROM_GROK=1\n", "0"),
                ("GROK_NOTIFY_FROM_GROK=1\nNOTIFY_FROM_GROK=0\n", "1"),
                ("GROK_NOTIFY_ENABLED=1\nGROK_NOTIFY_FROM_GROK=0\nNOTIFY_FROM_GROK=0\n", "1"),
                ("GROK_NOTIFY_ENABLED=0\nGROK_NOTIFY_FROM_GROK=1\nNOTIFY_FROM_GROK=1\n", "0")):
            with self.subTest(settings=settings):
                sentinel = "DISCORD_WEBHOOK_URL=https://example.invalid/test-only\n"
                self.write_config(settings + sentinel)
                self.run_install(root=True)
                contents = self.config.read_text()
                actual = [line for line in contents.splitlines() if line.startswith("GROK_NOTIFY_ENABLED=")]
                self.assertEqual(actual, ["GROK_NOTIFY_ENABLED=" + expected])
                self.assertIn(sentinel, contents)
                for old_line in settings.splitlines():
                    self.assertIn(old_line, contents.splitlines())
                self.run_install(root=True)
                self.assertEqual(self.config.read_text(), contents)


if __name__ == "__main__":
    unittest.main()
