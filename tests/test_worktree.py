"""install.sh must not dirty a fresh checkout, including on core.filemode=false."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from support import bash_exe, force_linux_uname, link_tool, set_unix_mode  # noqa: E402


REPO = Path(__file__).resolve().parents[1]


class WorktreeTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "repo"
        shutil.copytree(
            REPO,
            self.repo,
            ignore=shutil.ignore_patterns(".git", "__pycache__", ".github"),
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in (
            "bash", "jq", "curl", "git", "chmod", "cmp", "dirname", "basename",
            "mkdir", "tr", "grep", "sed", "awk", "mv", "rm", "cp", "uname", "cat",
            "ln", "head", "tail", "mktemp",
        ):
            link_tool(self.bin, name)
        force_linux_uname(self.bin)
        gitconfig = self.root / "gitconfig"
        gitconfig.write_text("")
        self.env = {
            "HOME": str(self.home),
            "PATH": str(self.bin),
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
            "NOTIFY_DRY_RUN": "1",
        }
        self.git("init")
        self.git("add", "-A")
        recorded = subprocess.run(
            ["git", "ls-files", "-s"],
            cwd=REPO,
            text=True,
            capture_output=True,
            check=True,
        )
        for line in recorded.stdout.splitlines():
            meta, path = line.split("\t", 1)
            mode = meta.split()[0]
            if not (self.repo / path).is_file():
                continue
            flag = "+x" if mode == "100755" else "-x"
            self.git("update-index", "--chmod=" + flag, "--", path)
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "test")
        self.git("commit", "-m", "init")
        self.runtime = self.repo / "lib" / "runtime.sh"
        self.send = self.repo / "lib" / "send.sh"
        # Only the scripts install.sh itself chmods. The root install.sh is not
        # in that list; clearing its bit would stay dirty for an unrelated reason.
        for pattern in ("lib/*.sh", "*/hooks/*.sh", "*/statusline/*.sh", "*/install.sh"):
            for path in self.repo.glob(pattern):
                set_unix_mode(path, 0o644)

    def git(self, *args, check=True):
        result = subprocess.run(
            ["git", *args],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_install(self):
        result = subprocess.run(
            [bash_exe(), str(self.repo / "install.sh")],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("未检测到", result.stderr)
        return result

    def index_mode(self, rel):
        line = self.git("ls-files", "-s", "--", rel).stdout.splitlines()[0]
        return line.split()[0]

    def is_executable(self, path):
        # Git Bash honors the Unix bit; os.access on Windows does not.
        result = subprocess.run(
            [bash_exe(), "-c", 'test -x "$1"', "bash", str(path)],
            env=self.env,
        )
        return result.returncode == 0

    def assert_clean(self):
        status = self.git("status", "--porcelain")
        self.assertEqual(status.stdout, "")
        self.assertEqual(self.index_mode("lib/runtime.sh"), "100644")
        self.assertEqual(self.index_mode("lib/send.sh"), "100755")

    def test_filemode_true_install_leaves_a_clean_tree(self):
        self.git("config", "core.filemode", "true")
        self.run_install()
        self.assert_clean()
        self.assertFalse(self.is_executable(self.runtime))
        self.assertTrue(self.is_executable(self.send))
        self.assertTrue(self.is_executable(self.repo / "grok" / "install.sh"))

    def test_filemode_false_restores_executable_scripts_only(self):
        self.git("config", "core.filemode", "false")
        set_unix_mode(self.runtime, 0o644)
        set_unix_mode(self.send, 0o644)
        self.run_install()
        self.assert_clean()
        self.assertFalse(self.is_executable(self.runtime))
        self.assertTrue(self.is_executable(self.send))
