#!/usr/bin/env python3
"""Create a deterministic, reconstructible snapshot of managed OpenClaw cron jobs."""

import argparse
import json
import sys
from typing import Any

TOP_LEVEL_METADATA_FIELDS = {
    "deliveryPreviews",
    "hasMore",
    "limit",
    "nextOffset",
    "offset",
    "total",
    "version",
}
JOB_FIELDS = {
    "agentId",
    "deleteAfterRun",
    "delivery",
    "description",
    "enabled",
    "id",
    "name",
    "payload",
    "schedule",
    "sessionTarget",
    "wakeMode",
}
VOLATILE_JOB_FIELDS = {
    "createdAtMs",
    "lastDelivered",
    "lastDeliveryError",
    "lastDeliveryStatus",
    "lastFailureNotificationDelivered",
    "lastFailureNotificationDeliveryError",
    "lastFailureNotificationDeliveryStatus",
    "lastRunAtMs",
    "lastRunError",
    "lastRunStatus",
    "nextRunAtMs",
    "state",
    "status",
    "updatedAtMs",
}
SCHEDULE_FIELDS = {"anchorMs", "at", "everyMs", "expr", "kind", "tz"}
PAYLOAD_FIELDS = {
    "bestEffortDeliver",
    "channel",
    "deliver",
    "kind",
    "lightContext",
    "message",
    "model",
    "text",
    "thinking",
    "timeoutSeconds",
    "to",
    "tools",
}
DELIVERY_FIELDS = {"accountId", "bestEffort", "channel", "mode", "threadId", "to"}


def select_fields(
    value: dict[str, Any], allowed: set[str], context: str
) -> dict[str, Any]:
    """Return allowed fields and reject unknown fields."""
    unknown = set(value) - allowed
    if unknown:
        raise ValueError(f"unknown {context} fields: {', '.join(sorted(unknown))}")
    return {key: value[key] for key in value if key in allowed}


def sanitize_job(job: Any) -> dict[str, Any]:
    """Validate and sanitize one managed cron job."""
    if not isinstance(job, dict):
        raise ValueError("each cron job must be an object")

    unknown = set(job) - JOB_FIELDS - VOLATILE_JOB_FIELDS
    if unknown:
        raise ValueError(f"unknown job fields: {', '.join(sorted(unknown))}")

    sanitized = {key: job[key] for key in job if key in JOB_FIELDS}
    for key, allowed in (
        ("schedule", SCHEDULE_FIELDS),
        ("payload", PAYLOAD_FIELDS),
        ("delivery", DELIVERY_FIELDS),
    ):
        if key not in sanitized:
            continue
        value = sanitized[key]
        if not isinstance(value, dict):
            raise ValueError(f"{key} must be an object")
        sanitized[key] = select_fields(value, allowed, key)

    return sanitized


def sanitize_snapshot(source: Any) -> dict[str, Any]:
    """Keep only managed SLS jobs and fields required to recreate them."""
    if not isinstance(source, dict):
        raise ValueError("cron list output must be an object")

    unknown = set(source) - {"jobs"} - TOP_LEVEL_METADATA_FIELDS
    if unknown:
        raise ValueError(f"unknown top-level fields: {', '.join(sorted(unknown))}")

    jobs = source.get("jobs")
    if not isinstance(jobs, list):
        raise ValueError("cron list output must contain a jobs array")

    managed_jobs = []
    for job in jobs:
        if not isinstance(job, dict):
            raise ValueError("each cron job must be an object")
        name = job.get("name")
        if isinstance(name, str) and name.startswith("sls-"):
            managed_jobs.append(sanitize_job(job))

    managed_jobs.sort(key=lambda job: (job.get("name", ""), job.get("id", "")))
    return {"version": 1, "jobs": managed_jobs}


def main(argv: list[str] | None = None) -> None:
    """Read cron-list JSON from stdin and write the sanitized snapshot to stdout."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    snapshot = sanitize_snapshot(json.load(sys.stdin))
    json.dump(snapshot, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
