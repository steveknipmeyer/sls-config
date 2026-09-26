"""Regression tests for atomic harvest redaction and secret scanning."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

HARVEST = Path(__file__).parents[1] / "scripts" / "harvest.sh"


def function_source(name: str) -> str:
    """Extract a shell helper without running the root-only harvest body."""
    script = HARVEST.read_text(encoding="utf-8")
    start = script.index(f"{name}() {{")
    end = script.index("\n}", start) + 2
    return script[start:end]


def config_filter() -> str:
    """Return the jq filter passed to the runtime config snapshot helper."""
    script = HARVEST.read_text(encoding="utf-8")
    marker = '"${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json" \'\n'
    return script.split(marker, 1)[1].split("\n'\nlog", 1)[0]


class HarvestRedactionTests(unittest.TestCase):
    def test_harvest_uses_read_only_doctor_report(self) -> None:
        harvest = HARVEST.read_text(encoding="utf-8")
        self.assertIn("run_openclaw_as_openclaw doctor --json", harvest)
        self.assertNotIn(
            "run_openclaw_as_openclaw doctor --non-interactive --yes", harvest
        )

    def test_missing_token_paths_stay_absent(self) -> None:
        source = {"gateway": {"auth": {}}, "hooks": {"enabled": False}}
        result = subprocess.run(
            ["jq", config_filter()],
            input=json.dumps(source),
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(json.loads(result.stdout), source)

    def test_existing_tokens_are_redacted_and_secret_refs_remain(self) -> None:
        source = {
            "gateway": {
                "auth": {"token": "example-secret"},
                "remote": {"token": {"source": "env", "id": "TOKEN_REF"}},
            },
            "hooks": {"token": "example-hook-secret"},
        }
        result = subprocess.run(
            ["jq", config_filter()],
            input=json.dumps(source),
            text=True,
            capture_output=True,
            check=True,
        )
        redacted = json.loads(result.stdout)
        self.assertEqual(redacted["gateway"]["auth"]["token"], "REDACTED")
        self.assertEqual(
            redacted["gateway"]["remote"]["token"], source["gateway"]["remote"]["token"]
        )
        self.assertEqual(redacted["hooks"]["token"], "REDACTED")

    def run_snapshot_helper(
        self, source: Path, snapshot: Path
    ) -> subprocess.CompletedProcess[str]:
        """Run the harvest helper against synthetic paths only."""
        shell = (
            "set -euo pipefail\n"
            "log_warn() { :; }\n"
            f"{function_source('redact_json_snapshot')}\n"
            'redact_json_snapshot "$1" "$2" ".token = \\"REDACTED\\""\n'
        )
        return subprocess.run(
            ["bash", "-c", shell, "test", str(source), str(snapshot)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_missing_or_malformed_source_preserves_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            snapshot = root / "snapshot.json"
            snapshot.write_text('{"saved":"good"}\n', encoding="utf-8")

            self.assertNotEqual(
                self.run_snapshot_helper(source, snapshot).returncode, 0
            )
            self.assertEqual(snapshot.read_text(), '{"saved":"good"}\n')

            source.write_text("{invalid", encoding="utf-8")
            self.assertNotEqual(
                self.run_snapshot_helper(source, snapshot).returncode, 0
            )
            self.assertEqual(snapshot.read_text(), '{"saved":"good"}\n')
            self.assertEqual(list(root.glob("snapshot.json.tmp.*")), [])

    def test_valid_source_replaces_snapshot_with_redacted_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            snapshot = root / "snapshot.json"
            source.write_text('{"token":"example-secret"}\n', encoding="utf-8")
            snapshot.write_text('{"saved":"old"}\n', encoding="utf-8")

            result = self.run_snapshot_helper(source, snapshot)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(snapshot.read_text()), {"token": "REDACTED"})

    def test_only_named_package_hash_lines_are_exempt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            script = state / "usr/local/libexec/sls/transition-node-runtime.sh"
            script.parent.mkdir(parents=True)
            digest = "a" * 64
            script.write_text(
                f'TARGET_PACKAGE_SHA256="{digest}"\nROLLBACK_PACKAGE_SHA256="{digest}"\n'
            )
            shell = (
                "set -euo pipefail\n"
                f"{function_source('contains_secret_pattern')}\n"
                'STATE_DIR="$1"\nSECRET_PATTERN="[0-9a-f]{64}|tskey-"\n'
                'contains_secret_pattern "$2"\n'
            )

            def detected() -> bool:
                return (
                    subprocess.run(
                        ["bash", "-c", shell, "test", str(state), str(script)],
                        capture_output=True,
                        check=False,
                    ).returncode
                    == 0
                )

            self.assertFalse(detected())
            script.write_text(script.read_text() + f'OTHER_VALUE="{digest}"\n')
            self.assertTrue(detected())
            script.write_text(f'TARGET_PACKAGE_SHA256="{digest}" # extra text\n')
            self.assertTrue(detected())


if __name__ == "__main__":
    unittest.main()
