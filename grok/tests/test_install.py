"""Run installers against copied sources and temporary homes; never invoke an agent."""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests"))
from support import (  # noqa: E402
    assert_unix_mode,
    bash_exe,
    bash_path,
    force_linux_uname,
    link_tool,
    posix_path,
    set_unix_mode,
    write_executable,
)


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
                     "cp", "cmp", "stat", "awk", "sort", "cut", "readlink", "realpath", "date",
                     "python3"):
            link_tool(self.bin, name)
        force_linux_uname(self.bin)
        self.env = {"HOME": str(self.home), "PATH": str(self.bin), "NOTIFY_DRY_RUN": "1"}
        self.grok_home = self.home / ".grok"
        self.hooks = self.grok_home / "hooks" / "coding_agents_env.json"
        self.config = self.home / ".config" / "coding_agents_env" / "notify.env"

    def run_install(self, *, root=False, detect=False, success=True, env=None):
        script = self.repo / ("install.sh" if root else "grok/install.sh")
        command = [bash_exe(), str(script)]
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
                        self.assertEqual(command[1:], [posix_path(self.repo / "grok/hooks/notify.sh")])
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
            [bash_exe(), "-c", command],
            input=json.dumps({"hook_event_name": "Stop", "reason": "end_turn", "cwd": "/tmp/project"}),
            text=True, capture_output=True, timeout=5,
            env={**self.env, "NOTIFY_SKIP_WHEN_FOCUSED": "0", "NOTIFY_SHOW_HOST": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("agent=Grok kind=stop ", result.stdout)

    def use_windows_stubs(self):
        # Simulate Windows path generation only; do not execute PowerShell.
        write_executable(self.bin / "uname", "#!/bin/sh\nprintf '%s\\n' MINGW64_NT\n")
        cygpath = self.bin / "cygpath"
        cygpath_body = "\n".join([
            "#!/bin/sh",
            "path=",
            "for arg in \"$@\"; do",
            "  case \"$arg\" in",
            "    -w|-m|-u|-wa|-ma) ;;",
            "    *) path=$arg ;;",
            "  esac",
            "done",
            "case \"$path\" in",
            "  *system32*|*System32*|*Sysnative*|*SysWOW64*|*sysnative*|*syswow64*)",
            "    printf '%s\\n' 'C:\\Windows\\System32\\bash.exe' ;;",
            "  */bin/bash)",
            "    printf '%s\\n' 'C:\\Windows\\System32\\bash.exe' ;;",
            "  *statusline.sh)",
            "    printf '%s\\n' \"C:/Users/O'Brien/project/grok/statusline/statusline.sh\" ;;",
            "  *notify.sh)",
            "    printf '%s\\n' \"C:/Users/O'Brien/project/grok/hooks/notify.sh\" ;;",
            "  *git-preferred*)",
            "    printf '%s\\n' 'C:/Git/git-preferred/bash.exe' ;;",
            "  *git-pf86*)",
            "    printf '%s\\n' 'C:/Git/git-pf86/bash.exe' ;;",
            "  *git-custom*)",
            "    printf '%s\\n' 'C:/Git/git-custom/bash.exe' ;;",
            "  *git-local*)",
            "    printf '%s\\n' 'C:/Git/git-local/bash.exe' ;;",
            "  *git-pf*)",
            "    printf '%s\\n' 'C:/Git/git-pf/bash.exe' ;;",
            "  *coding_agents_env-statusline.cmd*)",
            "    printf '%s\\n' \"$path\" ;;",
            "  *)",
            "    printf '%s\\n' 'C:/Program Files/Git/bin/bash.exe' ;;",
            "esac",
            "",
        ])
        write_executable(cygpath, cygpath_body)

    def hook_command(self):
        data = json.loads(self.hooks.read_text())
        return data["hooks"]["Stop"][0]["hooks"][0]["command"]

    def test_windows_hook_command_quotes_apostrophe_for_powershell(self):
        self.use_windows_stubs()
        bash_exe = self.root / "git-preferred" / "bash.exe"
        bash_exe.parent.mkdir()
        bash_exe.write_text("")
        env = {"CLAUDE_CODE_GIT_BASH_PATH": str(bash_exe)}
        self.run_install(env=env)
        data = json.loads(self.hooks.read_text())
        expected = "'C:/Git/git-preferred/bash.exe' 'C:/Users/O''Brien/project/grok/hooks/notify.sh'"
        for event in ("Stop", "Notification"):
            with self.subTest(event=event):
                self.assertEqual(data["hooks"][event][0]["hooks"][0]["command"], expected)
                self.assertNotIn("matcher", data["hooks"][event][0])
        config = self.grok_home / "config.toml"
        wrapper = self.grok_home / "coding_agents_env-statusline.cmd"
        self.assertTrue(wrapper.is_file())
        # read_text() translates \r\n to \n, so check the bytes the installer wrote.
        wrapper_text = wrapper.read_bytes().decode("utf-8")
        self.assertIn('"C:/Git/git-preferred/bash.exe"', wrapper_text)
        self.assertIn(
            "\"C:/Users/O'Brien/project/grok/statusline/statusline.sh\"",
            wrapper_text,
        )
        self.assertTrue(wrapper_text.endswith("\r\n"))
        self.assertNotIn("\n", wrapper_text.replace("\r\n", ""))
        first_text = config.read_text()
        # pwd -W expands an 8.3 directory such as RUNNER~1 to its long name.
        # Python keeps the spelling it was given. Both names are this file.
        match = re.search(r'(?m)^command = "(.*)"$', first_text)
        self.assertIsNotNone(match, first_text)
        command = match.group(1)
        self.assertTrue(os.path.samefile(command, wrapper), (command, wrapper))
        self.assertNotIn("&", command)
        self.assertNotIn('"', command)
        self.assertNotIn("'", command)
        again = self.run_install(env=env)
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), first_text)
        self.assertEqual(json.loads(self.hooks.read_text()), data)

    def test_windows_status_command_keeps_a_path_with_spaces(self):
        self.use_windows_stubs()
        bash_exe = self.root / "git-preferred" / "bash.exe"
        bash_exe.parent.mkdir()
        bash_exe.write_text("")
        grok_home = self.home / "Grok Home"
        self.run_install(env={
            "CLAUDE_CODE_GIT_BASH_PATH": str(bash_exe),
            "GROK_HOME": str(grok_home),
        })
        wrapper = grok_home / "coding_agents_env-statusline.cmd"
        self.assertTrue(wrapper.is_file())
        text = (grok_home / "config.toml").read_text()
        match = re.search(r'(?m)^command = "(.*)"$', text)
        self.assertIsNotNone(match, text)
        command = match.group(1)
        self.assertIn("Grok Home", command)
        self.assertNotIn('"', command)
        self.assertNotIn("&", command)
        self.assertTrue(os.path.samefile(command, wrapper), (command, wrapper))

    def test_windows_git_bash_search_skips_system32(self):
        self.use_windows_stubs()
        result = self.run_install(success=False)
        self.assertIn("找不到 Git Bash", result.stderr)
        self.assertIn("CLAUDE_CODE_GIT_BASH_PATH", result.stderr)
        self.assertFalse(self.hooks.exists())
        self.assertFalse((self.grok_home / "config.toml").exists())

        def touch(path):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("")
            return path

        system = touch(self.root / "win-system32" / "bash.exe")
        preferred = touch(self.root / "git-preferred" / "bash.exe")
        program = touch(self.root / "git-pf" / "Git" / "bin" / "bash.exe")
        local = touch(self.root / "git-local" / "Programs" / "Git" / "bin" / "bash.exe")
        pf86 = touch(self.root / "git-pf86" / "Git" / "bin" / "bash.exe")
        custom = touch(self.root / "git-custom" / "bash.exe")
        cases = (
            ("env", {"CLAUDE_CODE_GIT_BASH_PATH": str(preferred), "PROGRAMFILES": str(self.root / "git-pf")},
             "'C:/Git/git-preferred/bash.exe'"),
            ("program-files", {"PROGRAMFILES": str(self.root / "git-pf"), "LOCALAPPDATA": str(self.root / "git-local")},
             "'C:/Git/git-pf/bash.exe'"),
            ("local", {"LOCALAPPDATA": str(self.root / "git-local"), "ProgramFiles(x86)": str(self.root / "git-pf86")},
             "'C:/Git/git-local/bash.exe'"),
            ("pf86", {"ProgramFiles(x86)": str(self.root / "git-pf86")},
             "'C:/Git/git-pf86/bash.exe'"),
            ("path", {"PATH": bash_path(str(custom.parent), str(self.bin))},
             "'C:/Git/git-custom/bash.exe'"),
            ("skip-wsl-then-program-files", {
                "CLAUDE_CODE_GIT_BASH_PATH": str(system),
                "PROGRAMFILES": str(self.root / "git-pf"),
                "PATH": bash_path(str(custom.parent), str(self.bin)),
            }, "'C:/Git/git-pf/bash.exe'"),
        )
        for name, env, prefix in cases:
            with self.subTest(which=name):
                if self.grok_home.exists():
                    shutil.rmtree(self.grok_home)
                self.run_install(env=env)
                command = self.hook_command()
                self.assertTrue(command.startswith(prefix + " "), command)
                self.assertIn("O''Brien", command)
                self.assertNotIn("System32", command)

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
        assert_unix_mode(self, self.config, 0o600)
        self.assertFalse((self.home / ".claude").exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_root_installer_detects_grok_directory(self):
        self.grok_home.mkdir()
        self.run_install(root=True, detect=True)
        self.assert_native_hooks()

    def test_root_installer_detects_grok_on_path_without_running_it(self):
        marker = self.root / "grok-was-run"
        write_executable(
            self.bin / "grok",
            "#!/bin/sh\nprintf 'unexpected' > " + shlex.quote(str(marker)) + "\nexit 97\n",
        )
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
            [bash_exe(), "-c", self.status_command(text)],
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
        self.assertFalse(config.with_name("config.toml.bak").exists())

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
        set_unix_mode(config, 0o640)
        result = self.run_install()
        self.assertNotIn("接管", result.stderr)
        text = config.read_text()
        self.assertIn("max_thoughts_width = 120\n", text)
        self.assertIn('type = "keep-ui"\n', text)
        self.assertIn('command = "keep"\n', text)
        self.assertEqual(text.count("[ui.status_line]"), 1)
        self.assertEqual(text.count('type = "command"'), 1)
        assert_unix_mode(self, config, 0o640)
        self.assertEqual(config.with_name("config.toml.bak").read_text(), original)
        self.assert_status_command_runs(text)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)
        self.assertEqual(config.with_name("config.toml.bak").read_text(), original)
        config.write_text(text + "extra = 1\n")
        self.run_install()
        self.assertEqual(config.with_name("config.toml.bak").read_text(), original)

    def test_statusline_follows_relative_symlink_chain(self):
        actual = self.home / "actual.toml"
        actual.write_text("[ui]\nmax_thoughts_width = 120\n")
        set_unix_mode(actual, 0o604)
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
        assert_unix_mode(self, actual, 0o604)
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
        if os.name == "nt":
            # Git Bash rewrites the merged file as LF. Linux still requires CRLF.
            text = text.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
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
        again_bytes = config.read_bytes()
        if os.name == "nt":
            again_bytes = again_bytes.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        self.assertEqual(again_bytes, text)

    def test_dangling_config_symlink_is_not_replaced(self):
        self.grok_home.mkdir()
        link = self.grok_home / "config.toml"
        link.symlink_to(self.root / "missing.toml")
        self.run_install(success=False)
        self.assertTrue(link.is_symlink())
        self.assertFalse((self.root / "missing.toml").exists())

    @unittest.skipIf(os.name == "nt", "Windows paths cannot contain a directory named C:")
    def test_windows_drive_symlink_is_not_joined_as_relative(self):
        self.grok_home.mkdir()
        decoy_dir = self.grok_home / "C:"
        decoy_dir.mkdir()
        decoy = decoy_dir / "real.toml"
        decoy.write_text("decoy = true\n")
        link = self.grok_home / "config.toml"
        for target in ("C:/real.toml", "C:\\real.toml"):
            with self.subTest(target=target):
                if link.is_symlink() or link.exists():
                    link.unlink()
                link.symlink_to(target)
                decoy.write_text("decoy = true\n")
                result = self.run_install(success=False)
                self.assertIn("软链悬空", result.stderr)
                self.assertTrue(link.is_symlink())
                self.assertEqual(os.readlink(link), target)
                self.assertEqual(decoy.read_text(), "decoy = true\n")

    def write_grok_config(self, contents, mode=0o640):
        self.grok_home.mkdir(exist_ok=True)
        config = self.grok_home / "config.toml"
        data = contents.encode() if isinstance(contents, str) else contents
        config.write_bytes(data)
        set_unix_mode(config, mode)
        return config

    def load_toml(self, path):
        import tomllib
        return tomllib.loads(path.read_bytes().decode())

    def assert_status_table(self, path):
        data = self.load_toml(path)
        status = data["ui"]["status_line"]
        self.assertEqual(status["type"], "command")
        self.assertIn("/grok/statusline/statusline.sh", status["command"])
        self.assertEqual(list(status).count("type"), 1)
        self.assertEqual(list(status).count("command"), 1)
        return data

    def assert_config_unchanged(self, config, original, mode=0o640):
        self.assertEqual(config.read_bytes(), original)
        assert_unix_mode(self, config, mode)
        self.assertFalse(config.with_name("config.toml.bak").exists())

    def replace_stat(self, script):
        write_executable(self.bin / "stat", script)

    def test_gnu_stat_failure_text_is_not_used_as_the_mode(self):
        # GNU `stat -f` prints filesystem info and exits non-zero. A combined
        # `$(stat -f || stat -c)` would feed that text to chmod.
        original = "[ui]\nyolo = false\n"
        gnu = """#!/bin/sh
if [ "$1" = "-c" ]; then
  printf '%s\\n' 640
  exit 0
fi
printf '  File: "%s"\\n    ID: deadbeef Namelen: 255\\n' "$3"
echo "stat: cannot statx '$2': No such file or directory" >&2
exit 1
"""
        fallback = """#!/bin/sh
if [ "$1" = "-c" ]; then
  printf '  File: "junk"\\n640\\n'
  exit 1
fi
printf '%s\\n' 640
exit 0
"""
        for name, script in (("gnu", gnu), ("bsd-fallback", fallback)):
            with self.subTest(stat=name):
                config = self.write_grok_config(original)
                self.replace_stat(script)
                result = self.run_install()
                self.assertNotIn("无法读取权限", result.stderr)
                assert_unix_mode(self, config, 0o640)
                self.assert_status_table(config)
                self.assertEqual(self.load_toml(config)["ui"]["yolo"], False)
                self.assertEqual(config.with_name("config.toml.bak").read_text(), original)

    def test_multiline_command_and_decoy_header_stay_valid(self):
        config = self.write_grok_config(
            'note = """\n'
            '[ui.status_line]\n'
            'type = "stolen"\n'
            '"""\n'
            'title = "say \\"[ui.status_line]\\" ok"\n'
            '\n'
            '[mcp]\n'
            'enabled = true\n'
            '\n'
            '[ui.status_line]\n'
            'type = "command"\n'
            'command = """\n'
            'bash ~/.grok/old-status.sh\n'
            '"""\n'
            'padding = 2\n'
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_text()
        self.assertNotIn("old-status.sh", text)
        command_line = next(line for line in text.splitlines() if line.startswith("command = "))
        self.assertTrue(command_line.startswith('command = "') and command_line.endswith('"'))
        self.assertNotIn('"""', command_line)
        self.assertIn('note = """\n[ui.status_line]\ntype = "stolen"\n"""\n', text)
        data = self.assert_status_table(config)
        self.assertEqual(data["ui"]["status_line"]["padding"], 2)
        self.assertEqual(data["note"], '[ui.status_line]\ntype = "stolen"\n')
        self.assertEqual(data["title"], 'say "[ui.status_line]" ok')
        self.assertEqual(data["mcp"]["enabled"], True)
        headers = [line for line in text.splitlines() if line.strip() == "[ui.status_line]"]
        self.assertEqual(headers, ["[ui.status_line]", "[ui.status_line]"])
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_spaced_header_and_quoted_keys_are_updated_in_place(self):
        config = self.write_grok_config(
            '[ ui . status_line ]\n'
            '"type" = "builtin"\n'
            '\'command\' = "echo hello"\n'
            'padding = 2\n'
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_text()
        self.assertEqual(text.count("status_line"), 1)
        self.assertNotIn("builtin", text)
        self.assertNotIn("echo hello", text)
        self.assertNotIn('"type"', text)
        data = self.assert_status_table(config)
        self.assertEqual(data["ui"]["status_line"]["padding"], 2)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_quoted_table_header_is_the_same_table(self):
        config = self.write_grok_config(
            "[ \"ui\" . 'status_line' ]\n"
            "padding = 2\n"
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_text()
        self.assertEqual(text.count("status_line"), 1)
        data = self.assert_status_table(config)
        self.assertEqual(data["ui"]["status_line"]["padding"], 2)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_inline_status_line_keeps_other_keys(self):
        original_ui = {"max_thoughts_width": 120, "yolo": False}
        config = self.write_grok_config(
            "[ui]\n"
            "max_thoughts_width = 120\n"
            "yolo = false\n"
            'status_line = { type = "command", command = "echo hello", padding = 2 }\n'
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_text()
        self.assertNotIn("[ui.status_line]", text)
        self.assertNotIn("echo hello", text)
        data = self.assert_status_table(config)
        self.assertEqual(data["ui"]["max_thoughts_width"], original_ui["max_thoughts_width"])
        self.assertEqual(data["ui"]["yolo"], original_ui["yolo"])
        self.assertEqual(data["ui"]["status_line"]["padding"], 2)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_dotted_status_line_keys_are_updated_without_a_second_table(self):
        config = self.write_grok_config(
            "[ui]\n"
            "yolo = false\n"
            "status_line.padding = 2\n"
            'status_line.type = "builtin"\n'
            'status_line.command = """\n'
            "echo hello\n"
            '"""\n'
            "theme = \"dark\"\n"
        )
        result = self.run_install()
        self.assertIn("接管", result.stderr)
        text = config.read_text()
        self.assertNotIn("[ui.status_line]", text)
        self.assertNotIn("echo hello", text)
        self.assertNotIn('"""', text)
        data = self.assert_status_table(config)
        self.assertEqual(data["ui"]["yolo"], False)
        self.assertEqual(data["ui"]["theme"], "dark")
        self.assertEqual(data["ui"]["status_line"]["padding"], 2)
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def test_real_config_shape_appends_status_line_without_rewriting_arrays(self):
        original = (
            "[cli]\n"
            "installer = \"test\"\n"
            "\n"
            "[[marketplace.sources]]\n"
            "name = \"official\"\n"
            "git = \"https://example.invalid/repo.git\"\n"
            "\n"
            "[ui]\n"
            "max_thoughts_width = 120\n"
            "yolo = false\n"
            "\n"
            "[mcp_servers.rea]\n"
            "command = \"keep\"\n"
            "args = [\n"
            "  \"-y\",\n"
            "  \"rea-agents@6.5.0\",\n"
            "  \"mcp\",\n"
            "]\n"
            "\n"
            "[mcp_servers.rea.env]\n"
            "HOPPER_LAUNCHER_PATH = \"/tmp/hopper\"\n"
        )
        config = self.write_grok_config(original)
        before = self.load_toml(config)
        result = self.run_install()
        self.assertNotIn("接管", result.stderr)
        data = self.assert_status_table(config)
        before_ui = dict(before["ui"])
        after_ui = dict(data["ui"])
        after_ui.pop("status_line")
        self.assertEqual(after_ui, before_ui)
        self.assertEqual(data["mcp_servers"]["rea"]["command"], "keep")
        self.assertEqual(data["mcp_servers"]["rea"]["args"], ["-y", "rea-agents@6.5.0", "mcp"])
        self.assertEqual(data["mcp_servers"]["rea"]["env"]["HOPPER_LAUNCHER_PATH"], "/tmp/hopper")
        self.assertEqual(data["marketplace"]["sources"][0]["name"], "official")
        text = config.read_text()
        again = self.run_install()
        self.assertNotIn("接管", again.stderr)
        self.assertEqual(config.read_text(), text)

    def hide_python(self):
        python = self.bin / "python3"
        if python.exists() or python.is_symlink():
            python.unlink()
        self.assertFalse(python.exists())

    def write_python(self, script):
        write_executable(self.bin / "python3", script)

    def test_python3_that_cannot_run_skips_toml_check(self):
        self.write_python("#!/bin/sh\nexit 9009\n")
        self.run_install()
        config = self.grok_home / "config.toml"
        status = self.load_toml(config)["ui"]["status_line"]
        self.assertEqual(status["type"], "command")
        self.assertIn("/grok/statusline/statusline.sh", status["command"])

    def test_python3_exit_1_rejects_without_replacing_config(self):
        self.write_python("#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then exit 0; fi\nexit 1\n")
        config = self.write_grok_config("yolo = false\n")
        original = config.read_bytes()
        result = self.run_install(success=False)
        self.assertIn("不是合法 TOML", result.stderr)
        self.assert_config_unchanged(config, original)

    def test_root_inline_ui_merges_without_python(self):
        self.hide_python()
        cases = {
            "foreign-status": (
                'ui = { yolo = false, status_line = { type = "builtin", padding = 2, extra = { a = 1 } } }\n'
                '\n'
                '[mcp]\n'
                'enabled = true\n',
                True,
            ),
            "insert-status": ('ui = { yolo = false } # keep\n', False),
            "quoted-ui": ('"ui" = { yolo = false }\n', False),
            "dotted-inside": (
                'ui = { yolo = false, status_line.type = "builtin", '
                'status_line.command = "echo hello", status_line.padding = 2 }\n',
                True,
            ),
            "multiline": (
                'ui = {\n'
                '  yolo = false,\n'
                '  status_line = { type = "builtin", padding = 2 }\n'
                '}\n',
                True,
            ),
            "key-after-status": (
                'ui = { yolo = false, status_line = { padding = 2 }, theme = "dark" }\n',
                True,
            ),
        }
        for name, (contents, takeover) in cases.items():
            with self.subTest(shape=name):
                config = self.write_grok_config(contents)
                result = self.run_install()
                if takeover:
                    self.assertIn("接管", result.stderr)
                else:
                    self.assertNotIn("接管", result.stderr)
                text = config.read_text()
                headers = [line for line in text.splitlines() if line.strip() == "[ui.status_line]"]
                self.assertEqual(headers, [])
                self.assertNotIn("builtin", text)
                self.assertNotIn("echo hello", text)
                data = self.assert_status_table(config)
                self.assertIs(data["ui"]["yolo"], False)
                if name == "foreign-status":
                    self.assertEqual(data["ui"]["status_line"]["padding"], 2)
                    self.assertEqual(data["ui"]["status_line"]["extra"]["a"], 1)
                    self.assertEqual(data["mcp"]["enabled"], True)
                if name == "insert-status":
                    self.assertIn("# keep", text)
                if name == "dotted-inside":
                    self.assertEqual(data["ui"]["status_line"]["padding"], 2)
                if name == "key-after-status":
                    self.assertEqual(data["ui"]["status_line"]["padding"], 2)
                    self.assertEqual(data["ui"]["theme"], "dark")
                assert_unix_mode(self, config, 0o640)
                again = self.run_install()
                self.assertNotIn("接管", again.stderr)
                self.assertEqual(config.read_text(), text)

    def test_non_inline_ui_still_appends_without_python(self):
        self.hide_python()
        cases = {
            "dotted-parent": "ui.yolo = false\n",
            "standard-table": "[ui]\nyolo = false\n",
            "nested-dotted": "ui.ui = { yolo = false }\n",
            "subtable": '[ui.theme]\nname = "dark"\n',
        }
        for name, contents in cases.items():
            with self.subTest(shape=name):
                config = self.write_grok_config(contents)
                result = self.run_install()
                self.assertNotIn("接管", result.stderr)
                self.assertIn("[ui.status_line]", config.read_text())
                data = self.load_toml(config)
                status = data["ui"]["status_line"]
                self.assertEqual(status["type"], "command")
                self.assertIn("/grok/statusline/statusline.sh", status["command"])
                if name == "nested-dotted":
                    self.assertIs(data["ui"]["ui"]["yolo"], False)
                elif name == "subtable":
                    self.assertEqual(data["ui"]["theme"]["name"], "dark")
                else:
                    self.assertIs(data["ui"]["yolo"], False)

    def test_root_ui_unsafe_shapes_leave_the_file_unchanged_without_python(self):
        self.hide_python()
        samples = {
            "string": 'ui = "nope"\n',
            "array": "ui = [1]\n",
            "status-string": 'ui = { status_line = "nope" }\n',
            "comment": "ui = { yolo = false # keep\n}\n",
            "mixed": 'ui = { status_line = { padding = 1 }, status_line.type = "builtin" }\n',
            "dotted-then-inline": "ui.yolo = false\nui = { padding = 1 }\n",
            "inline-then-subtable": 'ui = { yolo = false }\n\n[ui.theme]\nname = "dark"\n',
            "duplicate-inline": "ui = { yolo = false }\nui = { padding = 1 }\n",
        }
        for name, contents in samples.items():
            with self.subTest(shape=name):
                config = self.write_grok_config(contents)
                original = config.read_bytes()
                result = self.run_install(success=False)
                self.assertIn("原文件未修改", result.stderr)
                self.assert_config_unchanged(config, original)

    def test_unsafe_status_line_shapes_leave_the_file_unchanged(self):
        samples = {
            "array-of-tables": "[[ui.status_line]]\ntype = \"command\"\n",
            "string-value": "[ui]\nstatus_line = \"nope\"\n",
            "inline-comment": "[ui]\nstatus_line = { type = \"builtin\", padding = 2 # keep\n}\n",
            "unclosed-string": "title = \"oops\n",
        }
        for name, contents in samples.items():
            with self.subTest(shape=name):
                config = self.write_grok_config(contents)
                original = config.read_bytes()
                result = self.run_install(success=False)
                self.assertIn("原文件未修改", result.stderr)
                self.assert_config_unchanged(config, original)


if __name__ == "__main__":
    unittest.main()
