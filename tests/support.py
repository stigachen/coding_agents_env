"""Helpers so unit tests can spawn bash from Win32 Python and from /bin/bash."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess


def _force_lf_writes() -> None:
    # Path.write_text translates \\n to os.linesep. On Windows that turns the
    # fixtures these shell tests read into CRLF and changes installer output.
    original = Path.write_text

    def write_text(self, data, encoding=None, errors=None, newline="\n"):
        return original(self, data, encoding=encoding, errors=errors, newline=newline)

    Path.write_text = write_text


_force_lf_writes()


def bash_exe() -> str:
    # GitHub Actions on Windows runs these tests with Win32 Python. CreateProcess
    # cannot open the MSYS path /bin/bash. TEST_BASH is a native path (cygpath -w)
    # set by the workflow; local Unix runs keep /bin/bash.
    override = os.environ.get("TEST_BASH")
    if override:
        return override
    if os.name != "nt" and os.path.isfile("/bin/bash"):
        return "/bin/bash"
    found = shutil.which("bash")
    if found:
        return found
    return "/bin/bash"


def link_tool(bin_dir: Path, name: str) -> None:
    executable = shutil.which(name)
    if not executable:
        return
    target = Path(executable)
    if os.name != "nt":
        link = bin_dir / name
        if not link.exists():
            link.symlink_to(target)
        return
    # Symlinks or copies of Git's .exe fail to load msys-2.0.dll from the
    # sandbox directory. A shell wrapper execs the real binary by absolute path.
    write_executable(
        bin_dir / name,
        "#!/bin/sh\nexec " + shlex.quote(target.as_posix()) + ' "$@"\n',
    )


def force_linux_uname(bin_dir: Path) -> None:
    # Installers branch on uname. A Windows runner's real uname is MINGW*, which
    # would take the Git Bash path and fail Unix-shaped assertions. Windows-stub
    # tests replace this script afterwards.
    if os.name != "nt":
        return
    write_executable(bin_dir / "uname", "#!/bin/sh\nprintf '%s\\n' Linux\n")


def write_executable(path: Path, text: str) -> None:
    # Drop a PATH stub. On Windows also remove name.exe: Git Bash's PATHEXT
    # would otherwise run the earlier symlink to the real tool. Write LF so the
    # shebang is not /bin/sh\\r, and chmod from bash because Win32 os.chmod
    # cannot set the bit Git Bash's test -x and exec see.
    for candidate in (path, path.with_name(path.name + ".exe")):
        if candidate.is_symlink() or candidate.exists():
            candidate.unlink()
    path.write_text(text, newline="\n")
    if os.name == "nt":
        subprocess.run(
            [bash_exe(), "-c", 'chmod +x "$1"', "chmod", str(path)],
            check=True,
        )
    else:
        path.chmod(0o755)


def set_unix_mode(path: Path, mode: int) -> None:
    if os.name != "nt":
        path.chmod(mode)
        return
    subprocess.run(
        [bash_exe(), "-c", 'chmod "$1" "$2"', "chmod", format(mode, "o"), str(path)],
        check=True,
    )


def bash_path(*parts: str) -> str:
    """Join PATH entries for Git Bash. Drive-letter colons are not separators."""
    converted = []
    for part in parts:
        text = part.replace("\\", "/")
        if os.name == "nt" and len(text) >= 2 and text[1] == ":":
            text = "/" + text[0].lower() + text[2:]
        converted.append(text)
    return ":".join(converted)


def posix_path(path: Path) -> str:
    """Path as the Unix installer records it. Git Bash pwd/cygpath, not pathlib."""
    if os.name != "nt":
        return str(path)
    result = subprocess.run(
        [bash_exe(), "-c", 'cygpath -u "$1"', "p", str(path)],
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def assert_unix_mode(test, path: Path, mode: int) -> None:
    # Git Bash stat reports 644 for modes that only differ by group/other read
    # (640, 604). 600 is representable and still checked. Linux and macOS check all.
    if os.name == "nt" and mode not in (0o600, 0o700, 0o755):
        return
    test.assertEqual(unix_mode(path), mode)


def unix_mode(path: Path) -> int:
    if os.name != "nt":
        return path.stat().st_mode & 0o777
    script = (
        'mode=$(stat -c \'%a\' "$1" 2>/dev/null) || mode=$(stat -f \'%OLp\' "$1")\n'
        "printf '%s\\n' \"$mode\"\n"
    )
    result = subprocess.run(
        [bash_exe(), "-c", script, "stat", str(path)],
        text=True,
        capture_output=True,
        check=True,
    )
    return int(result.stdout.strip(), 8)
