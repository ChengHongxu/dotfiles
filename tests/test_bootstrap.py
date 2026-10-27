"""Exercise bootstrap with isolated HOME/PATH; never install real packages."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BOOTSTRAP = Path(__file__).resolve().parents[1] / "bootstrap.sh"
STUB = r"""#!/bin/bash
set -eu
tool=${0##*/}
printf '%s' "$tool" >> "$CALL_LOG"
printf ' <%s>' "$@" >> "$CALL_LOG"
printf '\n' >> "$CALL_LOG"
case "$tool" in
  git)
    if [ "$1" = --version ]; then
      [ -f "$HOME/git-ready" ] || exit 127
      echo 'git version 2.43.0'
    elif [ "${BAD_REPO:-0}" = 1 ]; then
      echo 'fatal: test repository failure' >&2
      exit 128
    elif [ "$4" = --is-inside-work-tree ]; then
      echo true
    elif [ "$4" = --show-toplevel ]; then
      printf '%s\n' "$HOME/custom repo"
    else
      exit 99
    fi
    ;;
  uname) echo "${TEST_OS:-Linux}" ;;
  sudo)
    [ "${DENY_SUDO:-0}" = 0 ] || exit 1
    [ "$1" != -n ] || shift
    [ "$1" != -- ] || shift
    exec "$@"
    ;;
  apt-get|dnf|yum)
    [ "${FAIL_INSTALL:-0}" = 0 ] || exit 1
    if [ "$1" = install ] && [ "${BROKEN_INSTALL:-0}" = 0 ]; then
      : > "$HOME/git-ready"
    fi
    ;;
  chezmoi)
    if [ "$1" = source-path ]; then
      printf '%s\n' "$HOME/custom repo"
    fi
    ;;
  pixi|adopt) ;;
  *) exit 99 ;;
esac
"""


class BootstrapTest(unittest.TestCase):
    def run_bootstrap(self, *, git=True, manager="apt-get", sudo=True, **extra):
        with tempfile.TemporaryDirectory(prefix="dotfiles-test-") as tmp:
            home = Path(tmp)
            bin_dir = home / "bin"
            bin_dir.mkdir()
            tools = ["git", "uname", "pixi", "adopt", "chezmoi"]
            if manager:
                tools.append(manager)
            if sudo:
                tools.append("sudo")
            for tool in tools:
                path = bin_dir / tool
                path.write_text(STUB)
                path.chmod(0o755)
            if git:
                (home / "git-ready").touch()
            log = home / "calls"
            env = {
                "HOME": str(home),
                "PATH": str(bin_dir),
                "CALL_LOG": str(log),
                "ADOPT_GROUPS": "homelab",
                **extra,
            }
            # Match curl | bash, without a controlling terminal or inherited config.
            result = subprocess.run(
                ["/bin/bash"],
                input=BOOTSTRAP.read_text(),
                text=True,
                capture_output=True,
                env=env,
                start_new_session=True,
                timeout=10,
            )
            calls = log.read_text()
            return result, calls, str(home)

    def test_existing_git_and_explicit_source_repo(self):
        result, calls, home = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("apt-get", calls)
        self.assertNotIn("pixi <global>", calls)
        self.assertIn(
            f"adopt <init> <--yes> <--repo> <{home}/custom repo> <--groups> <homelab>",
            calls,
        )
        self.assertIn("chezmoi <apply> <--no-tty>", calls)

    def test_missing_git_installed_before_chezmoi_and_adopt(self):
        for manager in ("apt-get", "dnf", "yum"):
            with self.subTest(manager=manager):
                result, calls, _ = self.run_bootstrap(git=False, manager=manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                install = calls.index(f"{manager} <install> <-y> <git>")
                self.assertLess(install, calls.index("chezmoi <init>"))
                self.assertLess(install, calls.index("adopt <init>"))
                if os.geteuid() != 0:
                    self.assertIn(f"sudo <-n> <--> <{manager}>", calls)
                if manager == "apt-get":
                    self.assertLess(calls.index("apt-get <update>"), install)

    def test_invalid_repository_stops_before_adopt_and_preserves_git_error(self):
        result, calls, _ = self.run_bootstrap(BAD_REPO="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fatal: test repository failure", result.stderr)
        self.assertNotIn("adopt <init>", calls)

    def test_package_manager_failure_stops_before_chezmoi(self):
        result, calls, _ = self.run_bootstrap(git=False, FAIL_INSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("chezmoi <init>", calls)

    def test_git_must_work_after_install(self):
        result, calls, _ = self.run_bootstrap(git=False, BROKEN_INSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git --version", result.stderr)
        self.assertNotIn("chezmoi <init>", calls)

    def test_unsupported_package_manager(self):
        result, calls, _ = self.run_bootstrap(git=False, manager=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("adopt <init>", calls)

    def test_macos_missing_or_broken_git(self):
        result, calls, _ = self.run_bootstrap(git=False, TEST_OS="Darwin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("xcode-select --install", result.stderr)
        self.assertNotIn("apt-get", calls)

    @unittest.skipIf(os.geteuid() == 0, "root does not need sudo")
    def test_no_sudo(self):
        result, calls, _ = self.run_bootstrap(git=False, sudo=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apt-get <update>", calls)
        self.assertNotIn("adopt <init>", calls)

    @unittest.skipIf(os.geteuid() == 0, "root does not need sudo")
    def test_sudo_denied(self):
        result, calls, _ = self.run_bootstrap(git=False, DENY_SUDO="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apt-get <update>", calls)
        self.assertNotIn("adopt <init>", calls)

    def test_no_groups(self):
        result, calls, _ = self.run_bootstrap(ADOPT_GROUPS="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("<--groups>", calls)


if __name__ == "__main__":
    unittest.main()
