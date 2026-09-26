"""Tests for the harvested OpenClaw cron snapshot sanitizer."""

import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "sanitize_openclaw_cron.py"
HARVEST_PATH = Path(__file__).parents[1] / "scripts" / "harvest.sh"
SNAPSHOT_PATH = "config/state/home/openclaw/dot-openclaw/cron-jobs.json"


def load_module():
    """Load the sanitizer script as a module."""
    spec = importlib.util.spec_from_file_location("sanitize_openclaw_cron", SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SanitizeOpenClawCronTests(unittest.TestCase):
    def test_harvest_uses_gateway_handoff_and_tracks_snapshot(self) -> None:
        harvest = HARVEST_PATH.read_text()

        self.assertIn("run_openclaw_with_gateway_as_openclaw", harvest)
        self.assertIn("--whitelist-environment", harvest)
        self.assertIn("sanitize_openclaw_cron.py", harvest)
        self.assertIn(SNAPSHOT_PATH, harvest)
        self.assertIn("-type d -name __pycache__ -prune -exec rm -rf {} +", harvest)

    def test_keeps_only_reconstructible_sls_job_fields(self) -> None:
        sanitizer = load_module()
        source = {
            "version": 1,
            "deliveryPreviews": {
                "job-1": {
                    "label": "Telegram",
                    "detail": "private destination metadata",
                }
            },
            "jobs": [
                {
                    "id": "job-2",
                    "name": "personal-reminder",
                    "enabled": True,
                    "schedule": {"kind": "at", "at": "2026-09-10T12:00:00Z"},
                    "payload": {"kind": "agentTurn", "message": "Private reminder"},
                },
                {
                    "id": "job-1",
                    "name": "sls-system",
                    "description": "Daily system renderer",
                    "enabled": True,
                    "createdAtMs": 1,
                    "updatedAtMs": 2,
                    "nextRunAtMs": 3,
                    "lastRunAtMs": 4,
                    "lastRunStatus": "ok",
                    "lastRunError": "old error",
                    "lastDelivered": True,
                    "lastDeliveryStatus": "delivered",
                    "lastDeliveryError": "old delivery error",
                    "lastFailureNotificationDelivered": True,
                    "lastFailureNotificationDeliveryStatus": "delivered",
                    "lastFailureNotificationDeliveryError": "old alert error",
                    "status": "idle",
                    "schedule": {
                        "kind": "cron",
                        "expr": "45 3 * * *",
                        "tz": "America/New_York",
                    },
                    "sessionTarget": "isolated",
                    "wakeMode": "now",
                    "payload": {
                        "kind": "agentTurn",
                        "message": "Use the sls-system skill.",
                        "model": "openai/gpt-5.6-luna",
                        "thinking": "off",
                        "timeoutSeconds": 300,
                        "lightContext": True,
                        "tools": ["read"],
                    },
                    "delivery": {"mode": "none", "channel": "last"},
                    "state": {"nextRunAtMs": 5, "lastStatus": "ok"},
                },
            ],
        }

        result = sanitizer.sanitize_snapshot(source)

        self.assertEqual(
            result,
            {
                "version": 1,
                "jobs": [
                    {
                        "id": "job-1",
                        "name": "sls-system",
                        "description": "Daily system renderer",
                        "enabled": True,
                        "schedule": {
                            "kind": "cron",
                            "expr": "45 3 * * *",
                            "tz": "America/New_York",
                        },
                        "sessionTarget": "isolated",
                        "wakeMode": "now",
                        "payload": {
                            "kind": "agentTurn",
                            "message": "Use the sls-system skill.",
                            "model": "openai/gpt-5.6-luna",
                            "thinking": "off",
                            "timeoutSeconds": 300,
                            "lightContext": True,
                            "tools": ["read"],
                        },
                        "delivery": {"mode": "none", "channel": "last"},
                    }
                ],
            },
        )

    def test_ignores_snapshot_revision_metadata(self) -> None:
        sanitizer = load_module()
        source = {"snapshotRevision": "revision-123", "jobs": []}

        self.assertEqual(
            sanitizer.sanitize_snapshot(source), {"version": 1, "jobs": []}
        )

    def test_ignores_managed_job_revision_and_resolved_agent(self) -> None:
        sanitizer = load_module()
        source = {
            "jobs": [
                {
                    "id": "job-1",
                    "name": "sls-system",
                    "agentId": "configured-agent",
                    "configRevision": "revision-123",
                    "effectiveAgentId": "resolved-agent",
                }
            ]
        }

        self.assertEqual(
            sanitizer.sanitize_snapshot(source),
            {
                "version": 1,
                "jobs": [
                    {
                        "id": "job-1",
                        "name": "sls-system",
                        "agentId": "configured-agent",
                    }
                ],
            },
        )

    def test_rejects_unknown_managed_job_fields(self) -> None:
        sanitizer = load_module()
        source = {
            "jobs": [
                {
                    "id": "job-1",
                    "name": "sls-system",
                    "enabled": True,
                    "schedule": {"kind": "cron", "expr": "45 3 * * *"},
                    "payload": {
                        "kind": "agentTurn",
                        "message": "Use the sls-system skill.",
                        "unexpected": "must not be silently harvested",
                    },
                }
            ]
        }

        with self.assertRaisesRegex(ValueError, "payload fields"):
            sanitizer.sanitize_snapshot(source)

    def test_cli_reads_stdin_and_writes_formatted_json(self) -> None:
        sanitizer = load_module()
        source = {
            "jobs": [
                {
                    "id": "job-1",
                    "name": "sls-costs",
                    "enabled": True,
                    "schedule": {"kind": "cron", "expr": "58 3 * * *"},
                    "payload": {
                        "kind": "agentTurn",
                        "message": "Use the sls-costs skill.",
                        "model": "openai/gpt-5.6-luna",
                    },
                }
            ]
        }
        stdin = io.StringIO(json.dumps(source))
        stdout = io.StringIO()
        with patch.object(sys, "stdin", stdin), patch.object(sys, "stdout", stdout):
            sanitizer.main([])

        self.assertEqual(json.loads(stdout.getvalue())["jobs"][0]["name"], "sls-costs")


if __name__ == "__main__":
    unittest.main()
