"""Run installers against copied sources and temporary homes; never invoke an agent."""

import json
import os
from pathlib import Path
import re
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

    def test_root_installer_supports_explicit_grok_without_extra_gates(self):
        self.run_install(root=True)
        self.assert_native_hooks()
        keys = {line.partition("=")[0] for line in self.config.read_text().splitlines()}
        self.assertTrue(keys.isdisjoint({"GROK_NOTIFY_ENABLED", "GROK_NOTIFY_FROM_GROK", "NOTIFY_FROM_GROK"}))
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

    def test_obsolete_keys_are_preserved_without_creating_or_migrating_gates(self):
        obsolete = {"GROK_NOTIFY_ENABLED", "GROK_NOTIFY_FROM_GROK", "NOTIFY_FROM_GROK"}
        for key in sorted(obsolete):
            for value in ("0", "1", ""):
                with self.subTest(key=key, value=value):
                    old_line = key + "=" + value
                    sentinel = "DISCORD_WEBHOOK_URL=https://example.invalid/test-only\n"
                    self.write_config(old_line + "\n" + sentinel)
                    self.run_install(root=True)
                    contents = self.config.read_text()
                    actual = [line for line in contents.splitlines() if line.partition("=")[0] in obsolete]
                    self.assertEqual(actual, [old_line])
                    self.assertIn(sentinel, contents)
                    for line in contents.splitlines():
                        if line.startswith("GROK_NOTIFY_ON_"):
                            self.assertNotEqual(line.partition("=")[2], "0", line)
                    self.run_install(root=True)
                    self.assertEqual(self.config.read_text(), contents)

    def test_existing_grok_event_overrides_are_preserved(self):
        settings = "NOTIFY_FROM_GROK=0\nGROK_NOTIFY_ON_STOP=1\nGROK_NOTIFY_ON_IDLE=0\n"
        self.write_config(settings)
        self.run_install(root=True)
        lines = self.config.read_text().splitlines()
        for line in settings.splitlines():
            self.assertEqual(lines.count(line), 1)

    def toml_basic_unescape(self, value):
        out = []
        index = 0
        while index < len(value):
            if value[index] == "\\" and index + 1 < len(value):
                out.append(value[index + 1])
                index += 2
            else:
                out.append(value[index])
                index += 1
        return "".join(out)

    def status_command(self, text):
        found = []
        for line in text.splitlines():
            match = re.match(r'^command = "(.*)"$', line)
            if match and "statusline.sh" in match.group(1):
                found.append(self.toml_basic_unescape(match.group(1)))
        self.assertEqual(len(found), 1, text)
        return found[0]

    def assert_status_command_runs(self, text):
        rendered = subprocess.run(
            ["/bin/bash", "-c", self.status_command(text)],
            input='{"model":{"display_name":"Grok 4.7"}}\n',
            text=True, capture_output=True, timeout=10,
            env={**os.environ, "HOME": str(self.home)},
        )
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("Grok 4.7", rendered.stdout)

    def test_missing_config_gets_statusline_without_backup(self):
        result = self.run_install()
        self.assertNotIn("接管", result.stderr)
        config = self.grok_home / "config.toml"
        text = config.read_text()
        self.assertTrue(text.startswith("[ui.status_line]\n"))
        self.assertEqual(text.count('type = "command"'), 1)
        self.assertIn("/grok/statusline/statusline.sh", text)
        self.assertFalse(config.with_name("config.toml.bak").exists())
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_statusline_preserves_other_tables_mode_and_runs(self):
        self.grok_home.mkdir()
        config = self.grok_home / "config.toml"
        original = (
            "[ui]\n"
            "max_thoughts_width = 120\n"
            "type = \"keep-ui\"\n"
            "\n"
            "[mcp_servers.rea]\n"
            "command = \"keep\"\n"
        )
        config.write_text(original)
        config.chmod(0o640)
        result = self.run_install()
        self.assertNotIn("接管", result.stderr)
        text = config.read_text()
        self.assertIn("max_thoughts_width = 120\n", text)
        self.assertIn('type = "keep-ui"\n', text)
        self.assertIn('command = "keep"\n', text)
        self.assertEqual(text.count("[ui.status_line]"), 1)
        self.assertEqual(text.count('type = "command"'), 1)
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(config.with_name("config.toml.bak").read_text(), original)
        self.assert_status_command_runs(text)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_statusline_follows_relative_symlink_chain(self):
        actual = self.home / "actual.toml"
        actual.write_text("[ui]\nmax_thoughts_width = 120\n")
        actual.chmod(0o604)
        mid = self.home / "mid.toml"
        mid.symlink_to("actual.toml")
        self.grok_home.mkdir()
        link = self.grok_home / "config.toml"
        link.symlink_to("../mid.toml")
        self.run_install()
        self.assertTrue(link.is_symlink())
        self.assertTrue(mid.is_symlink())
        text = actual.read_text()
        self.assertIn("max_thoughts_width = 120", text)
        self.assertIn("[ui.status_line]", text)
        self.assert_status_command_runs(text)
        self.assertEqual(actual.stat().st_mode & 0o777, 0o604)
        self.assertEqual((self.home / "actual.toml.bak").read_text(), "[ui]\nmax_thoughts_width = 120\n")
        self.assertFalse((self.grok_home / "config.toml.bak").exists())

    def test_statusline_takes_over_foreign_command_and_keeps_other_keys(self):
        self.grok_home.mkdir()
        config = self.grok_home / "config.toml"
        config.write_bytes(
            "[ui]\r\nyolo = false\r\n\r\n"
            "[ui.status_line]\r\n"
            "# user note\r\n"
            "items = [\"cwd\", \"model\"]\r\n"
            "padding = 2\r\n"
            "type = \"builtin\"\r\n"
            "refresh_interval = 30\r\n"
            "command = \"~/.grok/other.sh\"\r\n"
            "\r\n"
            "[mcp]\r\n"
            "enabled = true\r\n".encode()
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_bytes()
        self.assertIn(b"[ui]\r\nyolo = false\r\n", text)
        self.assertIn(b"[mcp]\r\nenabled = true\r\n", text)
        self.assertIn(b"# user note\r\n", text)
        self.assertIn(b"items = [\"cwd\", \"model\"]\r\n", text)
        self.assertIn(b"padding = 2\r\n", text)
        self.assertIn(b"refresh_interval = 30\r\n", text)
        self.assertNotIn(b"builtin", text)
        self.assertNotIn(b"other.sh", text)
        self.assertEqual(text.count(b"[ui.status_line]"), 1)
        self.assertEqual(text.count(b'type = "command"'), 1)
        self.assertEqual(text.count(b"/grok/statusline/statusline.sh"), 1)
        header = text.split(b"[ui.status_line]\r\n", 1)[1]
        self.assertTrue(header.startswith(b'type = "command"\r\ncommand = "'))
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_bytes(), text)

    def test_dangling_config_symlink_is_not_replaced(self):
        self.grok_home.mkdir()
        link = self.grok_home / "config.toml"
        link.symlink_to(self.root / "missing.toml")
        self.run_install(success=False)
        self.assertTrue(link.is_symlink())
        self.assertFalse((self.root / "missing.toml").exists())


if __name__ == "__main__":
    unittest.main()
