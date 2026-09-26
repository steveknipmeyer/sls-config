#!/usr/bin/env python3
"""Behavior tests for the staged OpenClaw restore validator."""

from __future__ import annotations

import io
import json
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "validate_openclaw_restore.py"
)
ARCHIVE_ROOT = "2026-09-15T08-00-00.000+00-00-openclaw-backup"
STATE_ARCHIVE_PATH = f"{ARCHIVE_ROOT}/payload/posix/home/openclaw/.openclaw"


class StagedRestoreValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        fake_openclaw = self.bin_dir / "openclaw"
        fake_openclaw.write_text(
            "#!/bin/sh\n"
            'case "$3" in\n'
            '  /proc/self/fd/*) exit 1 ;;\n'
            '  /proc/*/fd/*) test -r "$3" ;;\n'
            '  *) exit 1 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        fake_openclaw.chmod(0o755)
        self.package_root = self.root / "system-openclaw-package"
        (self.package_root / "dist").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def create_archive(
        self,
        *,
        only_config: bool = False,
        corrupt_sqlite: bool = False,
        false_state_source: bool = False,
        malformed_asset: bool = False,
        omit_config: bool = False,
        restrictive_directory: bool = False,
        absolute_internal_symlink: bool = False,
        safe_symlink: bool = False,
        system_package_symlink: bool = False,
        traversal_asset_path: bool = False,
        unsafe_symlink: bool = False,
    ) -> Path:
        source = self.root / "source"
        state = source / ".openclaw"
        state.mkdir(parents=True)
        database = state / "state" / "openclaw.sqlite"
        database.parent.mkdir()
        if corrupt_sqlite:
            database.write_bytes(b"not a sqlite database")
        else:
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE health (status TEXT NOT NULL)")
            connection.execute("INSERT INTO health VALUES ('ok')")
            connection.commit()
            connection.close()
        (state / "credentials").mkdir()
        (state / "workspace").mkdir()
        if not omit_config:
            (state / "openclaw.json").write_text("{}\n", encoding="utf-8")

        manifest = {
            "schemaVersion": 1,
            "createdAt": "2026-09-15T08:00:00Z",
            "archiveRoot": ARCHIVE_ROOT,
            "runtimeVersion": "2026.7.1-2",
            "options": {"includeWorkspace": True, "onlyConfig": only_config},
            "paths": {
                "stateDir": "/home/openclaw/.openclaw",
                "configPath": "/home/openclaw/.openclaw/openclaw.json",
                "oauthDir": "/home/openclaw/.openclaw/credentials",
                "workspaceDirs": ["/home/openclaw/.openclaw/workspace"],
            },
            "assets": [
                {
                    "kind": "state",
                    "sourcePath": (
                        "/tmp/false-state"
                        if false_state_source
                        else "/home/openclaw/.openclaw"
                    ),
                    "archivePath": (
                        f"{ARCHIVE_ROOT}/payload/../outside"
                        if traversal_asset_path
                        else STATE_ARCHIVE_PATH
                    ),
                }
            ],
            "skipped": [],
        }
        if malformed_asset:
            manifest["assets"].append("not-an-asset")
        manifest_path = source / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        archive = self.root / "backup.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(manifest_path, arcname=f"{ARCHIVE_ROOT}/manifest.json")
            bundle.add(state, arcname=STATE_ARCHIVE_PATH)
            if absolute_internal_symlink:
                link = tarfile.TarInfo(f"{STATE_ARCHIVE_PATH}/absolute-config-link")
                link.type = tarfile.SYMTYPE
                link.linkname = "/home/openclaw/.openclaw/openclaw.json"
                bundle.addfile(link)
            if safe_symlink:
                link = tarfile.TarInfo(f"{STATE_ARCHIVE_PATH}/config-link")
                link.type = tarfile.SYMTYPE
                link.linkname = "openclaw.json"
                bundle.addfile(link)
            if system_package_symlink:
                link = tarfile.TarInfo(f"{STATE_ARCHIVE_PATH}/package-link")
                link.type = tarfile.SYMTYPE
                link.linkname = str(self.package_root / "dist")
                bundle.addfile(link)
            if restrictive_directory:
                directory = tarfile.TarInfo(f"{STATE_ARCHIVE_PATH}/restricted")
                directory.type = tarfile.DIRTYPE
                directory.mode = 0
                bundle.addfile(directory)
                payload = b"test"
                child = tarfile.TarInfo(f"{directory.name}/child")
                child.size = len(payload)
                bundle.addfile(child, io.BytesIO(payload))
            if unsafe_symlink:
                link = tarfile.TarInfo(f"{STATE_ARCHIVE_PATH}/unsafe-link")
                link.type = tarfile.SYMTYPE
                link.linkname = "/etc/passwd"
                bundle.addfile(link)
        return archive

    def run_validator(
        self, archive: Path, staging: Path
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.bin_dir}:{environment['PATH']}"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(archive),
                "--staging-dir",
                str(staging),
                "--system-package-root",
                str(self.package_root),
                "--live-state-root",
                "/home/openclaw/.openclaw",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_extracts_full_archive_and_validates_sqlite(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(), staging)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS staged restore", result.stdout)
        self.assertIn("sqlite=1", result.stdout)
        self.assertTrue(
            (staging / STATE_ARCHIVE_PATH / "state" / "openclaw.sqlite").is_file()
        )
        self.assertEqual(staging.stat().st_mode & 0o777, 0o700)

    def test_accepts_symlink_that_stays_inside_staging(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(safe_symlink=True), staging)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_remaps_absolute_internal_symlink_into_staging(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(
            self.create_archive(absolute_internal_symlink=True), staging
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        restored_link = staging / STATE_ARCHIVE_PATH / "absolute-config-link"
        self.assertTrue(restored_link.is_symlink())
        self.assertFalse(Path(os.readlink(restored_link)).is_absolute())

    def test_omits_reconstructable_system_package_symlink(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(
            self.create_archive(system_package_symlink=True), staging
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("package-links=1", result.stdout)
        self.assertFalse((staging / STATE_ARCHIVE_PATH / "package-link").exists())

    def test_rejects_missing_required_config_payload(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(omit_config=True), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required config payload", result.stderr)
        self.assertFalse(staging.exists())

    def test_rejects_traversal_in_manifest_asset_path(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(
            self.create_archive(traversal_asset_path=True), staging
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest asset path", result.stderr)
        self.assertFalse(staging.exists())

    def test_rejects_manifest_state_source_that_differs_from_live_root(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(
            self.create_archive(false_state_source=True), staging
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("live state root", result.stderr)
        self.assertFalse(staging.exists())

    def test_malformed_asset_fails_without_traceback(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(malformed_asset=True), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(staging.exists())

    def test_restrictive_directory_is_extracted_safely(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(
            self.create_archive(restrictive_directory=True), staging
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        restored = staging / STATE_ARCHIVE_PATH / "restricted"
        self.assertEqual(restored.stat().st_mode & 0o700, 0o700)

    def test_rejects_config_only_archive(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(only_config=True), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full backup", result.stderr)
        self.assertFalse(staging.exists())

    def test_rejects_unsafe_symlink_without_leaving_staging(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(unsafe_symlink=True), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe external archive link", result.stderr)
        self.assertFalse(staging.exists())

    def test_rejects_corrupt_sqlite_without_leaving_staging(self) -> None:
        staging = self.root / "staging"

        result = self.run_validator(self.create_archive(corrupt_sqlite=True), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SQLite integrity check failed", result.stderr)
        self.assertFalse(staging.exists())

    def test_refuses_existing_staging_directory(self) -> None:
        staging = self.root / "staging"
        staging.mkdir()

        result = self.run_validator(self.create_archive(), staging)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not already exist", result.stderr)


if __name__ == "__main__":
    unittest.main()
