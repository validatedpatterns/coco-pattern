"""Smoke tests for Python command-line interfaces without external tooling."""

import re
import subprocess
import sys
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


def test_help_for_all_python_entry_points():
    commands = {
        "scripts/collect_firmware_refvals.py": "--platform",
        "scripts/git-http-server.py": "GIT_PROJECT_ROOT",
        "rhdp/rhdp-cluster-define.py": "REGION",
    }
    for script, expected_option in commands.items():
        result = run_cli(script, "--help")
        assert result.returncode == 0, output(result)
        assert "Usage:" in output(result)
        assert expected_option in output(result)


def test_collector_rejects_missing_or_invalid_options():
    cases = (
        (),
        ("--platform", "invalid"),
        ("--platform", "baremetal", "--tee", "invalid"),
    )
    for arguments in cases:
        result = run_cli("scripts/collect_firmware_refvals.py", *arguments)
        assert result.returncode != 0
        assert "Error" in output(result)


def test_collector_help_preserves_option_contract():
    result = run_cli("scripts/collect_firmware_refvals.py", "--help")
    assert result.returncode == 0, output(result)
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
        assert option in help_output


def test_git_http_server_help_preserves_positional_defaults():
    result = run_cli("scripts/git-http-server.py", "--help")
    assert result.returncode == 0, output(result)
    help_output = output(result)
    assert "[port]" in help_output
    assert "[default: 8080]" in help_output
    assert "[git_project_root]" in help_output
    assert "[default: ~/public_html/git]" in help_output
