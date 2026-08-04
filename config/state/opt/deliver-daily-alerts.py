#!/usr/bin/env python3
"""Deliver today's daily summary through the fixed host-owned sender."""

from __future__ import annotations

import argparse
import json
import os
import pwd
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
DEFAULT_WORKSPACE = Path("/home/openclaw/.openclaw/workspace")
SENDER_TIMEOUT_SECONDS = 60


def read_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON artifact: {path}") from exc


def validate_inputs(workspace: Path, today: str) -> None:
    active_path = workspace / "state/alerts/active.json"
    if not active_path.is_file():
        raise ValueError(f"missing active alert state: {active_path}")
    active = read_json(active_path)
    if not isinstance(active, dict) or not isinstance(active.get("alerts"), list):
        raise ValueError(f"invalid active alert state: {active_path}")

    brief_path = workspace / f"public/briefs/{today}.html"
    if not brief_path.is_file() or brief_path.stat().st_size == 0:
        raise ValueError(f"missing published daily brief: {brief_path}")

    marker_path = workspace / f"working/sls-daily-brief/runs/{today}/sls-daily-brief.json"
    marker = read_json(marker_path)
    if (
        not isinstance(marker, dict)
        or marker.get("status") != "ok"
        or not marker.get("completed")
    ):
        raise ValueError(f"daily brief run is not complete: {marker_path}")


def build_sender_environment(workspace: Path, source: dict[str, str]) -> dict[str, str]:
    environment = dict(source)
    environment.pop("OPENCLAW_GATEWAY_TOKEN", None)
    environment.pop("OPENCLAW_REMOTE_TOKEN", None)
    environment["OPENCLAW_WORKSPACE"] = str(workspace)
    return environment


def validate_sender_output(stdout: str, stderr: str) -> None:
    telegram_ok = (
        "Telegram brief-summary sent via host service." in stdout
        or "Telegram brief-summary deduped via host service." in stdout
    )
    if not telegram_ok:
        detail = stderr.strip() or "sender did not report Telegram success"
        raise RuntimeError(f"Telegram delivery failed: {detail}")


def has_receipt(directory: Path, prefix: str, telegram: bool = False) -> bool:
    if not directory.is_dir():
        return False
    for path in directory.glob("*.json"):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(record, dict):
            continue
        if record.get("status") != "delivered":
            continue
        if not str(record.get("idempotencyKey", "")).startswith(prefix):
            continue
        if telegram:
            delivery = record.get("delivery")
            if not isinstance(delivery, dict) or delivery.get("ok") is not True:
                continue
        else:
            result = record.get("result")
            if not isinstance(result, dict) or not result.get("id"):
                continue
        return True
    return False


def validate_receipts(workspace: Path, today: str) -> None:
    telegram_prefix = f"sls-alerts:{today}:brief-summary:"
    telegram_dir = workspace / "working/sls-alerts/telegram-deliveries"
    if not has_receipt(telegram_dir, telegram_prefix, telegram=True):
        raise RuntimeError(f"missing Telegram delivery receipt for {today}")

    email_prefix = f"sls-alerts:{today}:email:"
    email_dir = workspace / "working/mail-proxy/deliveries"
    if not has_receipt(email_dir, email_prefix):
        raise RuntimeError(f"missing email delivery receipt for {today}")


def require_openclaw_user() -> None:
    expected_uid = pwd.getpwnam("openclaw").pw_uid
    if os.geteuid() != expected_uid:
        raise RuntimeError("daily alert delivery must run as openclaw")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deliver today's daily summary and verify both channel receipts."
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path(os.environ.get("OPENCLAW_WORKSPACE", DEFAULT_WORKSPACE)),
        help="OpenClaw workspace root",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    workspace = args.workspace.resolve()
    today = datetime.now(ET).strftime("%Y-%m-%d")
    sender = workspace / ".agents/skills/sls-alerts/scripts/send_alerts.py"

    require_openclaw_user()
    validate_inputs(workspace, today)
    if not sender.is_file():
        raise ValueError(f"missing immutable alert sender: {sender}")

    completed = subprocess.run(
        [sys.executable, str(sender)],
        cwd=workspace,
        env=build_sender_environment(workspace, os.environ),
        capture_output=True,
        text=True,
        timeout=SENDER_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise RuntimeError(f"daily alert sender exited with status {completed.returncode}")

    validate_sender_output(completed.stdout, completed.stderr)
    validate_receipts(workspace, today)
    print(f"Verified Telegram and email delivery receipts for {today}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)