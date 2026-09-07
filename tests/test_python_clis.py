"""Smoke tests for Python command-line interfaces without external tooling."""

import re
import subprocess
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


def run_cli(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, *arguments],
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def output(result: subprocess.CompletedProcess[str]) -> str:
    return ANSI_ESCAPE.sub("", result.stdout + result.stderr)


class PythonCLITests(unittest.TestCase):
    def test_help_for_all_python_entry_points(self):
        commands = {
            "scripts/collect_firmware_refvals.py": "--platform",
            "scripts/git-http-server.py": "GIT_PROJECT_ROOT",
            "rhdp/rhdp-cluster-define.py": "REGION",
        }
        for script, expected_option in commands.items():
            with self.subTest(script=script):
                result = run_cli(script, "--help")
                self.assertEqual(result.returncode, 0, output(result))
                self.assertIn("Usage:", output(result))
                self.assertIn(expected_option, output(result))

    def test_collector_rejects_missing_or_invalid_options(self):
        cases = (
            (),
            ("--platform", "invalid"),
            ("--platform", "baremetal", "--tee", "invalid"),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = run_cli("scripts/collect_firmware_refvals.py", *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error", output(result))

    def test_collector_help_preserves_option_contract(self):
        result = run_cli("scripts/collect_firmware_refvals.py", "--help")
        self.assertEqual(result.returncode, 0, output(result))
        help_output = output(result)
        for option in (
            "[baremetal|azure]",
            "--output",
            "--pull-secret",
            "--ocp-version",
            "--osc-version",
            "[tdx|snp|both]",
            "--verify-tlog",
        ):
            with self.subTest(option=option):
                self.assertIn(option, help_output)

    def test_git_http_server_help_preserves_positional_defaults(self):
        result = run_cli("scripts/git-http-server.py", "--help")
        self.assertEqual(result.returncode, 0, output(result))
        help_output = output(result)
        self.assertIn("[port]", help_output)
        self.assertIn("[default: 8080]", help_output)
        self.assertIn("[git_project_root]", help_output)
        self.assertIn("[default: ~/public_html/git]", help_output)


if __name__ == "__main__":
    unittest.main()
