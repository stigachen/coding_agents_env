"""Install Codex hooks into a temporary CODEX_HOME. Never touch ~/.codex."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[2]
INSTALL = REPO / "codex" / "install.sh"


class InstallTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.codex_home = self.root / "O'Brien" / ".codex"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "jq", "dirname", "mkdir", "tr", "grep", "sed", "head", "mktemp",
                     "mv", "rm", "uname", "cat", "cp", "cmp", "awk", "cut", "printenv", "shasum",
                     "sha256sum", "openssl", "python3"):
            executable = shutil.which(name)
            if executable:
                (self.bin / name).symlink_to(executable)
        self.env = {
            "HOME": str(self.home),
            "PATH": str(self.bin),
            "CODEX_HOME": str(self.codex_home),
            "NOTIFY_DRY_RUN": "1",
        }

    def run_install(self, *, success=True, env=None):
        result = subprocess.run(
            ["/bin/bash", str(INSTALL)],
            env={**self.env, **(env or {})}, text=True, capture_output=True, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def use_windows_stubs(self):
        uname = self.bin / "uname"
        uname.unlink()
        uname.write_text("#!/bin/sh\nprintf '%s\\n' MINGW64_NT\n")
        uname.chmod(0o755)
        cygpath = self.bin / "cygpath"
        cygpath.write_text("\n".join([
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
            "  *hooks.json)",
            "    printf '%s\\n' 'C:\\Users\\O'\"'\"'Brien\\.codex\\hooks.json' ;;",
            "  *notify.sh)",
            "    printf '%s\\n' \"C:/Users/O'Brien/project/codex/hooks/notify.sh\" ;;",
            "  *git-preferred*)",
            "    printf '%s\\n' 'C:/Git/git-preferred/bash.exe' ;;",
            "  *)",
            "    printf '%s\\n' 'C:/Program Files/Git/bin/bash.exe' ;;",
            "esac",
            "",
        ]))
        cygpath.chmod(0o755)

    def write_python(self, script):
        python = self.bin / "python3"
        if python.is_symlink() or python.exists():
            python.unlink()
        python.write_text(script)
        python.chmod(0o755)

    def test_unix_install_is_idempotent(self):
        self.run_install()
        hooks_path = self.codex_home / "hooks.json"
        config_path = self.codex_home / "config.toml"
        hooks = json.loads(hooks_path.read_text())
        command = hooks["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(command, 'bash "' + str(REPO / "codex" / "hooks" / "notify.sh") + '"')
        self.assertEqual(
            hooks["hooks"]["PermissionRequest"][0]["hooks"][0]["command"], command)
        text = config_path.read_text()
        data = tomllib.loads(text)
        self.assertIs(data["features"]["hooks"], True)
        self.assertIn("model-with-reasoning", data["tui"]["status_line"])
        state = data["hooks"]["state"]
        self.assertEqual(len(state), 2)
        for key, value in state.items():
            self.assertIn("O'Brien", key)
            self.assertNotIn("\\", key)
            self.assertTrue(value["trusted_hash"].startswith("sha256:"))
        self.assertNotIn("[hooks.state.'", text)
        hooks_text = hooks_path.read_text()
        self.run_install()
        self.assertEqual(config_path.read_text(), text)
        self.assertEqual(hooks_path.read_text(), hooks_text)
        self.assertFalse(config_path.with_name("config.toml.bak").exists())

    def test_existing_config_backup_survives_a_second_install(self):
        self.codex_home.mkdir(parents=True)
        config = self.codex_home / "config.toml"
        original = "keep = 1\n"
        config.write_text(original)
        self.run_install()
        backup = config.with_name("config.toml.bak")
        self.assertEqual(backup.read_text(), original)
        self.assertNotEqual(config.read_text(), original)
        config.write_text(config.read_text() + "extra = 1\n")
        self.run_install()
        self.assertEqual(backup.read_text(), original)
        self.assertIn("keep = 1", config.read_text())
        self.assertIn("trusted_hash", config.read_text())

    def test_windows_command_and_trust_key_round_trip(self):
        self.use_windows_stubs()
        bash_exe = self.root / "git-preferred" / "bash.exe"
        bash_exe.parent.mkdir()
        bash_exe.write_text("")
        foreign = "D:\\other\\hooks.json:stop:0:0"
        config_path = self.codex_home / "config.toml"
        config_path.parent.mkdir(parents=True)
        config_path.write_bytes(
            "[features]\r\n"
            "theme = \"dark\"\r\n"
            "\r\n"
            "[hooks.state.'C:\\Users\\O'Brien\\.codex\\hooks.json:stop:0:0']\r\n"
            "trusted_hash = \"sha256:deadbeef\"\r\n"
            "\r\n"
            "[hooks.state.'C:\\Users\\O'Brien\\.codex\\hooks.json:permission_request:0:0']\r\n"
            "trusted_hash = \"sha256:deadbeef\"\r\n"
            "\r\n"
            "[hooks.state.\"D:\\\\other\\\\hooks.json:stop:0:0\"]\r\n"
            "trusted_hash = \"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"\r\n"
            .encode()
        )
        env = {"CLAUDE_CODE_GIT_BASH_PATH": str(bash_exe)}
        self.run_install(env=env)
        hooks = json.loads((self.codex_home / "hooks.json").read_text())
        expected = '"C:/Git/git-preferred/bash.exe" "C:/Users/O\'Brien/project/codex/hooks/notify.sh"'
        for event in ("Stop", "PermissionRequest"):
            with self.subTest(event=event):
                self.assertEqual(hooks["hooks"][event][0]["hooks"][0]["command"], expected)
        text = config_path.read_text()
        self.assertNotIn("[hooks.state.'", text)
        self.assertEqual(text.count('[hooks.state."C:\\\\Users\\\\O\'Brien\\\\.codex\\\\hooks.json:stop:0:0"]'), 1)
        data = tomllib.loads(text)
        self.assertEqual(data["features"]["theme"], "dark")
        self.assertIs(data["features"]["hooks"], True)
        stop = "C:\\Users\\O'Brien\\.codex\\hooks.json:stop:0:0"
        perm = "C:\\Users\\O'Brien\\.codex\\hooks.json:permission_request:0:0"
        state = data["hooks"]["state"]
        self.assertEqual(set(state), {stop, perm, foreign})
        for key in (stop, perm):
            self.assertTrue(state[key]["trusted_hash"].startswith("sha256:"))
            self.assertNotEqual(state[key]["trusted_hash"], "sha256:deadbeef")
        self.assertEqual(
            state[foreign]["trusted_hash"],
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        )
        self.run_install(env=env)
        self.assertEqual(config_path.read_text(), text)

    def test_windows_without_git_bash_does_not_create_a_home(self):
        self.use_windows_stubs()
        result = self.run_install(success=False)
        self.assertIn("找不到 Git Bash", result.stderr)
        self.assertIn("CLAUDE_CODE_GIT_BASH_PATH", result.stderr)
        self.assertFalse(self.codex_home.exists())

    def test_python3_that_cannot_run_skips_toml_check(self):
        self.write_python("#!/bin/sh\nexit 9009\n")
        self.run_install()
        data = tomllib.loads((self.codex_home / "config.toml").read_text())
        self.assertIs(data["features"]["hooks"], True)
        self.assertEqual(len(data["hooks"]["state"]), 2)

    def test_python3_exit_1_rolls_back(self):
        self.write_python("#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then exit 0; fi\nexit 1\n")
        self.codex_home.mkdir(parents=True)
        config = self.codex_home / "config.toml"
        config.write_text("keep = 1\n")
        result = self.run_install(success=False)
        self.assertIn("不是合法 TOML", result.stderr)
        self.assertEqual(config.read_text(), "keep = 1\n")

    def test_python3_other_exit_does_not_roll_back(self):
        self.write_python("#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then exit 0; fi\nexit 2\n")
        self.codex_home.mkdir(parents=True)
        config = self.codex_home / "config.toml"
        config.write_text("keep = 1\n")
        self.run_install()
        text = config.read_text()
        self.assertIn("keep = 1", text)
        self.assertIn("trusted_hash", text)
        data = tomllib.loads(text)
        self.assertEqual(data["keep"], 1)
        self.assertIs(data["features"]["hooks"], True)


if __name__ == "__main__":
    unittest.main()
